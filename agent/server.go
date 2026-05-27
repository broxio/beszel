package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"strings"
	"time"

	"github.com/henrygd/beszel"
	"github.com/henrygd/beszel/agent/utils"
	"github.com/henrygd/beszel/internal/common"
	"github.com/henrygd/beszel/internal/entities/system"

	"github.com/blang/semver"
	"github.com/fxamacker/cbor/v2"
	"github.com/gliderlabs/ssh"
	gossh "golang.org/x/crypto/ssh"
)

// ServerOptions contains configuration options for starting the SSH server.
type ServerOptions struct {
	Addr    string            // Network address to listen on (e.g., ":45876" or "/path/to/socket")
	Network string            // Network type ("tcp" or "unix")
	Keys    []gossh.PublicKey // SSH public keys for authentication
}

// hubVersions caches hub versions by session ID to avoid repeated parsing.
var hubVersions map[string]semver.Version

// StartServer starts the SSH server with the provided options.
// It configures the server with secure defaults, sets up authentication,
// and begins listening for connections. Returns an error if the server
// is already running or if there's an issue starting the server.
func (a *Agent) StartServer(opts ServerOptions) error {
	if disableSSH, _ := utils.GetEnv("DISABLE_SSH"); disableSSH == "true" {
		return errors.New("SSH disabled")
	}
	if a.server != nil {
		return errors.New("server already started")
	}

	slog.Info("Starting SSH server", "addr", opts.Addr, "network", opts.Network)

	if opts.Network == "unix" {
		// remove existing socket file if it exists
		if err := os.Remove(opts.Addr); err != nil && !os.IsNotExist(err) {
			return err
		}
	}

	// start listening on the address
	ln, err := net.Listen(opts.Network, opts.Addr)
	if err != nil {
		return err
	}
	defer ln.Close()

	// base config (limit to allowed algorithms)
	config := &gossh.ServerConfig{
		ServerVersion: fmt.Sprintf("SSH-2.0-%s_%s", beszel.AppName, beszel.Version),
	}
	config.KeyExchanges = common.DefaultKeyExchanges
	config.MACs = common.DefaultMACs
	config.Ciphers = common.DefaultCiphers

	// set default handler
	ssh.Handle(a.handleSession)

	a.server = &ssh.Server{
		ServerConfigCallback: func(ctx ssh.Context) *gossh.ServerConfig {
			return config
		},
		// check public key(s)
		PublicKeyHandler: func(ctx ssh.Context, key ssh.PublicKey) bool {
			remoteAddr := ctx.RemoteAddr()
			for _, pubKey := range opts.Keys {
				if ssh.KeysEqual(key, pubKey) {
					slog.Info("SSH connected", "addr", remoteAddr)
					return true
				}
			}
			slog.Warn("Invalid SSH key", "addr", remoteAddr)
			return false
		},
		// disable pty
		PtyCallback: func(ctx ssh.Context, pty ssh.Pty) bool {
			return false
		},
		// close idle connections after 70 seconds (channel-traffic-aware — does
		// not fire while a port-forward is actively shipping bytes).
		IdleTimeout: 70 * time.Second,
		// Allow direct-tcpip forwards ONLY to Vector's gRPC API port on
		// localhost. Enables the hub to dial Vector's StreamComponentMetrics
		// gRPC service through this SSH connection without exposing the rest
		// of the agent's localhost services. Disabled entirely when
		// VECTOR_API_ADDR is not set.
		LocalPortForwardingCallback: vectorForwardCallback(),
	}

	// Start SSH server on the listener
	return a.server.Serve(ln)
}

// getHubVersion retrieves and caches the hub version for a given session.
// It extracts the version from the SSH client version string and caches
// it to avoid repeated parsing. Returns a zero version if parsing fails.
func (a *Agent) getHubVersion(sessionId string, sessionCtx ssh.Context) semver.Version {
	if hubVersions == nil {
		hubVersions = make(map[string]semver.Version, 1)
	}
	hubVersion, ok := hubVersions[sessionId]
	if ok {
		return hubVersion
	}
	// Extract hub version from SSH client version
	clientVersion := sessionCtx.Value(ssh.ContextKeyClientVersion)
	if versionStr, ok := clientVersion.(string); ok {
		hubVersion, _ = extractHubVersion(versionStr)
	}
	hubVersions[sessionId] = hubVersion
	return hubVersion
}

// handleSession handles an incoming SSH session by gathering system statistics
// and sending them to the hub. It signals connection events, determines the
// appropriate encoding format based on hub version, and exits with appropriate
// status codes.
func (a *Agent) handleSession(s ssh.Session) {
	a.connectionManager.eventChan <- SSHConnect

	sessionCtx := s.Context()
	sessionID := sessionCtx.SessionID()

	hubVersion := a.getHubVersion(sessionID, sessionCtx)

	// Legacy one-shot behavior for older hubs
	if hubVersion.LT(beszel.MinVersionAgentResponse) {
		if err := a.handleLegacyStats(s, hubVersion); err != nil {
			slog.Error("Error encoding stats", "err", err)
			s.Exit(1)
			return
		}
	}

	var req common.HubRequest[cbor.RawMessage]
	if err := cbor.NewDecoder(s).Decode(&req); err != nil {
		// Fallback to legacy one-shot if the first decode fails
		if err2 := a.handleLegacyStats(s, hubVersion); err2 != nil {
			slog.Error("Error encoding stats (fallback)", "err", err2)
			s.Exit(1)
			return
		}
		s.Exit(0)
		return
	}
	if err := a.handleSSHRequest(s, &req); err != nil {
		slog.Error("SSH request handling failed", "err", err)
		s.Exit(1)
		return
	}
	s.Exit(0)
}

// handleSSHRequest builds a handler context and dispatches to the shared registry
func (a *Agent) handleSSHRequest(w io.Writer, req *common.HubRequest[cbor.RawMessage]) error {
	// SSH does not support fingerprint auth action
	if req.Action == common.CheckFingerprint {
		return cbor.NewEncoder(w).Encode(common.AgentResponse{Error: "unsupported action"})
	}

	// responder that writes AgentResponse to stdout
	// Uses legacy typed fields for backward compatibility with <= 0.17
	sshResponder := func(data any, requestID *uint32) error {
		response := newAgentResponse(data, requestID)
		return cbor.NewEncoder(w).Encode(response)
	}

	ctx := &HandlerContext{
		Client:       nil,
		Agent:        a,
		Request:      req,
		RequestID:    nil,
		HubVerified:  true,
		SendResponse: sshResponder,
	}

	if handler, ok := a.handlerRegistry.GetHandler(req.Action); ok {
		if err := handler.Handle(ctx); err != nil {
			return cbor.NewEncoder(w).Encode(common.AgentResponse{Error: err.Error()})
		}
		return nil
	}
	return cbor.NewEncoder(w).Encode(common.AgentResponse{Error: fmt.Sprintf("unknown action: %d", req.Action)})
}

// handleLegacyStats serves the legacy one-shot stats payload for older hubs
func (a *Agent) handleLegacyStats(w io.Writer, hubVersion semver.Version) error {
	stats := a.gatherStats(common.DataRequestOptions{CacheTimeMs: defaultDataCacheTimeMs})
	return a.writeToSession(w, stats, hubVersion)
}

// writeToSession encodes and writes system statistics to the session.
// It chooses between CBOR and JSON encoding based on the hub version,
// using CBOR for newer versions and JSON for legacy compatibility.
func (a *Agent) writeToSession(w io.Writer, stats *system.CombinedData, hubVersion semver.Version) error {
	if hubVersion.GTE(beszel.MinVersionCbor) {
		return cbor.NewEncoder(w).Encode(stats)
	}
	return json.NewEncoder(w).Encode(stats)
}

// vectorForwardCallback returns a LocalPortForwardingCallback that allows
// direct-tcpip channels to Vector's gRPC API port and rejects everything else.
//
// The hub uses this forward to stream Vector observability data
// (StreamComponentMetrics) without needing a new agent-side handler — it dials
// gRPC straight through to the local Vector instance. Whitelisting one specific
// destination keeps the surface narrow: the hub gets reach into the agent's
// Vector port but not into anything else on localhost.
//
// When VECTOR_API_ADDR is not set on the agent (no Vector on this host) all
// forwards are denied — same posture as before this change.
func vectorForwardCallback() ssh.LocalPortForwardingCallback {
	var allowedHost string
	var allowedPort uint32

	addr, ok := utils.GetEnv("VECTOR_API_ADDR")
	if !ok || strings.TrimSpace(addr) == "" {
		// Legacy alias from mp.5 era — accept either spelling.
		if legacy, lok := utils.GetEnv("VECTOR_API_URL"); lok {
			addr = legacy
		}
	}
	if h, p, err := parseHostPort(addr); err == nil {
		allowedHost = h
		allowedPort = p
		slog.Info("SSH local port forward allowed for Vector", "host", allowedHost, "port", allowedPort)
	}

	return func(ctx ssh.Context, destinationHost string, destinationPort uint32) bool {
		if allowedPort == 0 {
			slog.Debug("SSH port forward denied (Vector not configured)", "to", fmt.Sprintf("%s:%d", destinationHost, destinationPort))
			return false
		}
		// Only loopback destinations matching the configured Vector port.
		if destinationPort != allowedPort {
			slog.Debug("SSH port forward denied (wrong port)", "to", fmt.Sprintf("%s:%d", destinationHost, destinationPort), "allowed", fmt.Sprintf("%s:%d", allowedHost, allowedPort))
			return false
		}
		if destinationHost != "127.0.0.1" && destinationHost != "localhost" && destinationHost != allowedHost {
			slog.Debug("SSH port forward denied (wrong host)", "to", fmt.Sprintf("%s:%d", destinationHost, destinationPort), "allowed", fmt.Sprintf("%s:%d", allowedHost, allowedPort))
			return false
		}
		return true
	}
}

// parseHostPort tolerates the URL-shaped inputs that VECTOR_API_ADDR / _URL
// historically accepted, plus plain host:port. Returns the host (loopback
// expected) and port number.
func parseHostPort(raw string) (string, uint32, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", 0, errors.New("empty")
	}
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := strings.IndexByte(s, '/'); i >= 0 {
		s = s[:i]
	}
	host, portStr, err := net.SplitHostPort(s)
	if err != nil {
		return "", 0, err
	}
	var port uint32
	for _, r := range portStr {
		if r < '0' || r > '9' {
			return "", 0, fmt.Errorf("invalid port: %q", portStr)
		}
		port = port*10 + uint32(r-'0')
	}
	if port == 0 || port > 65535 {
		return "", 0, fmt.Errorf("port out of range: %d", port)
	}
	return host, port, nil
}

// extractHubVersion extracts the beszel version from SSH client version string.
// Expected format: "SSH-2.0-beszel_X.Y.Z" or "beszel_X.Y.Z"
func extractHubVersion(versionString string) (semver.Version, error) {
	_, after, _ := strings.Cut(versionString, "_")
	return semver.Parse(after)
}

// ParseKeys parses a string containing SSH public keys in authorized_keys format.
// It returns a slice of ssh.PublicKey and an error if any key fails to parse.
func ParseKeys(input string) ([]gossh.PublicKey, error) {
	var parsedKeys []gossh.PublicKey
	for line := range strings.Lines(input) {
		line = strings.TrimSpace(line)
		// Skip empty lines or comments
		if len(line) == 0 || strings.HasPrefix(line, "#") {
			continue
		}
		// Parse the key
		parsedKey, _, _, _, err := gossh.ParseAuthorizedKey([]byte(line))
		if err != nil {
			return nil, fmt.Errorf("failed to parse key: %s, error: %w", line, err)
		}
		parsedKeys = append(parsedKeys, parsedKey)
	}
	return parsedKeys, nil
}

// GetAddress determines the network address to listen on from various sources.
// It checks the provided address, then environment variables (LISTEN, PORT),
// and finally defaults to ":45876".
func GetAddress(addr string) string {
	if addr == "" {
		addr, _ = utils.GetEnv("LISTEN")
	}
	if addr == "" {
		// Legacy PORT environment variable support
		addr, _ = utils.GetEnv("PORT")
	}
	if addr == "" {
		return ":45876"
	}
	// prefix with : if only port was provided
	if GetNetwork(addr) != "unix" && !strings.Contains(addr, ":") {
		addr = ":" + addr
	}
	return addr
}

// GetNetwork determines the network type based on the address format.
// It checks the NETWORK environment variable first, then infers from
// the address format: addresses starting with "/" are "unix", others are "tcp".
func GetNetwork(addr string) string {
	if network, ok := utils.GetEnv("NETWORK"); ok && network != "" {
		return network
	}
	if strings.HasPrefix(addr, "/") {
		return "unix"
	}
	return "tcp"
}

// StopServer stops the SSH server if it's running.
// It returns an error if the server is not running or if there's an error stopping it.
func (a *Agent) StopServer() error {
	if a.server == nil {
		return errors.New("SSH server not running")
	}

	slog.Info("Stopping SSH server")
	_ = a.server.Close()
	a.server = nil
	a.connectionManager.eventChan <- SSHDisconnect
	return nil
}
