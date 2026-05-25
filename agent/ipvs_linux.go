//go:build linux

package agent

import (
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sort"
	"strings"
	"syscall"

	"github.com/henrygd/beszel/internal/entities/system"
	"github.com/moby/ipvs"
)

var errIPVSUnavailable = errors.New("IPVS kernel module not loaded (/proc/net/ip_vs missing)")

// ipvsAvailable returns true when the ip_vs kernel module is present.
// The /proc entry only appears once the module is loaded — checking it is
// cheaper than opening a netlink socket and avoids spurious errors on hosts
// that aren't load balancers.
func ipvsAvailable() bool {
	_, err := os.Stat("/proc/net/ip_vs")
	return err == nil
}

// fetch pulls the current IPVS state via netlink and classifies this host's role.
func (im *IPVSManager) fetch() (*system.IPVSStats, error) {
	h, err := ipvs.New("")
	if err != nil {
		return nil, fmt.Errorf("ipvs handle: %w", err)
	}
	defer h.Close()

	services, err := h.GetServices()
	if err != nil {
		return nil, fmt.Errorf("ipvs services: %w", err)
	}

	stats := &system.IPVSStats{
		Services:   make([]system.IPVSService, 0, len(services)),
		VirtualIPs: nil,
	}
	vipSet := make(map[string]struct{}, len(services))

	for _, svc := range services {
		vip := svc.Address.String()
		vipSet[vip] = struct{}{}

		dests, derr := h.GetDestinations(svc)
		if derr != nil {
			// Don't fail the whole collection for one bad service.
			slog.Debug("IPVS destinations fetch failed", "vip", vip, "err", derr)
			dests = nil
		}

		ipvsDests := make([]system.IPVSDest, 0, len(dests))
		var svcInactive uint32
		var fwdMode string
		for _, d := range dests {
			mode := forwardMode(d.ConnectionFlags)
			if fwdMode == "" {
				fwdMode = mode
			}
			svcInactive += uint32(d.InactiveConnections)
			ipvsDests = append(ipvsDests, system.IPVSDest{
				Address:       d.Address.String(),
				Port:          d.Port,
				Weight:        int32(d.Weight),
				ForwardMode:   mode,
				ActiveConns:   uint32(d.ActiveConnections),
				InactiveConns: uint32(d.InactiveConnections),
				ConnRate:      uint64(d.Stats.CPS),
				BytesInRate:   uint64(d.Stats.BPSIn),
				BytesOutRate:  uint64(d.Stats.BPSOut),
			})
		}

		ipvsSvc := system.IPVSService{
			VIP:           vip,
			Port:          svc.Port,
			Protocol:      protocolName(svc.Protocol),
			Scheduler:     svc.SchedName,
			ForwardMode:   fwdMode,
			ActiveConns:   svc.Stats.Connections, // current active from kernel estimator
			InactiveConns: svcInactive,            // summed from destinations (service-level has no inactive)
			ConnRate:      uint64(svc.Stats.CPS),
			BytesInRate:   uint64(svc.Stats.BPSIn),
			BytesOutRate:  uint64(svc.Stats.BPSOut),
			PktInRate:     uint64(svc.Stats.PPSIn),
			PktOutRate:    uint64(svc.Stats.PPSOut),
			TotalBytesIn:  svc.Stats.BytesIn,
			TotalBytesOut: svc.Stats.BytesOut,
			TotalConns:    uint64(svc.Stats.Connections),
			Destinations:  ipvsDests,
		}
		stats.Services = append(stats.Services, ipvsSvc)

		// Service-level aggregates only — see IPVSStats godoc.
		stats.ActiveConns += ipvsSvc.ActiveConns
		stats.InactiveConns += svcInactive
		stats.ConnRate += ipvsSvc.ConnRate
		stats.BytesInRate += ipvsSvc.BytesInRate
		stats.BytesOutRate += ipvsSvc.BytesOutRate
		stats.PktInRate += ipvsSvc.PktInRate
		stats.PktOutRate += ipvsSvc.PktOutRate
		stats.TotalBytesIn += ipvsSvc.TotalBytesIn
		stats.TotalBytesOut += ipvsSvc.TotalBytesOut
		stats.TotalConns += ipvsSvc.TotalConns
	}

	stats.VirtualIPs = sortedKeys(vipSet)
	stats.Role = classifyRole(stats.VirtualIPs)
	return stats, nil
}

func protocolName(p uint16) string {
	switch p {
	case syscall.IPPROTO_TCP:
		return "TCP"
	case syscall.IPPROTO_UDP:
		return "UDP"
	case syscall.IPPROTO_SCTP:
		return "SCTP"
	default:
		return fmt.Sprintf("IP(%d)", p)
	}
}

// forwardMode decodes the IPVS connection-flag forwarding bits.
func forwardMode(flags uint32) string {
	switch flags & ipvs.ConnectionFlagFwdMask {
	case ipvs.ConnectionFlagMasq:
		return "NAT"
	case ipvs.ConnectionFlagLocalNode:
		return "LOCAL"
	case ipvs.ConnectionFlagTunnel:
		return "TUN"
	case ipvs.ConnectionFlagDirectRoute:
		return "DR"
	}
	return ""
}

func sortedKeys(m map[string]struct{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// classifyRole returns "active" if every configured VIP is bound on a local
// interface, "standby" if none are, and "unknown" otherwise (partial bind, or
// look-up failure). Active node = the keepalived master; standby holds the
// IPVS rules but no VIPs.
//
// If keepalived is configured to drop /var/run/beszel-vrrp-state via a
// notify_master / notify_backup script, that file wins over the VIP-bound
// heuristic. See CLAUDE.md for the script snippet.
func classifyRole(vips []string) string {
	if role := readKeepalivedState(); role != "" {
		return role
	}
	if len(vips) == 0 {
		return "unknown"
	}
	local, err := localAddrSet()
	if err != nil || len(local) == 0 {
		return "unknown"
	}
	bound := 0
	for _, v := range vips {
		if _, ok := local[v]; ok {
			bound++
		}
	}
	switch {
	case bound == 0:
		return "standby"
	case bound == len(vips):
		return "active"
	default:
		return "unknown"
	}
}

// localAddrSet returns the set of IPv4/IPv6 addresses bound to non-loopback
// interfaces on this host. Used to detect VRRP master state without depending
// on keepalived being configured to drop a state file.
func localAddrSet() (map[string]struct{}, error) {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	out := make(map[string]struct{})
	for _, ifi := range ifs {
		if ifi.Flags&net.FlagLoopback != 0 || ifi.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, aerr := ifi.Addrs()
		if aerr != nil {
			continue
		}
		for _, a := range addrs {
			ip, _, perr := net.ParseCIDR(a.String())
			if perr != nil {
				continue
			}
			out[ip.String()] = struct{}{}
		}
	}
	return out, nil
}

// readProcKeepalivedState (optional override) — if the operator wires
// keepalived's notify_master/backup scripts to write one of these state
// strings to /var/run/beszel-vrrp-state, we trust it over the VIP-bound check.
// Returns "" when no override is present.
func readKeepalivedState() string {
	b, err := os.ReadFile("/var/run/beszel-vrrp-state")
	if err != nil {
		return ""
	}
	s := strings.ToLower(strings.TrimSpace(string(b)))
	switch s {
	case "master", "active":
		return "active"
	case "backup", "standby":
		return "standby"
	}
	return ""
}

