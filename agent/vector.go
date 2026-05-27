package agent

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/henrygd/beszel/agent/utils"
	"github.com/henrygd/beszel/agent/vectorpb"
	"github.com/henrygd/beszel/internal/entities/system"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// VectorManager polls a local Vector aggregator's gRPC observability API
// and exposes per-component throughput and byte counters. Opt-in via the
// VECTOR_API_ADDR env var (a gRPC dial target like "127.0.0.1:8687", not
// a URL) — when unset, NewVectorManager returns (nil, error) and the agent
// skips Vector collection.
//
// Vector exposes only cumulative counters; the UI derives per-second rates
// client-side from successive samples (parallels HAProxy, in contrast to
// LVS where the kernel estimator provides rates directly).
//
// The gRPC API has separate streaming RPCs (StreamComponentMetrics) for
// "live" `vector top`-style updates, but we stick with polling here to
// match the rest of the agent's collection model.
type VectorManager struct {
	sync.Mutex
	addr         string
	conn         *grpc.ClientConn
	client       vectorpb.ObservabilityServiceClient
	stats        *system.VectorStats
	lastUpdate   time.Time
	updatePeriod time.Duration

	consecutiveFailures int
	lastError           error
}

const (
	vectorDefaultUpdateInterval = 5 * time.Second
	vectorRequestTimeout        = 4 * time.Second
)

var errVectorDisabled = errors.New("VECTOR_API_ADDR not set")

// NewVectorManager returns a manager only when VECTOR_API_ADDR is set AND the
// endpoint answers GetMeta. Probe failures bubble up so the agent logs the
// reason at DEBUG and continues without Vector collection.
func NewVectorManager() (*VectorManager, error) {
	// Backward-compat alias: accept VECTOR_API_URL too so an mp.5 config keeps
	// working after the operator notices the rename. The URL form will likely
	// have a "/graphql" suffix that we strip before dialing.
	addr, ok := utils.GetEnv("VECTOR_API_ADDR")
	if !ok || strings.TrimSpace(addr) == "" {
		if legacy, lok := utils.GetEnv("VECTOR_API_URL"); lok && strings.TrimSpace(legacy) != "" {
			addr = legacy
			slog.Warn("VECTOR_API_URL is deprecated, use VECTOR_API_ADDR (host:port)", "value", legacy)
		} else {
			return nil, errVectorDisabled
		}
	}

	dialTarget, err := normalizeVectorAddr(addr)
	if err != nil {
		return nil, fmt.Errorf("invalid VECTOR_API_ADDR: %w", err)
	}

	updatePeriod := vectorDefaultUpdateInterval
	if intervalStr, exists := utils.GetEnv("VECTOR_UPDATE_INTERVAL"); exists {
		if d, perr := time.ParseDuration(intervalStr); perr == nil && d > 0 {
			updatePeriod = d
			slog.Info("Vector update interval configured", "duration", d)
		}
	}

	// grpc.NewClient lazy-connects on first RPC, so dial errors surface on the
	// initial fetch rather than here. That's fine for our probe model.
	conn, err := grpc.NewClient(dialTarget, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("vector dial: %w", err)
	}

	vm := &VectorManager{
		addr:         dialTarget,
		conn:         conn,
		client:       vectorpb.NewObservabilityServiceClient(conn),
		updatePeriod: updatePeriod,
	}

	if _, err := vm.fetch(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	slog.Info("Vector monitoring enabled", "addr", dialTarget)
	return vm, nil
}

// normalizeVectorAddr accepts forms users typically set and produces a gRPC
// dial target (host:port). Tolerates the old VECTOR_API_URL shapes — anyone
// upgrading from mp.5 likely still has http://host:8687/graphql in their conf.
//
//   - 127.0.0.1:8687              → 127.0.0.1:8687
//   - http://127.0.0.1:8687       → 127.0.0.1:8687
//   - http://127.0.0.1:8687/graphql → 127.0.0.1:8687 (path stripped)
//   - vector-host:8687            → vector-host:8687
func normalizeVectorAddr(raw string) (string, error) {
	addr := strings.TrimSpace(raw)
	if addr == "" {
		return "", fmt.Errorf("empty address")
	}
	// Strip scheme if present.
	if i := strings.Index(addr, "://"); i >= 0 {
		addr = addr[i+3:]
	}
	// Strip any path component.
	if i := strings.IndexByte(addr, '/'); i >= 0 {
		addr = addr[:i]
	}
	if addr == "" {
		return "", fmt.Errorf("missing host")
	}
	return addr, nil
}

// Close releases the underlying gRPC connection. Currently the agent has no
// shutdown hook for managers, but Close is here for tests and future use.
func (vm *VectorManager) Close() error {
	vm.Lock()
	defer vm.Unlock()
	if vm.conn != nil {
		return vm.conn.Close()
	}
	return nil
}

// GetStats returns a copy of the most recent Vector snapshot, refreshing if stale.
func (vm *VectorManager) GetStats() *system.VectorStats {
	vm.Lock()
	defer vm.Unlock()

	if time.Since(vm.lastUpdate) > vm.updatePeriod {
		if stats, err := vm.fetch(); err == nil {
			vm.stats = stats
			vm.lastUpdate = time.Now()
			vm.consecutiveFailures = 0
			vm.lastError = nil
		} else {
			vm.consecutiveFailures++
			vm.lastError = err
			if vm.consecutiveFailures > 5 {
				slog.Warn("Vector collection persistently failing",
					"consecutiveFailures", vm.consecutiveFailures, "err", err)
			} else {
				slog.Debug("Vector fetch failed", "err", err)
			}
		}
	}

	if vm.stats == nil {
		return nil
	}
	c := *vm.stats
	return &c
}

// GetConnectionHealth exposes the consecutive failure count for diagnostics.
func (vm *VectorManager) GetConnectionHealth() (failures int, lastErr error) {
	vm.Lock()
	defer vm.Unlock()
	return vm.consecutiveFailures, vm.lastError
}

// fetch issues two unary RPCs (GetMeta + GetComponents) and assembles the
// VectorStats snapshot. Both calls share a single timeout — if Vector is
// slow, fail fast rather than blocking the agent's collection loop.
func (vm *VectorManager) fetch() (*system.VectorStats, error) {
	ctx, cancel := context.WithTimeout(context.Background(), vectorRequestTimeout)
	defer cancel()

	meta, err := vm.client.GetMeta(ctx, &vectorpb.GetMetaRequest{})
	if err != nil {
		return nil, fmt.Errorf("vector GetMeta: %w", err)
	}

	components, err := vm.client.GetComponents(ctx, &vectorpb.GetComponentsRequest{Limit: 0})
	if err != nil {
		return nil, fmt.Errorf("vector GetComponents: %w", err)
	}

	stats := &system.VectorStats{
		Version:  meta.GetVersion(),
		Hostname: meta.GetHostname(),
		// gRPC API has no health endpoint distinct from connection health —
		// successful GetMeta = healthy. Anyone listening on that port and
		// implementing this proto is by definition a working Vector.
		Healthy: true,
	}

	for _, c := range components.GetComponents() {
		comp := system.VectorComponent{
			ID:   c.GetComponentId(),
			Type: c.GetOnType(),
			Kind: componentKindString(c.GetComponentType()),
		}
		if m := c.GetMetrics(); m != nil {
			comp.ReceivedEvents = uint64(m.GetReceivedEventsTotal())
			comp.SentEvents = uint64(m.GetSentEventsTotal())
			comp.ReceivedBytes = uint64(m.GetReceivedBytesTotal())
			comp.SentBytes = uint64(m.GetSentBytesTotal())
		}
		// Vector's GetComponents proto doesn't expose errors_total or
		// discarded_events_total — those are only available via the streaming
		// StreamComponentMetrics RPC (MetricName.METRIC_NAME_ERRORS_TOTAL).
		// We leave comp.Errors / comp.Discarded zero rather than open a
		// long-lived stream just for those counts. Revisit if errors become
		// the operator's primary question.

		stats.Components = append(stats.Components, comp)
		stats.ComponentCount++
		switch comp.Kind {
		case "source":
			stats.SourceCount++
			stats.ReceivedEvents += comp.ReceivedEvents
			stats.ReceivedBytes += comp.ReceivedBytes
		case "transform":
			stats.TransformCount++
		case "sink":
			stats.SinkCount++
			stats.SentEvents += comp.SentEvents
			stats.SentBytes += comp.SentBytes
		}
	}

	return stats, nil
}

// componentKindString maps the proto enum to the lowercase strings the UI
// expects ("source" / "transform" / "sink"). Anything else (UNSPECIFIED or
// a future kind) becomes "unknown" so the UI doesn't have to learn new values.
func componentKindString(t vectorpb.ComponentType) string {
	switch t {
	case vectorpb.ComponentType_COMPONENT_TYPE_SOURCE:
		return "source"
	case vectorpb.ComponentType_COMPONENT_TYPE_TRANSFORM:
		return "transform"
	case vectorpb.ComponentType_COMPONENT_TYPE_SINK:
		return "sink"
	default:
		return "unknown"
	}
}
