package systems

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/henrygd/beszel/internal/common"
	"github.com/henrygd/beszel/internal/entities/system"
)

// Conntrack DuckDB recorder.
//
// An always-on, UI-independent collector that samples netfilter conntrack table
// stats (cd.Stats.Conntrack) from every agent reporting them and appends one row
// per host to a sealed NDJSON spool. The loader (scripts/duck-conntrack-ingest.sh)
// ingests the spool into a dedicated DuckDB so conntrack pressure can be
// cross-queried against the HAProxy/capacity stores. Opt-in via CONNTRACK_DUCK_SPOOL.
//
// It reuses the HAProxy recorder's shared helpers in this package (spoolStream,
// sweepStats, parseDurationEnv, tsLayout) and the same private-buffer fetch
// (sys.fetchForRecorder) so it never races the realtime worker/updater. One row
// per host (no per-proxy explosion), so the volume is tiny — a slower default
// interval than HAProxy is plenty for table-fill trending.

const (
	defaultConntrackRecordInterval = 10 * time.Second
	defaultConntrackProbeInterval  = 60 * time.Second
	defaultConntrackSpoolRotate    = 60 * time.Second
	// conntrackMaxConcurrentFetch bounds simultaneous agent requests per sweep.
	conntrackMaxConcurrentFetch = 8
)

// conntrackRecorder owns the sampling loop and the single spool writer.
type conntrackRecorder struct {
	sm         *SystemManager
	interval   time.Duration
	probeEvery time.Duration

	spool *spoolStream

	mu      sync.Mutex
	members map[string]struct{} // system IDs known to report conntrack
	names   map[string]string   // system ID -> friendly hostname
}

// startConntrackRecorder self-gates on CONNTRACK_DUCK_SPOOL and, when set, runs
// the recorder loop forever. Safe to call unconditionally from Initialize.
func (sm *SystemManager) startConntrackRecorder() {
	spoolDir := os.Getenv("CONNTRACK_DUCK_SPOOL")
	if spoolDir == "" {
		return
	}
	if err := os.MkdirAll(spoolDir, 0o755); err != nil {
		sm.hub.Logger().Error("Conntrack recording disabled: cannot create spool dir", "dir", spoolDir, "err", err)
		return
	}

	rotate := parseDurationEnv("CONNTRACK_SPOOL_ROTATE", defaultConntrackSpoolRotate)
	r := &conntrackRecorder{
		sm:         sm,
		interval:   parseDurationEnv("CONNTRACK_RECORD_INTERVAL", defaultConntrackRecordInterval),
		probeEvery: parseDurationEnv("CONNTRACK_PROBE_INTERVAL", defaultConntrackProbeInterval),
		spool:      &spoolStream{dir: spoolDir, prefix: "conntrack", rotateEvery: rotate},
		members:    map[string]struct{}{},
		names:      map[string]string{},
	}
	// Seal any live file a previous process left behind so it gets ingested.
	r.spool.sealOrphan()

	sm.hub.Logger().Info("Conntrack recording enabled",
		"spool", spoolDir, "interval", r.interval.String(), "probe", r.probeEvery.String(), "rotate", rotate.String())
	// Also to stderr so it shows in `docker logs` (PB app logs go to the DB).
	log.Printf("[conntrack-recorder] enabled spool=%s interval=%s probe=%s rotate=%s",
		spoolDir, r.interval, r.probeEvery, rotate)
	r.run()
}

func (r *conntrackRecorder) run() {
	r.probe() // initial discovery so the first samples have members

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

// probe re-scans all systems to refresh the conntrack membership set and the
// id->hostname map, recording any data it sees along the way.
func (r *conntrackRecorder) probe() {
	r.refreshNames()

	members := make(map[string]struct{})
	var mu sync.Mutex
	var rows int64
	st := r.sweep(r.sm.systems.Values(), func(sys *System, cd *system.CombinedData) {
		if cd.Stats.Conntrack == nil {
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

	r.spool.flush()

	log.Printf("[conntrack-recorder] probe: systems=%d eligible=%d ok=%d failed=%d conntrack_members=%d rows=%d%s",
		st.total, st.eligible, st.ok, st.failed, len(members), rows, st.errSuffix())
}

// sample fetches only the known conntrack members (cheap steady state).
func (r *conntrackRecorder) sample() {
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
	r.spool.flush()

	if st.failed > 0 || rows == 0 {
		log.Printf("[conntrack-recorder] sample: members=%d ok=%d failed=%d rows=%d%s",
			len(ids), st.ok, st.failed, rows, st.errSuffix())
	}
}

// sweep fetches the given systems concurrently (bounded) into private buffers and
// calls fn for each successful response. Parallels haproxyRecorder.sweep; kept
// separate so the two recorders stay independent.
func (r *conntrackRecorder) sweep(systems []*System, fn func(*System, *system.CombinedData)) sweepStats {
	sem := make(chan struct{}, conntrackMaxConcurrentFetch)
	var wg sync.WaitGroup
	var eligible, ok, failed int64
	var errMu sync.Mutex
	var sampleErr string

	for _, sys := range systems {
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

// fetch issues a GetData request into a PRIVATE buffer (never the shared sys.data)
// via WebSocket or SSH, so it never races the realtime worker/updater.
func (r *conntrackRecorder) fetch(sys *System) (*system.CombinedData, error) {
	ctx, cancel := context.WithTimeout(context.Background(), r.interval)
	defer cancel()

	ms := min(r.interval.Milliseconds(), 65535)
	return sys.fetchForRecorder(ctx, common.DataRequestOptions{CacheTimeMs: uint16(ms)})
}

// emit writes one NDJSON line for the host's conntrack snapshot. All fields are
// always present (no omitempty) so DuckDB's read_json_auto sees a stable schema.
func (r *conntrackRecorder) emit(systemID string, cd *system.CombinedData) int {
	ct := cd.Stats.Conntrack
	if ct == nil {
		return 0
	}
	ts := time.Now().UTC().Format(tsLayout)

	r.mu.Lock()
	host := r.names[systemID]
	r.mu.Unlock()
	if host == "" {
		host = systemID
	}

	row := conntrackRow{
		TS: ts, System: systemID, Host: host,
		Conns: ct.Count, ConnsMax: ct.Max, Found: ct.Found, Invalid: ct.Invalid,
		InsertFailed: ct.InsertFailed, PktDrop: ct.Drop, EarlyDrop: ct.EarlyDrop, SearchRestart: ct.SearchRestart,
	}
	if b, err := json.Marshal(&row); err == nil {
		if r.spool.writeLine(b) == nil {
			return 1
		}
	}
	return 0
}

// refreshNames rebuilds the system ID -> friendly hostname map (one cheap query
// per probe) so spool rows carry a human-readable host.
func (r *conntrackRecorder) refreshNames() {
	var rows []struct {
		Id   string `db:"id"`
		Name string `db:"name"`
	}
	if err := r.sm.hub.DB().NewQuery("SELECT id, name FROM systems").All(&rows); err != nil {
		r.sm.hub.Logger().Warn("Conntrack recorder: hostname refresh failed", "err", err)
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

// conntrackRow is one per-host conntrack sample. Mirrors system.ConntrackStats
// with DuckDB-friendly column names — deliberately avoiding the SQL reserved/
// function words count/max/drop so report queries need no quoting. util% is
// derived at query time (100*conns/conns_max).
type conntrackRow struct {
	TS            string `json:"ts"`
	System        string `json:"system"`
	Host          string `json:"host"`
	Conns         uint64 `json:"conns"`          // nf_conntrack_count (current entries)
	ConnsMax      uint64 `json:"conns_max"`      // nf_conntrack_max (table limit)
	Found         uint64 `json:"found"`          // cumulative
	Invalid       uint64 `json:"invalid"`        // cumulative
	InsertFailed  uint64 `json:"insert_failed"`  // cumulative
	PktDrop       uint64 `json:"pkt_drop"`       // cumulative: packets dropped (table full)
	EarlyDrop     uint64 `json:"early_drop"`     // cumulative
	SearchRestart uint64 `json:"search_restart"` // cumulative
}
