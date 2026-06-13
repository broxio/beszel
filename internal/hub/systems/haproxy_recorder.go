package systems

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/henrygd/beszel/internal/common"
	"github.com/henrygd/beszel/internal/entities/system"
)

// errNoRecorderTransport is returned by fetchForRecorder when a system has
// neither a connected WebSocket nor an existing SSH client to reuse.
var errNoRecorderTransport = errors.New("no usable transport for recorder")

// HAProxy DuckDB recorder.
//
// An always-on, UI-independent collector that samples HAProxy stats from every
// agent reporting them and appends them to a daily-rotated NDJSON spool. A
// separate loader (scripts/duck-haproxy-ingest.sh) ingests the spool into a
// dedicated DuckDB for troubleshooting. Opt-in via HAPROXY_DUCK_SPOOL.
//
// Unlike the realtime worker (system_realtime.go), which only runs while a
// browser is subscribed and never persists, this records continuously. It
// issues its own GetData request into a PRIVATE buffer (not the shared
// sys.data) so it can run concurrently with the realtime worker without a
// data race — the WS connection multiplexes in-flight requests by id
// (internal/hub/ws/request_manager.go).

const (
	defaultHAProxyRecordInterval = 2 * time.Second
	defaultHAProxyProbeInterval  = 60 * time.Second
	defaultHAProxySpoolRotate    = 60 * time.Second
	// haproxyMaxConcurrentFetch bounds simultaneous agent requests per sweep.
	haproxyMaxConcurrentFetch = 8
	// tsLayout is fixed-width millisecond-precision UTC ISO-8601 so DuckDB's
	// read_json_auto infers a TIMESTAMP and the (system, ts, proxy, type) PK
	// stays unique even at sub-second intervals.
	tsLayout = "2006-01-02T15:04:05.000Z"
)

// haproxyRecorder owns the sampling loop and spool writers.
type haproxyRecorder struct {
	sm         *SystemManager
	interval   time.Duration
	probeEvery time.Duration

	proxies *spoolStream
	info    *spoolStream

	recordTypes map[string]bool // which HAProxy row types to record (uppercased)

	mu      sync.Mutex
	members map[string]struct{} // system IDs known to report HAProxy
	names   map[string]string   // system ID -> friendly hostname (for readable rows)
}

// startHAProxyRecorder self-gates on HAPROXY_DUCK_SPOOL and, when set, runs the
// recorder loop forever. Safe to call unconditionally from Initialize.
func (sm *SystemManager) startHAProxyRecorder() {
	spoolDir := os.Getenv("HAPROXY_DUCK_SPOOL")
	if spoolDir == "" {
		return
	}
	if err := os.MkdirAll(spoolDir, 0o755); err != nil {
		sm.hub.Logger().Error("HAProxy recording disabled: cannot create spool dir", "dir", spoolDir, "err", err)
		return
	}

	rotate := parseDurationEnv("HAPROXY_SPOOL_ROTATE", defaultHAProxySpoolRotate)
	r := &haproxyRecorder{
		sm:          sm,
		interval:    parseDurationEnv("HAPROXY_RECORD_INTERVAL", defaultHAProxyRecordInterval),
		probeEvery:  parseDurationEnv("HAPROXY_PROBE_INTERVAL", defaultHAProxyProbeInterval),
		proxies:     &spoolStream{dir: spoolDir, prefix: "haproxy_proxies", rotateEvery: rotate},
		info:        &spoolStream{dir: spoolDir, prefix: "haproxy_info", rotateEvery: rotate},
		recordTypes: parseTypesEnv("HAPROXY_RECORD_TYPES", []string{"FRONTEND", "BACKEND"}),
		members:     map[string]struct{}{},
		names:       map[string]string{},
	}
	// Seal any live files a previous process left behind so they get ingested.
	r.proxies.sealOrphan()
	r.info.sealOrphan()

	types := make([]string, 0, len(r.recordTypes))
	for t := range r.recordTypes {
		types = append(types, t)
	}
	sort.Strings(types)
	typesStr := strings.Join(types, ",")

	sm.hub.Logger().Info("HAProxy recording enabled",
		"spool", spoolDir, "interval", r.interval.String(), "probe", r.probeEvery.String(),
		"rotate", rotate.String(), "types", typesStr)
	// Also log to stderr so it's visible in `docker logs` (PocketBase app logs go
	// to the DB Logs table, not stdout).
	log.Printf("[haproxy-recorder] enabled spool=%s interval=%s probe=%s rotate=%s types=%s",
		spoolDir, r.interval, r.probeEvery, rotate, typesStr)
	r.run()
}

func (r *haproxyRecorder) run() {
	// initial discovery so the first samples have members to read
	r.probe()

	sampleTick := time.NewTicker(r.interval)
	probeTick := time.NewTicker(r.probeEvery)
	defer sampleTick.Stop()
	defer probeTick.Stop()

	for {
		select {
		case <-probeTick.C:
			r.probe()
		case <-sampleTick.C:
			r.sample()
		}
	}
}

// probe re-scans all systems to refresh the HAProxy membership set and the
// id->hostname map, recording any data it sees in the process.
func (r *haproxyRecorder) probe() {
	r.refreshNames()

	members := make(map[string]struct{})
	var mu sync.Mutex
	var rows int64
	st := r.sweep(r.sm.systems.Values(), func(sys *System, cd *system.CombinedData) {
		if len(cd.Stats.HAProxy) == 0 && cd.Stats.HAProxyInfo == nil {
			return
		}
		mu.Lock()
		members[sys.Id] = struct{}{}
		mu.Unlock()
		atomic.AddInt64(&rows, int64(r.emit(sys.Id, cd)))
	})

	r.mu.Lock()
	r.members = members
	r.mu.Unlock()

	r.proxies.flush()
	r.info.flush()

	// Always log the probe summary (low volume, every probe interval). This is
	// the main diagnostic: members=0 means no agent returned HAProxy data;
	// failed>0 with a sample error means the fetch transport is failing.
	log.Printf("[haproxy-recorder] probe: systems=%d eligible=%d ok=%d failed=%d haproxy_members=%d rows=%d%s",
		st.total, st.eligible, st.ok, st.failed, len(members), rows, st.errSuffix())
}

// sample fetches only the known HAProxy members (cheap steady state).
func (r *haproxyRecorder) sample() {
	r.mu.Lock()
	ids := make([]string, 0, len(r.members))
	for id := range r.members {
		ids = append(ids, id)
	}
	r.mu.Unlock()
	if len(ids) == 0 {
		return
	}

	systems := make([]*System, 0, len(ids))
	for _, id := range ids {
		if sys, ok := r.sm.systems.GetOk(id); ok {
			systems = append(systems, sys)
		}
	}

	var rows int64
	st := r.sweep(systems, func(sys *System, cd *system.CombinedData) {
		atomic.AddInt64(&rows, int64(r.emit(sys.Id, cd)))
	})
	r.proxies.flush()
	r.info.flush()

	// Quiet on the happy path; only log when something looks wrong (a stall or
	// fetch failures) so we don't flood docker logs every interval.
	if st.failed > 0 || rows == 0 {
		log.Printf("[haproxy-recorder] sample: members=%d ok=%d failed=%d rows=%d%s",
			len(ids), st.ok, st.failed, rows, st.errSuffix())
	}
}

// sweepStats summarizes one sweep for logging.
type sweepStats struct {
	total     int
	eligible  int
	ok        int
	failed    int
	sampleErr string
}

func (s sweepStats) errSuffix() string {
	if s.sampleErr == "" {
		return ""
	}
	return " err=\"" + s.sampleErr + "\""
}

// sweep fetches the given systems concurrently (bounded) and calls fn for each
// successful response, returning counts for diagnostics.
func (r *haproxyRecorder) sweep(systems []*System, fn func(*System, *system.CombinedData)) sweepStats {
	sem := make(chan struct{}, haproxyMaxConcurrentFetch)
	var wg sync.WaitGroup
	var eligible, ok, failed int64
	var errMu sync.Mutex
	var sampleErr string

	for _, sys := range systems {
		// Skip systems that aren't up or have no usable transport (neither a
		// connected WebSocket nor an existing SSH client to reuse).
		if sys.Status != up {
			continue
		}
		wsUp := sys.WsConn != nil && sys.WsConn.IsConnected()
		if !wsUp && sys.client == nil {
			continue
		}
		atomic.AddInt64(&eligible, 1)
		wg.Add(1)
		sem <- struct{}{}
		go func(sys *System) {
			defer wg.Done()
			defer func() { <-sem }()
			cd, err := r.fetch(sys)
			if err != nil || cd == nil {
				atomic.AddInt64(&failed, 1)
				if err != nil {
					errMu.Lock()
					if sampleErr == "" {
						sampleErr = sys.Host + ": " + err.Error()
					}
					errMu.Unlock()
				}
				return
			}
			atomic.AddInt64(&ok, 1)
			fn(sys, cd)
		}(sys)
	}
	wg.Wait()
	return sweepStats{
		total:     len(systems),
		eligible:  int(eligible),
		ok:        int(ok),
		failed:    int(failed),
		sampleErr: sampleErr,
	}
}

// fetch issues a GetData request into a PRIVATE buffer (never the shared
// sys.data) via WebSocket or SSH, so it never races the realtime worker/updater.
func (r *haproxyRecorder) fetch(sys *System) (*system.CombinedData, error) {
	ctx, cancel := context.WithTimeout(context.Background(), r.interval)
	defer cancel()

	ms := min(r.interval.Milliseconds(), 65535)
	return sys.fetchForRecorder(ctx, common.DataRequestOptions{CacheTimeMs: uint16(ms)})
}

// emit writes one NDJSON line per HAProxy proxy entry plus one per-host info
// line. All fields are always present (no omitempty) so DuckDB's read_json_auto
// sees a stable schema.
func (r *haproxyRecorder) emit(systemID string, cd *system.CombinedData) int {
	ts := time.Now().UTC().Format(tsLayout)

	r.mu.Lock()
	host := r.names[systemID]
	r.mu.Unlock()
	if host == "" {
		host = systemID
	}

	written := 0
	for i := range cd.Stats.HAProxy {
		h := &cd.Stats.HAProxy[i]
		// Volume control: skip row types we're not recording. SERVER rows (one
		// per backend server, per sample) dominate the spool, so they're off by
		// default — set HAPROXY_RECORD_TYPES=FRONTEND,BACKEND,SERVER to include.
		if !r.recordTypes[strings.ToUpper(h.Type)] {
			continue
		}
		row := haproxyProxyRow{
			TS: ts, System: systemID, Host: host,
			Proxy: h.Name, Type: h.Type, Status: h.Status,
			Scur: h.CurrentSess, Smax: h.MaxSess, Slim: h.SessionLimit, Stot: h.TotalSess,
			Bin: h.BytesIn, Bout: h.BytesOut, BinRate: h.BytesInRate, BoutRate: h.BytesOutRate,
			ReqRate: h.RequestRate, ReqTot: h.RequestTotal, Rtime: h.ResponseTime,
			Hrsp1xx: h.Resp1xx, Hrsp2xx: h.Resp2xx, Hrsp3xx: h.Resp3xx, Hrsp4xx: h.Resp4xx, Hrsp5xx: h.Resp5xx,
			Hrsp1xxRate: h.Resp1xxRate, Hrsp2xxRate: h.Resp2xxRate, Hrsp3xxRate: h.Resp3xxRate,
			Hrsp4xxRate: h.Resp4xxRate, Hrsp5xxRate: h.Resp5xxRate,
			HchkFail: h.HealthCheckFail, ActSrv: h.ActiveServers, BckSrv: h.BackupServers,
		}
		if b, err := json.Marshal(&row); err == nil {
			if r.proxies.writeLine(b) == nil {
				written++
			}
		}
	}

	if hi := cd.Stats.HAProxyInfo; hi != nil {
		row := haproxyInfoRow{
			TS: ts, System: systemID, Host: host,
			Version: hi.Version, UptimeSec: hi.UptimeSec,
			Maxconn: hi.Maxconn, Nbthread: hi.Nbthread,
			CurrConns: hi.CurrConns, CumConns: hi.CumConns, CumReq: hi.CumReq,
			ConnRate: hi.ConnRate, MaxConnRate: hi.MaxConnRate,
			SessRate: hi.SessRate, MaxSessRate: hi.MaxSessRate,
			CurrSslConns: hi.CurrSslConns, SslRate: hi.SslRate,
			Tasks: hi.Tasks, RunQueue: hi.RunQueue, IdlePct: hi.IdlePct,
			PoolAllocMB: hi.PoolAllocMB, PoolUsedMB: hi.PoolUsedMB, MemMaxMB: hi.MemMaxMB,
			BytesOutTot: hi.TotalBytesOut, BytesOutRate: hi.BytesOutRate,
		}
		if b, err := json.Marshal(&row); err == nil {
			if r.info.writeLine(b) == nil {
				written++
			}
		}
	}
	return written
}

// refreshNames rebuilds the system ID -> friendly hostname map (one cheap query
// per probe) so spool rows carry a human-readable host.
func (r *haproxyRecorder) refreshNames() {
	var rows []struct {
		Id   string `db:"id"`
		Name string `db:"name"`
	}
	if err := r.sm.hub.DB().NewQuery("SELECT id, name FROM systems").All(&rows); err != nil {
		r.sm.hub.Logger().Warn("HAProxy recorder: hostname refresh failed", "err", err)
		return
	}
	names := make(map[string]string, len(rows))
	for _, x := range rows {
		names[x.Id] = x.Name
	}
	r.mu.Lock()
	r.names = names
	r.mu.Unlock()
}

// parseTypesEnv parses a comma-separated, case-insensitive list of HAProxy row
// types (FRONTEND/BACKEND/SERVER) into a set. Empty/unset falls back to def.
func parseTypesEnv(key string, def []string) map[string]bool {
	m := map[string]bool{}
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		for _, t := range def {
			m[strings.ToUpper(t)] = true
		}
		return m
	}
	for _, t := range strings.Split(v, ",") {
		if t = strings.ToUpper(strings.TrimSpace(t)); t != "" {
			m[t] = true
		}
	}
	return m
}

func parseDurationEnv(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return def
}

// haproxyProxyRow is one frontend/backend/server sample. Mirrors HAProxyStats
// (internal/entities/system/system.go) with DuckDB-friendly column names.
type haproxyProxyRow struct {
	TS          string `json:"ts"`
	System      string `json:"system"`
	Host        string `json:"host"`
	Proxy       string `json:"proxy"`
	Type        string `json:"type"`
	Status      string `json:"status"`
	Scur        uint64 `json:"scur"`
	Smax        uint64 `json:"smax"`
	Slim        uint64 `json:"slim"`
	Stot        uint64 `json:"stot"`
	Bin         uint64 `json:"bin"`
	Bout        uint64 `json:"bout"`
	BinRate     uint64 `json:"bin_rate"`
	BoutRate    uint64 `json:"bout_rate"`
	ReqRate     uint64 `json:"req_rate"`
	ReqTot      uint64 `json:"req_tot"`
	Rtime       uint64 `json:"rtime"`
	Hrsp1xx     uint64 `json:"hrsp_1xx"`
	Hrsp2xx     uint64 `json:"hrsp_2xx"`
	Hrsp3xx     uint64 `json:"hrsp_3xx"`
	Hrsp4xx     uint64 `json:"hrsp_4xx"`
	Hrsp5xx     uint64 `json:"hrsp_5xx"`
	Hrsp1xxRate uint64 `json:"hrsp_1xx_rate"`
	Hrsp2xxRate uint64 `json:"hrsp_2xx_rate"`
	Hrsp3xxRate uint64 `json:"hrsp_3xx_rate"`
	Hrsp4xxRate uint64 `json:"hrsp_4xx_rate"`
	Hrsp5xxRate uint64 `json:"hrsp_5xx_rate"`
	HchkFail    uint64 `json:"hchk_fail"`
	ActSrv      uint64 `json:"act_srv"`
	BckSrv      uint64 `json:"bck_srv"`
}

// haproxyInfoRow is one per-host process sample. Mirrors HAProxyInfo.
type haproxyInfoRow struct {
	TS           string `json:"ts"`
	System       string `json:"system"`
	Host         string `json:"host"`
	Version      string `json:"version"`
	UptimeSec    uint64 `json:"uptime_sec"`
	Maxconn      uint64 `json:"maxconn"`
	Nbthread     uint64 `json:"nbthread"`
	CurrConns    uint64 `json:"curr_conns"`
	CumConns     uint64 `json:"cum_conns"`
	CumReq       uint64 `json:"cum_req"`
	ConnRate     uint64 `json:"conn_rate"`
	MaxConnRate  uint64 `json:"max_conn_rate"`
	SessRate     uint64 `json:"sess_rate"`
	MaxSessRate  uint64 `json:"max_sess_rate"`
	CurrSslConns uint64 `json:"curr_ssl_conns"`
	SslRate      uint64 `json:"ssl_rate"`
	Tasks        uint64 `json:"tasks"`
	RunQueue     uint64 `json:"run_queue"`
	IdlePct      uint64 `json:"idle_pct"`
	PoolAllocMB  uint64 `json:"pool_alloc_mb"`
	PoolUsedMB   uint64 `json:"pool_used_mb"`
	MemMaxMB     uint64 `json:"mem_max_mb"`
	BytesOutTot  uint64 `json:"bytes_out_tot"`
	BytesOutRate uint64 `json:"bytes_out_rate"`
}

// spoolStream is a mutex-guarded, buffered NDJSON appender that the loader can
// safely consume-and-delete. It writes to a single "<prefix>.live.ndjson" and
// every rotateEvery seals it: flush, close, and atomically rename to a complete
// "<prefix>-<UTCstamp>-<seq>.ndjson". The hub NEVER writes a sealed file again,
// so the loader can ingest sealed files and delete them with zero gap. The live
// file (which the loader ignores) holds at most rotateEvery of data.
type spoolStream struct {
	dir         string
	prefix      string
	rotateEvery time.Duration

	mu       sync.Mutex
	f        *os.File
	w        *bufio.Writer
	openedAt time.Time
	seq      uint64
}

func (s *spoolStream) livePath() string {
	return filepath.Join(s.dir, s.prefix+".live.ndjson")
}

// sealLocked flushes/closes the live file and renames it to a unique sealed name.
// Caller must hold s.mu.
func (s *spoolStream) sealLocked() {
	if s.f == nil {
		return
	}
	_ = s.w.Flush()
	_ = s.f.Close()
	s.f, s.w = nil, nil
	s.seq++
	sealed := filepath.Join(s.dir, fmt.Sprintf("%s-%s-%d.ndjson",
		s.prefix, time.Now().UTC().Format("20060102T150405"), s.seq))
	_ = os.Rename(s.livePath(), sealed)
}

// sealOrphan seals a stale live file left by a previous process at startup, so it
// gets ingested rather than lingering.
func (s *spoolStream) sealOrphan() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := os.Stat(s.livePath()); err == nil {
		s.seq++
		sealed := filepath.Join(s.dir, fmt.Sprintf("%s-%s-orphan%d.ndjson",
			s.prefix, time.Now().UTC().Format("20060102T150405"), s.seq))
		_ = os.Rename(s.livePath(), sealed)
	}
}

func (s *spoolStream) writeLine(b []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	if s.f != nil && s.rotateEvery > 0 && now.Sub(s.openedAt) >= s.rotateEvery {
		s.sealLocked()
	}
	if s.f == nil {
		f, err := os.OpenFile(s.livePath(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		s.f = f
		s.w = bufio.NewWriter(f)
		s.openedAt = now
	}

	if _, err := s.w.Write(b); err != nil {
		return err
	}
	return s.w.WriteByte('\n')
}

func (s *spoolStream) flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.w != nil {
		_ = s.w.Flush()
	}
}
