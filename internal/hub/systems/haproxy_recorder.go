package systems

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/henrygd/beszel/internal/common"
	"github.com/henrygd/beszel/internal/entities/system"
	"github.com/henrygd/beszel/internal/hub/transport"
)

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

	r := &haproxyRecorder{
		sm:         sm,
		interval:   parseDurationEnv("HAPROXY_RECORD_INTERVAL", defaultHAProxyRecordInterval),
		probeEvery: parseDurationEnv("HAPROXY_PROBE_INTERVAL", defaultHAProxyProbeInterval),
		proxies:    &spoolStream{dir: spoolDir, prefix: "haproxy_proxies"},
		info:       &spoolStream{dir: spoolDir, prefix: "haproxy_info"},
		members:    map[string]struct{}{},
		names:      map[string]string{},
	}

	sm.hub.Logger().Info("HAProxy recording enabled",
		"spool", spoolDir, "interval", r.interval.String(), "probe", r.probeEvery.String())
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
	r.sweep(r.sm.systems.Values(), func(sys *System, cd *system.CombinedData) {
		if len(cd.Stats.HAProxy) == 0 && cd.Stats.HAProxyInfo == nil {
			return
		}
		mu.Lock()
		members[sys.Id] = struct{}{}
		mu.Unlock()
		r.emit(sys.Id, cd)
	})

	r.mu.Lock()
	r.members = members
	r.mu.Unlock()

	r.proxies.flush()
	r.info.flush()
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

	r.sweep(systems, func(sys *System, cd *system.CombinedData) {
		r.emit(sys.Id, cd)
	})
	r.proxies.flush()
	r.info.flush()
}

// sweep fetches the given systems concurrently (bounded) and calls fn for each
// successful response.
func (r *haproxyRecorder) sweep(systems []*System, fn func(*System, *system.CombinedData)) {
	sem := make(chan struct{}, haproxyMaxConcurrentFetch)
	var wg sync.WaitGroup
	for _, sys := range systems {
		conn := sys.WsConn
		if sys.Status != up || conn == nil || !conn.IsConnected() {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(sys *System) {
			defer wg.Done()
			defer func() { <-sem }()
			cd, err := r.fetch(sys)
			if err != nil || cd == nil {
				return
			}
			fn(sys, cd)
		}(sys)
	}
	wg.Wait()
}

// fetch issues a GetData request into a PRIVATE buffer so it never races with
// the realtime worker / updater which mutate the shared sys.data.
func (r *haproxyRecorder) fetch(sys *System) (*system.CombinedData, error) {
	t := transport.NewWebSocketTransport(sys.WsConn)
	ctx, cancel := context.WithTimeout(context.Background(), r.interval)
	defer cancel()

	ms := min(r.interval.Milliseconds(), 65535)
	var cd system.CombinedData
	if err := t.Request(ctx, common.GetData, common.DataRequestOptions{CacheTimeMs: uint16(ms)}, &cd); err != nil {
		return nil, err
	}
	return &cd, nil
}

// emit writes one NDJSON line per HAProxy proxy entry plus one per-host info
// line. All fields are always present (no omitempty) so DuckDB's read_json_auto
// sees a stable schema.
func (r *haproxyRecorder) emit(systemID string, cd *system.CombinedData) {
	ts := time.Now().UTC().Format(tsLayout)

	r.mu.Lock()
	host := r.names[systemID]
	r.mu.Unlock()
	if host == "" {
		host = systemID
	}

	for i := range cd.Stats.HAProxy {
		h := &cd.Stats.HAProxy[i]
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
			_ = r.proxies.writeLine(b)
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
			_ = r.info.writeLine(b)
		}
	}
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

// spoolStream is a mutex-guarded, daily-rotated, buffered NDJSON appender.
type spoolStream struct {
	dir    string
	prefix string

	mu   sync.Mutex
	date string
	f    *os.File
	w    *bufio.Writer
}

func (s *spoolStream) writeLine(b []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	today := time.Now().UTC().Format("20060102")
	if today != s.date || s.f == nil {
		if s.w != nil {
			_ = s.w.Flush()
		}
		if s.f != nil {
			_ = s.f.Close()
		}
		path := filepath.Join(s.dir, s.prefix+"-"+today+".ndjson")
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			s.f, s.w = nil, nil
			return err
		}
		s.f = f
		s.w = bufio.NewWriter(f)
		s.date = today
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
