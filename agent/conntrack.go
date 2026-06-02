package agent

import (
	"bufio"
	"errors"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/henrygd/beszel/agent/utils"
	"github.com/henrygd/beszel/internal/entities/system"
)

// ConntrackManager collects netfilter connection-tracking table stats from /proc
// (Linux only). On non-Linux builds NewConntrackManager returns (nil, error) and
// the agent simply skips conntrack collection.
type ConntrackManager struct {
	sync.Mutex
	stats        *system.ConntrackStats
	lastUpdate   time.Time
	updatePeriod time.Duration

	consecutiveFailures int
	lastError           error
}

const conntrackDefaultUpdateInterval = 5 * time.Second

// NewConntrackManager returns a manager only when conntrack is usable on this host
// (Linux build AND the nf_conntrack module loaded). It auto-enables wherever the
// module is present — no env opt-in and no capability needed (the /proc files are
// world-readable), mirroring the IPVS auto-enable model. On other systems it
// returns (nil, error) and the caller should log-and-continue.
func NewConntrackManager() (*ConntrackManager, error) {
	if !conntrackAvailable() {
		return nil, errConntrackUnavailable
	}

	updatePeriod := conntrackDefaultUpdateInterval
	if intervalStr, exists := utils.GetEnv("CONNTRACK_UPDATE_INTERVAL"); exists {
		if d, err := time.ParseDuration(intervalStr); err == nil && d > 0 {
			updatePeriod = d
			slog.Info("Conntrack update interval configured", "duration", d)
		}
	}

	cm := &ConntrackManager{updatePeriod: updatePeriod}

	if _, err := cm.fetch(); err != nil {
		return nil, err
	}
	slog.Info("Conntrack monitoring enabled")
	return cm, nil
}

// GetStats returns a copy of the most recent conntrack snapshot, refreshing if
// stale. Returns nil if the manager has not yet collected any data.
func (cm *ConntrackManager) GetStats() *system.ConntrackStats {
	cm.Lock()
	defer cm.Unlock()

	if time.Since(cm.lastUpdate) > cm.updatePeriod {
		if stats, err := cm.fetch(); err == nil {
			cm.stats = stats
			cm.lastUpdate = time.Now()
			cm.consecutiveFailures = 0
			cm.lastError = nil
		} else {
			cm.consecutiveFailures++
			cm.lastError = err
			if cm.consecutiveFailures > 5 {
				slog.Warn("Conntrack collection persistently failing",
					"consecutiveFailures", cm.consecutiveFailures, "err", err)
			} else {
				slog.Debug("Conntrack fetch failed", "err", err)
			}
		}
	}

	if cm.stats == nil {
		return nil
	}
	// shallow copy is sufficient — ConntrackStats has no reference fields.
	c := *cm.stats
	return &c
}

// GetConnectionHealth exposes the consecutive failure count for diagnostics.
func (cm *ConntrackManager) GetConnectionHealth() (failures int, lastErr error) {
	cm.Lock()
	defer cm.Unlock()
	return cm.consecutiveFailures, cm.lastError
}

// parseConntrackStat sums the named per-CPU columns of a /proc/net/stat/nf_conntrack
// stream into st. The column set varies by kernel version, so we map header names
// to indices and only read the ones we care about (missing columns stay zero).
// Values are hexadecimal. Kept OS-agnostic (no /proc) so it's unit-testable.
func parseConntrackStat(r io.Reader, st *system.ConntrackStats) error {
	sc := bufio.NewScanner(r)
	if !sc.Scan() {
		return errors.New("empty nf_conntrack stat file")
	}
	idx := make(map[string]int)
	for i, name := range strings.Fields(sc.Text()) {
		idx[name] = i
	}
	want := map[string]*uint64{
		"found":          &st.Found,
		"invalid":        &st.Invalid,
		"insert_failed":  &st.InsertFailed,
		"drop":           &st.Drop,
		"early_drop":     &st.EarlyDrop,
		"search_restart": &st.SearchRestart,
	}
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		for name, dst := range want {
			i, ok := idx[name]
			if !ok || i >= len(fields) {
				continue
			}
			if v, perr := strconv.ParseUint(fields[i], 16, 64); perr == nil {
				*dst += v
			}
		}
	}
	return sc.Err()
}
