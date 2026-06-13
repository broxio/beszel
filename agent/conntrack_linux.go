//go:build linux

package agent

import (
	"errors"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"github.com/henrygd/beszel/internal/entities/system"
)

const (
	conntrackCountPath = "/proc/sys/net/netfilter/nf_conntrack_count"
	conntrackMaxPath   = "/proc/sys/net/netfilter/nf_conntrack_max"
	conntrackStatPath  = "/proc/net/stat/nf_conntrack"
)

var errConntrackUnavailable = errors.New("conntrack not available (/proc/sys/net/netfilter/nf_conntrack_count missing — module not loaded)")

// conntrackAvailable reports whether the nf_conntrack module is loaded. The
// /proc/sys entry only appears once the module is active; checking it is cheaper
// than reading and avoids noise on hosts that don't track connections.
func conntrackAvailable() bool {
	_, err := os.Stat(conntrackCountPath)
	return err == nil
}

// fetch reads the conntrack table gauges plus the cumulative per-CPU counters.
// Every read is a small /proc file — it NEVER scans the full conntrack table
// (/proc/net/nf_conntrack, which can be millions of lines on a busy LB).
func (cm *ConntrackManager) fetch() (*system.ConntrackStats, error) {
	count, err := readUintFile(conntrackCountPath)
	if err != nil {
		return nil, err
	}
	max, err := readUintFile(conntrackMaxPath)
	if err != nil {
		return nil, err
	}
	st := &system.ConntrackStats{Count: count, Max: max}
	// per-CPU counters are best-effort: a parse miss must not drop count/max.
	if err := readConntrackStat(st); err != nil {
		slog.Debug("conntrack stat parse", "err", err)
	}
	return st, nil
}

// readUintFile reads a single decimal integer from a /proc/sys file.
func readUintFile(path string) (uint64, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
}

// readConntrackStat opens /proc/net/stat/nf_conntrack and sums its per-CPU
// counters into st (see parseConntrackStat for the column handling).
func readConntrackStat(st *system.ConntrackStats) error {
	f, err := os.Open(conntrackStatPath)
	if err != nil {
		return err
	}
	defer f.Close()
	return parseConntrackStat(f, st)
}
