// duck-api — a tiny, read-only HTTP wrapper that exposes the duck-report-*.sh
// reports as JSON over HTTP for an AI agent. It NEVER exposes DuckDB SQL: each
// route runs a FIXED report script with FORMAT=json and STRICTLY VALIDATED params.
// Stdlib only; runs -readonly as the unprivileged `duck` user behind nginx.
package main

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

//go:embed openapi.json
var openapiSpec []byte

// endpoint maps a route to one report script + what params it accepts. No script
// path or param ever comes from the request — only the values below + validated args.
type endpoint struct {
	script    string
	takesHost bool
	views     []string // allowed VIEW values; empty => endpoint takes no view
	defView   string
}

var endpoints = map[string]endpoint{
	"/v1/basics":    {"duck-report-basics.sh", true, []string{"host", "group"}, "host"},
	"/v1/capacity":  {"duck-report-capacity.sh", true, nil, ""},
	"/v1/haproxy":   {"duck-report-haproxy.sh", true, nil, ""},
	"/v1/conntrack": {"duck-report-conntrack.sh", true, nil, ""},
	"/v1/summary":   {"duck-report-summary.sh", false, []string{"usage", "forecast"}, "usage"},
	"/v1/cross":     {"duck-report-cross.sh", true, nil, ""},
}

// host glob: hostnames + the shell-glob wildcards the scripts understand. Deliberately
// excludes everything that could matter to a shell (we never use a shell, but defence in depth).
var hostRe = regexp.MustCompile(`^[A-Za-z0-9_.*?-]{1,64}$`)

// timestamp for from/to range mode: mirrors the validation in the report scripts
// ('YYYY-MM-DD' or 'YYYY-MM-DD HH:MM[:SS]', local time per the script's TZ_OFFSET).
// Restricted to digits + - : space T, so it is safe to pass as an argv element.
var tsRe = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$`)

type params struct {
	Hours int    `json:"hours,omitempty"`
	Host  string `json:"host,omitempty"`
	View  string `json:"view,omitempty"`
	From  string `json:"from,omitempty"`
	To    string `json:"to,omitempty"`
}

type envelope struct {
	Report      string            `json:"report"`
	Params      params            `json:"params"`
	GeneratedAt string            `json:"generated_at"`
	Sections    []json.RawMessage `json:"sections"`
}

var (
	scriptDir = env("API_SCRIPT_DIR", "/usr/local/bin")
	maxHours  = envInt("API_MAX_HOURS", 2160) // 90 days
	queryTO   = time.Duration(envInt("API_QUERY_TIMEOUT", 60)) * time.Second
	sem       = make(chan struct{}, envInt("API_MAX_CONCURRENCY", 4))
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("GET /openapi.json", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(openapiSpec)
	})
	mux.HandleFunc("GET /{$}", indexHandler) // service root (== /api/ after nginx strips the prefix)
	mux.HandleFunc("GET /v1", indexHandler)
	for path, ep := range endpoints {
		mux.HandleFunc("GET "+path, makeHandler(strings.TrimPrefix(path, "/v1/"), ep))
	}

	addr := env("API_LISTEN", ":8088")
	log.Printf("[duck-api] listening on %s scripts=%s max_hours=%d timeout=%s concurrency=%d",
		addr, scriptDir, maxHours, queryTO, cap(sem))
	srv := &http.Server{Addr: addr, Handler: logging(mux), ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func indexHandler(w http.ResponseWriter, _ *http.Request) {
	list := map[string]any{}
	for path, ep := range endpoints {
		e := map[string]any{"params": paramDoc(ep)}
		list[path] = e
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"service":   "duck-api",
		"endpoints": list,
		"openapi":   "/openapi.json",
		"note":      "read-only GET; window via ?hours=N (1.." + strconv.Itoa(maxHours) + ") or ?from=&to= (local time)",
	})
}

func paramDoc(ep endpoint) map[string]any {
	p := map[string]any{
		"hours": "int 1.." + strconv.Itoa(maxHours) + " (relative window; mutually exclusive with from/to)",
		"from":  "local ts 'YYYY-MM-DD[ HH:MM[:SS]]'; pair with to for an explicit range",
		"to":    "local ts 'YYYY-MM-DD[ HH:MM[:SS]]'; pair with from for an explicit range",
	}
	if ep.takesHost {
		p["host"] = "glob, default *"
	}
	if len(ep.views) > 0 {
		p["view"] = ep.views
	}
	return p
}

func makeHandler(report string, ep endpoint) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()

		// Window selection: either relative (?hours=N) or an explicit local-time
		// range (?from=...&to=...). The two are mutually exclusive; range mode
		// hands FROM/TO straight to the script's range form (arg1 not an integer).
		from, to := q.Get("from"), q.Get("to")
		rangeMode := from != "" || to != ""

		var hours int
		if rangeMode {
			if q.Get("hours") != "" {
				httpError(w, http.StatusBadRequest, "cannot combine 'hours' with 'from'/'to'")
				return
			}
			if from == "" || to == "" {
				httpError(w, http.StatusBadRequest, "range query needs both 'from' and 'to'")
				return
			}
			if !tsRe.MatchString(from) || !tsRe.MatchString(to) {
				httpError(w, http.StatusBadRequest, "from/to must be 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM[:SS]' (local time)")
				return
			}
		} else {
			var ok bool
			hours, ok = parseHours(q.Get("hours"))
			if !ok {
				httpError(w, http.StatusBadRequest, "hours must be an integer in 1.."+strconv.Itoa(maxHours))
				return
			}
		}

		host := q.Get("host")
		if ep.takesHost {
			if host == "" {
				host = "*"
			}
			if !hostRe.MatchString(host) {
				httpError(w, http.StatusBadRequest, "host must match "+hostRe.String())
				return
			}
		} else if host != "" {
			httpError(w, http.StatusBadRequest, "this report does not take a host param")
			return
		}

		view := q.Get("view")
		if len(ep.views) > 0 {
			if view == "" {
				view = ep.defView
			}
			if !contains(ep.views, view) {
				httpError(w, http.StatusBadRequest, "view must be one of "+strings.Join(ep.views, "|"))
				return
			}
		} else if view != "" {
			httpError(w, http.StatusBadRequest, "this report does not take a view param")
			return
		}

		// argv: never a shell. Args already validated above. In range mode the
		// script auto-selects its FROM/TO form because arg1 isn't a bare integer.
		var args []string
		if rangeMode {
			args = []string{from, to}
		} else {
			args = []string{strconv.Itoa(hours)}
		}
		if ep.takesHost {
			args = append(args, host)
		}

		ctx, cancel := context.WithTimeout(r.Context(), queryTO)
		defer cancel()

		// bound concurrent DuckDB execs so agent fan-out can't thrash the box
		select {
		case sem <- struct{}{}:
			defer func() { <-sem }()
		case <-ctx.Done():
			httpError(w, http.StatusServiceUnavailable, "busy")
			return
		}

		cmd := exec.CommandContext(ctx, filepath.Join(scriptDir, ep.script), args...)
		cmd.Env = append(os.Environ(), "FORMAT=json")
		if len(ep.views) > 0 {
			cmd.Env = append(cmd.Env, "VIEW="+view)
		}
		var stdout, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &stdout, &stderr

		if err := cmd.Run(); err != nil {
			// Log detail server-side; return a sanitized message (no stderr/paths to the client).
			log.Printf("[duck-api] %s failed: %v; stderr=%q", ep.script, err, truncate(stderr.String(), 500))
			if ctx.Err() == context.DeadlineExceeded {
				httpError(w, http.StatusGatewayTimeout, "report timed out")
			} else {
				httpError(w, http.StatusBadGateway, "report failed")
			}
			return
		}

		sections, err := splitJSONArrays(stdout.Bytes())
		if err != nil {
			log.Printf("[duck-api] %s produced non-JSON output: %v", ep.script, err)
			httpError(w, http.StatusBadGateway, "report produced unparseable output")
			return
		}

		writeJSON(w, http.StatusOK, envelope{
			Report:      report,
			Params:      params{Hours: hours, Host: hostFor(ep, host), View: view, From: from, To: to},
			GeneratedAt: time.Now().UTC().Format(time.RFC3339),
			Sections:    sections,
		})
	}
}

func hostFor(ep endpoint, host string) string {
	if ep.takesHost {
		return host
	}
	return ""
}

// splitJSONArrays reads the successive top-level JSON arrays a multi-statement
// FORMAT=json report emits (one array per SQL section) into a single slice.
func splitJSONArrays(b []byte) ([]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	out := []json.RawMessage{}
	for {
		var raw json.RawMessage
		err := dec.Decode(&raw)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		out = append(out, raw)
	}
	return out, nil
}

func parseHours(s string) (int, bool) {
	if s == "" {
		return 24, true // default window
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 || n > maxHours {
		return 0, false
	}
	return n, true
}

// --- small helpers ---

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	enc.Encode(v)
}

func httpError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// logging records method, path, query, status, and duration to stdout.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(c int) { s.status = c; s.ResponseWriter.WriteHeader(c) }

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		log.Printf("[duck-api] %s %s?%s -> %d (%s)", r.Method, r.URL.Path, r.URL.RawQuery, rec.status, time.Since(start).Round(time.Millisecond))
	})
}
