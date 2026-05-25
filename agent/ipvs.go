package agent

import (
	"log/slog"
	"sync"
	"time"

	"github.com/henrygd/beszel/agent/utils"
	"github.com/henrygd/beszel/internal/entities/system"
)

// IPVSManager collects LVS / IPVS stats via netlink (Linux only).
// On non-Linux builds, NewIPVSManager returns nil and the agent simply skips IPVS collection.
type IPVSManager struct {
	sync.Mutex
	stats        *system.IPVSStats
	lastUpdate   time.Time
	updatePeriod time.Duration

	consecutiveFailures int
	lastError           error
}

const ipvsDefaultUpdateInterval = 5 * time.Second

// NewIPVSManager returns a manager only when IPVS is usable on this host
// (Linux build AND kernel module loaded AND at least one virtual service or
// IPVS_FORCE=1). On other systems it returns (nil, error) and the caller
// should log-and-continue.
func NewIPVSManager() (*IPVSManager, error) {
	if !ipvsAvailable() {
		return nil, errIPVSUnavailable
	}

	updatePeriod := ipvsDefaultUpdateInterval
	if intervalStr, exists := utils.GetEnv("IPVS_UPDATE_INTERVAL"); exists {
		if d, err := time.ParseDuration(intervalStr); err == nil && d > 0 {
			updatePeriod = d
			slog.Info("IPVS update interval configured", "duration", d)
		}
	}

	im := &IPVSManager{updatePeriod: updatePeriod}

	if _, err := im.fetch(); err != nil {
		return nil, err
	}
	slog.Info("IPVS monitoring enabled")
	return im, nil
}

// GetStats returns a copy of the most recent IPVS snapshot, refreshing if stale.
// Returns nil if the manager has not yet collected any data.
func (im *IPVSManager) GetStats() *system.IPVSStats {
	im.Lock()
	defer im.Unlock()

	if time.Since(im.lastUpdate) > im.updatePeriod {
		if stats, err := im.fetch(); err == nil {
			im.stats = stats
			im.lastUpdate = time.Now()
			im.consecutiveFailures = 0
			im.lastError = nil
		} else {
			im.consecutiveFailures++
			im.lastError = err
			if im.consecutiveFailures > 5 {
				slog.Warn("IPVS collection persistently failing",
					"consecutiveFailures", im.consecutiveFailures, "err", err)
			} else {
				slog.Debug("IPVS fetch failed", "err", err)
			}
		}
	}

	if im.stats == nil {
		return nil
	}
	// shallow copy is sufficient — Stats is encoded immediately after this call
	// and the underlying slices are not mutated in place.
	c := *im.stats
	return &c
}

// GetConnectionHealth exposes the consecutive failure count for diagnostics.
func (im *IPVSManager) GetConnectionHealth() (failures int, lastErr error) {
	im.Lock()
	defer im.Unlock()
	return im.consecutiveFailures, im.lastError
}
