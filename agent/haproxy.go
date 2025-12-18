package agent

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/henrygd/beszel/internal/entities/system"
)

// HAProxy CSV column indices (from HAProxy stats output)
// Verified via: echo "show stat typed desc" | nc -U /var/run/haproxy.stat
const (
	hapColPxName       = 0  // proxy name
	hapColSvName       = 1  // service name (FRONTEND, BACKEND, server name)
	hapColScur         = 4  // current sessions
	hapColSmax         = 5  // max sessions
	hapColSlim         = 6  // configured session limit
	hapColStot         = 7  // cumulative number of sessions
	hapColBin          = 8  // bytes in
	hapColBout         = 9  // bytes out
	hapColStatus       = 17 // status (UP/DOWN/OPEN/etc)
	hapColAct          = 19 // active servers (backend only)
	hapColBck          = 20 // backup servers (backend only)
	hapColChkFail      = 21 // number of failed health checks
	hapColChkDown      = 22 // number of UP->DOWN transitions
	hapColRate         = 33 // sessions/requests per second (sessions for frontends, requests for backends/servers)
	hapColReqRate      = 46 // HTTP request rate per second (for frontends)
	hapColHrsp1xx      = 39 // 1xx HTTP responses
	hapColHrsp2xx      = 40 // 2xx HTTP responses
	hapColHrsp3xx      = 41 // 3xx HTTP responses
	hapColHrsp4xx      = 42 // 4xx HTTP responses
	hapColHrsp5xx      = 43 // 5xx HTTP responses
	hapColReqTot       = 48 // total HTTP requests
	hapColRtime        = 60 // average response time (ms)
)

// haproxyPrevCounters stores previous counters for rate calculation
type haproxyPrevCounters struct {
	bytesIn  uint64
	bytesOut uint64
	resp1xx  uint64
	resp2xx  uint64
	resp3xx  uint64
	resp4xx  uint64
	resp5xx  uint64
	time     time.Time
}

// HAProxyManager manages HAProxy stats collection
type HAProxyManager struct {
	sync.Mutex
	socketPath   string        // Unix socket path (e.g., /var/run/haproxy/admin.sock)
	httpURL      string        // HTTP stats URL (e.g., http://localhost:8404/stats)
	httpClient   *http.Client  // HTTP client for stats endpoint
	stats        []system.HAProxyStats
	info         *system.HAProxyInfo
	pools        []system.HAProxyPool
	poolSummary  *system.HAProxyPoolSummary
	activity     []system.HAProxyActivity
	servers      []system.HAProxyServerState
	lastUpdate   time.Time
	updatePeriod time.Duration
	filter       map[string]struct{}              // filter to specific frontends/backends (nil = all)
	prevCounters map[string]*haproxyPrevCounters // previous counters per proxy (key: "name:type")
}

// NewHAProxyManager creates a new HAProxy stats manager
// Configuration via environment variables:
//   - HAPROXY_SOCKET: Unix socket path (e.g., /var/run/haproxy/admin.sock)
//   - HAPROXY_URL: HTTP stats URL (e.g., http://localhost:8404/stats;csv)
//   - HAPROXY_FILTER: Comma-separated list of proxy names to monitor (optional)
func NewHAProxyManager() (*HAProxyManager, error) {
	socketPath, hasSocket := GetEnv("HAPROXY_SOCKET")
	httpURL, hasURL := GetEnv("HAPROXY_URL")

	if !hasSocket && !hasURL {
		return nil, fmt.Errorf("HAProxy not configured (set HAPROXY_SOCKET or HAPROXY_URL)")
	}

	// Default update period is 5 seconds, configurable via HAPROXY_UPDATE_INTERVAL
	updatePeriod := 5 * time.Second
	if intervalStr, exists := GetEnv("HAPROXY_UPDATE_INTERVAL"); exists {
		if seconds, err := strconv.Atoi(intervalStr); err == nil && seconds > 0 {
			updatePeriod = time.Duration(seconds) * time.Second
			slog.Info("HAProxy update interval configured", "seconds", seconds)
		}
	}

	hm := &HAProxyManager{
		socketPath:   socketPath,
		httpURL:      httpURL,
		updatePeriod: updatePeriod,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
		prevCounters: make(map[string]*haproxyPrevCounters),
	}

	// Parse optional filter
	if filterStr, exists := GetEnv("HAPROXY_FILTER"); exists {
		hm.filter = make(map[string]struct{})
		for _, name := range strings.Split(filterStr, ",") {
			name = strings.TrimSpace(name)
			if name != "" {
				hm.filter[name] = struct{}{}
			}
		}
		slog.Info("HAProxy filter configured", "proxies", filterStr)
	}

	// Verify connection works
	if _, err := hm.fetchStats(); err != nil {
		return nil, fmt.Errorf("HAProxy connection failed: %w", err)
	}

	slog.Info("HAProxy monitoring enabled")
	return hm, nil
}

// GetStats returns current HAProxy stats (returns a copy to avoid race conditions)
func (hm *HAProxyManager) GetStats() []system.HAProxyStats {
	hm.Lock()
	defer hm.Unlock()

	// Update if stale
	if time.Since(hm.lastUpdate) > hm.updatePeriod {
		if stats, err := hm.fetchStats(); err == nil {
			hm.calculateRates(stats)
			hm.stats = stats
			hm.lastUpdate = time.Now()
		} else {
			slog.Debug("HAProxy fetch failed", "err", err)
		}
		// Also update info
		if info, err := hm.fetchInfo(); err == nil {
			hm.info = info
		} else {
			slog.Debug("HAProxy info fetch failed", "err", err)
		}
		// Update pools
		if pools, summary, err := hm.fetchPools(); err == nil {
			hm.pools = pools
			hm.poolSummary = summary
		} else {
			slog.Debug("HAProxy pools fetch failed", "err", err)
		}
		// Update activity
		if activity, err := hm.fetchActivity(); err == nil {
			hm.activity = activity
		} else {
			slog.Debug("HAProxy activity fetch failed", "err", err)
		}
		// Update server states
		if servers, err := hm.fetchServersState(); err == nil {
			hm.servers = servers
		} else {
			slog.Debug("HAProxy servers state fetch failed", "err", err)
		}
	}

	// Return a copy to avoid race conditions during CBOR encoding
	if hm.stats == nil {
		return nil
	}
	statsCopy := make([]system.HAProxyStats, len(hm.stats))
	copy(statsCopy, hm.stats)
	return statsCopy
}

// GetPools returns current HAProxy memory pool statistics (returns copies to avoid race conditions)
func (hm *HAProxyManager) GetPools() ([]system.HAProxyPool, *system.HAProxyPoolSummary) {
	hm.Lock()
	defer hm.Unlock()

	// Return copies to avoid race conditions during CBOR encoding
	var poolsCopy []system.HAProxyPool
	if hm.pools != nil {
		poolsCopy = make([]system.HAProxyPool, len(hm.pools))
		copy(poolsCopy, hm.pools)
	}

	var summaryCopy *system.HAProxyPoolSummary
	if hm.poolSummary != nil {
		s := *hm.poolSummary
		summaryCopy = &s
	}

	return poolsCopy, summaryCopy
}

// GetActivity returns current HAProxy thread activity statistics (returns a copy to avoid race conditions)
func (hm *HAProxyManager) GetActivity() []system.HAProxyActivity {
	hm.Lock()
	defer hm.Unlock()

	// Return a copy to avoid race conditions during CBOR encoding
	if hm.activity == nil {
		return nil
	}
	activityCopy := make([]system.HAProxyActivity, len(hm.activity))
	copy(activityCopy, hm.activity)
	return activityCopy
}

// GetServersState returns current HAProxy server states (returns a copy to avoid race conditions)
func (hm *HAProxyManager) GetServersState() []system.HAProxyServerState {
	hm.Lock()
	defer hm.Unlock()

	// Return a copy to avoid race conditions during CBOR encoding
	if hm.servers == nil {
		return nil
	}
	serversCopy := make([]system.HAProxyServerState, len(hm.servers))
	copy(serversCopy, hm.servers)
	return serversCopy
}

// calculateRates computes per-second rates and updates previous counters
func (hm *HAProxyManager) calculateRates(stats []system.HAProxyStats) {
	now := time.Now()

	// Track counts per name:type to handle multiple servers with same proxy name
	typeCounts := make(map[string]int)

	for i := range stats {
		stat := &stats[i]
		baseKey := stat.Name + ":" + stat.Type
		typeCounts[baseKey]++
		// Use count to make key unique for multiple servers with same proxy name
		key := baseKey + ":" + strconv.Itoa(typeCounts[baseKey])

		prev, exists := hm.prevCounters[key]
		if exists {
			elapsed := now.Sub(prev.time).Seconds()
			if elapsed > 0 {
				// Calculate bytes per second (handle counter wraps)
				if stat.BytesIn >= prev.bytesIn {
					stat.BytesInRate = uint64(float64(stat.BytesIn-prev.bytesIn) / elapsed)
				}
				if stat.BytesOut >= prev.bytesOut {
					stat.BytesOutRate = uint64(float64(stat.BytesOut-prev.bytesOut) / elapsed)
				}
				// Calculate HTTP response rates (handle counter wraps)
				if stat.Resp1xx >= prev.resp1xx {
					stat.Resp1xxRate = uint64(float64(stat.Resp1xx-prev.resp1xx) / elapsed)
				}
				if stat.Resp2xx >= prev.resp2xx {
					stat.Resp2xxRate = uint64(float64(stat.Resp2xx-prev.resp2xx) / elapsed)
				}
				if stat.Resp3xx >= prev.resp3xx {
					stat.Resp3xxRate = uint64(float64(stat.Resp3xx-prev.resp3xx) / elapsed)
				}
				if stat.Resp4xx >= prev.resp4xx {
					stat.Resp4xxRate = uint64(float64(stat.Resp4xx-prev.resp4xx) / elapsed)
				}
				if stat.Resp5xx >= prev.resp5xx {
					stat.Resp5xxRate = uint64(float64(stat.Resp5xx-prev.resp5xx) / elapsed)
				}
			}
		}

		// Update previous values
		hm.prevCounters[key] = &haproxyPrevCounters{
			bytesIn:  stat.BytesIn,
			bytesOut: stat.BytesOut,
			resp1xx:  stat.Resp1xx,
			resp2xx:  stat.Resp2xx,
			resp3xx:  stat.Resp3xx,
			resp4xx:  stat.Resp4xx,
			resp5xx:  stat.Resp5xx,
			time:     now,
		}
	}
}

// GetInfo returns current HAProxy process info (returns a copy to avoid race conditions)
func (hm *HAProxyManager) GetInfo() *system.HAProxyInfo {
	hm.Lock()
	defer hm.Unlock()

	// Return a copy to avoid race conditions during CBOR encoding
	if hm.info == nil {
		return nil
	}
	infoCopy := *hm.info
	return &infoCopy
}

// fetchInfo retrieves process info from HAProxy via socket
func (hm *HAProxyManager) fetchInfo() (*system.HAProxyInfo, error) {
	if hm.socketPath == "" {
		return nil, fmt.Errorf("socket path not configured for show info")
	}

	conn, err := net.DialTimeout("unix", hm.socketPath, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("socket connection failed: %w", err)
	}
	defer conn.Close()

	// Send info command
	if _, err := conn.Write([]byte("show info\n")); err != nil {
		return nil, fmt.Errorf("socket write failed: %w", err)
	}

	return hm.parseInfo(conn)
}

// parseInfo parses HAProxy "show info" output
func (hm *HAProxyManager) parseInfo(reader io.Reader) (*system.HAProxyInfo, error) {
	info := &system.HAProxyInfo{}
	scanner := bufio.NewScanner(reader)

	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, ": ", 2)
		if len(parts) != 2 {
			continue
		}
		key := parts[0]
		value := strings.TrimSpace(parts[1])

		switch key {
		case "Version":
			info.Version = value
		case "Uptime":
			info.Uptime = value
		case "Uptime_sec":
			info.UptimeSec, _ = strconv.ParseUint(value, 10, 64)
		case "Memmax_MB":
			info.MemMaxMB, _ = strconv.ParseUint(value, 10, 64)
		case "PoolAlloc_MB":
			info.PoolAllocMB, _ = strconv.ParseUint(value, 10, 64)
		case "PoolUsed_MB":
			info.PoolUsedMB, _ = strconv.ParseUint(value, 10, 64)
		case "Nbthread":
			info.Nbthread, _ = strconv.ParseUint(value, 10, 64)
		case "Maxconn":
			info.Maxconn, _ = strconv.ParseUint(value, 10, 64)
		case "CurrConns":
			info.CurrConns, _ = strconv.ParseUint(value, 10, 64)
		case "CumConns":
			info.CumConns, _ = strconv.ParseUint(value, 10, 64)
		case "CumReq":
			info.CumReq, _ = strconv.ParseUint(value, 10, 64)
		case "MaxSslConns":
			info.MaxSslConns, _ = strconv.ParseUint(value, 10, 64)
		case "CurrSslConns":
			info.CurrSslConns, _ = strconv.ParseUint(value, 10, 64)
		case "CumSslConns":
			info.CumSslConns, _ = strconv.ParseUint(value, 10, 64)
		case "ConnRate":
			info.ConnRate, _ = strconv.ParseUint(value, 10, 64)
		case "MaxConnRate":
			info.MaxConnRate, _ = strconv.ParseUint(value, 10, 64)
		case "SessRate":
			info.SessRate, _ = strconv.ParseUint(value, 10, 64)
		case "MaxSessRate":
			info.MaxSessRate, _ = strconv.ParseUint(value, 10, 64)
		case "SslRate":
			info.SslRate, _ = strconv.ParseUint(value, 10, 64)
		case "MaxSslRate":
			info.MaxSslRate, _ = strconv.ParseUint(value, 10, 64)
		case "Tasks":
			info.Tasks, _ = strconv.ParseUint(value, 10, 64)
		case "Run_queue":
			info.RunQueue, _ = strconv.ParseUint(value, 10, 64)
		case "Idle_pct":
			info.IdlePct, _ = strconv.ParseUint(value, 10, 64)
		case "node":
			info.Node = value
		case "TotalBytesOut":
			info.TotalBytesOut, _ = strconv.ParseUint(value, 10, 64)
		case "BytesOutRate":
			info.BytesOutRate, _ = strconv.ParseUint(value, 10, 64)
		case "Pid":
			info.Pid, _ = strconv.ParseUint(value, 10, 64)
		case "SslFrontendSessionReuse_pct":
			info.SslReusePct, _ = strconv.ParseUint(value, 10, 64)
		}
	}

	if info.Version == "" {
		return nil, fmt.Errorf("failed to parse HAProxy info")
	}

	return info, nil
}

// fetchStats retrieves stats from HAProxy via socket or HTTP
func (hm *HAProxyManager) fetchStats() ([]system.HAProxyStats, error) {
	var reader io.Reader
	var closer io.Closer

	if hm.socketPath != "" {
		// Connect via Unix socket
		conn, err := net.DialTimeout("unix", hm.socketPath, 5*time.Second)
		if err != nil {
			// Fall back to HTTP if socket fails and HTTP is configured
			if hm.httpURL != "" {
				return hm.fetchStatsHTTP()
			}
			return nil, fmt.Errorf("socket connection failed: %w", err)
		}
		closer = conn
		reader = conn

		// Send stats command
		if _, err := conn.Write([]byte("show stat\n")); err != nil {
			conn.Close()
			return nil, fmt.Errorf("socket write failed: %w", err)
		}
	} else {
		return hm.fetchStatsHTTP()
	}

	defer closer.Close()
	return hm.parseCSV(reader)
}

// fetchStatsHTTP retrieves stats via HTTP endpoint
func (hm *HAProxyManager) fetchStatsHTTP() ([]system.HAProxyStats, error) {
	url := hm.httpURL
	// Ensure we get CSV format
	if !strings.Contains(url, ";csv") && !strings.Contains(url, "csv") {
		if strings.Contains(url, "?") {
			url += ";csv"
		} else {
			url += "?stats;csv"
		}
	}

	resp, err := hm.httpClient.Get(url)
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP status %d", resp.StatusCode)
	}

	return hm.parseCSV(resp.Body)
}

// parseCSV parses HAProxy CSV stats output
func (hm *HAProxyManager) parseCSV(reader io.Reader) ([]system.HAProxyStats, error) {
	var stats []system.HAProxyStats

	csvReader := csv.NewReader(bufio.NewReader(reader))
	csvReader.FieldsPerRecord = -1 // Allow variable field count
	csvReader.Comment = '#'

	for {
		record, err := csvReader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			continue // Skip malformed lines
		}

		// Skip header row (starts with "# ")
		if len(record) > 0 && strings.HasPrefix(record[0], "#") {
			continue
		}

		// Need at least enough columns for basic stats
		if len(record) < 18 {
			continue
		}

		pxName := record[hapColPxName]
		svName := record[hapColSvName]

		// Apply filter if configured
		if hm.filter != nil {
			if _, ok := hm.filter[pxName]; !ok {
				continue
			}
		}

		// Determine type
		var proxyType string
		switch svName {
		case "FRONTEND":
			proxyType = "FRONTEND"
		case "BACKEND":
			proxyType = "BACKEND"
		default:
			proxyType = "SERVER"
		}

		stat := system.HAProxyStats{
			Name:        pxName,
			Type:        proxyType,
			Status:      record[hapColStatus],
			CurrentSess: parseUint64(record, hapColScur),
			MaxSess:     parseUint64(record, hapColSmax),
			SessionLimit: parseUint64(record, hapColSlim),
			TotalSess:   parseUint64(record, hapColStot),
			BytesIn:     parseUint64(record, hapColBin),
			BytesOut:    parseUint64(record, hapColBout),
		}

		// Additional fields depending on type and available columns
		if len(record) > hapColReqTot {
			stat.RequestTotal = parseUint64(record, hapColReqTot)
		}
		// Use req_rate (column 46) for frontends, rate (column 33) for backends/servers
		// Column 33 is session rate for frontends, but request rate for backends/servers
		if proxyType == "FRONTEND" && len(record) > hapColReqRate {
			stat.RequestRate = parseUint64(record, hapColReqRate)
		} else if len(record) > hapColRate {
			stat.RequestRate = parseUint64(record, hapColRate)
		}
		// HTTP response codes
		if len(record) > hapColHrsp1xx {
			stat.Resp1xx = parseUint64(record, hapColHrsp1xx)
		}
		if len(record) > hapColHrsp2xx {
			stat.Resp2xx = parseUint64(record, hapColHrsp2xx)
		}
		if len(record) > hapColHrsp3xx {
			stat.Resp3xx = parseUint64(record, hapColHrsp3xx)
		}
		if len(record) > hapColHrsp4xx {
			stat.Resp4xx = parseUint64(record, hapColHrsp4xx)
		}
		if len(record) > hapColHrsp5xx {
			stat.Resp5xx = parseUint64(record, hapColHrsp5xx)
		}
		if len(record) > hapColRtime {
			stat.ResponseTime = parseUint64(record, hapColRtime)
		}

		// Backend-specific fields
		if proxyType == "BACKEND" {
			stat.ActiveServers = parseUint64(record, hapColAct)
			stat.BackupServers = parseUint64(record, hapColBck)
		}

		// Server-specific fields (health checks)
		if proxyType == "SERVER" {
			stat.HealthCheckFail = parseUint64(record, hapColChkFail)
		}

		stats = append(stats, stat)
	}

	if len(stats) == 0 {
		return nil, fmt.Errorf("no stats found in HAProxy output")
	}

	return stats, nil
}

// parseUint64 safely parses a uint64 from a CSV record
func parseUint64(record []string, idx int) uint64 {
	if idx >= len(record) {
		return 0
	}
	val, _ := strconv.ParseUint(strings.TrimSpace(record[idx]), 10, 64)
	return val
}

// Regex patterns for parsing "show pools" output
var (
	// Match: "  - Pool ssl_sock_ct (128 bytes) : 260 allocated (33280 bytes), 260 used (~174 by thread caches), needed_avg 91, 0 failures, 6 users"
	poolLineRegex = regexp.MustCompile(`^\s*-\s*Pool\s+(\S+)\s+\((\d+)\s+bytes\)\s*:\s*(\d+)\s+allocated\s+\((\d+)\s+bytes\),\s*(\d+)\s+used\s+\(~(\d+)\s+by thread caches\).*?(\d+)\s+failures`)
	// Match: "Total: 38 pools, 5060640 bytes allocated, 5060640 used (~1023728 by thread caches)."
	poolTotalRegex = regexp.MustCompile(`Total:\s*(\d+)\s+pools,\s*(\d+)\s+bytes allocated,\s*(\d+)\s+used\s+\(~(\d+)\s+by thread caches\)`)
)

// fetchPools retrieves memory pool statistics from HAProxy via socket
func (hm *HAProxyManager) fetchPools() ([]system.HAProxyPool, *system.HAProxyPoolSummary, error) {
	if hm.socketPath == "" {
		return nil, nil, fmt.Errorf("socket path not configured for show pools")
	}

	conn, err := net.DialTimeout("unix", hm.socketPath, 5*time.Second)
	if err != nil {
		return nil, nil, fmt.Errorf("socket connection failed: %w", err)
	}
	defer conn.Close()

	if _, err := conn.Write([]byte("show pools\n")); err != nil {
		return nil, nil, fmt.Errorf("socket write failed: %w", err)
	}

	return hm.parsePools(conn)
}

// parsePools parses HAProxy "show pools" output
func (hm *HAProxyManager) parsePools(reader io.Reader) ([]system.HAProxyPool, *system.HAProxyPoolSummary, error) {
	var pools []system.HAProxyPool
	var summary *system.HAProxyPoolSummary

	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := scanner.Text()

		// Try to match pool line
		if matches := poolLineRegex.FindStringSubmatch(line); len(matches) == 8 {
			size, _ := strconv.ParseUint(matches[2], 10, 64)
			allocated, _ := strconv.ParseUint(matches[4], 10, 64)
			used, _ := strconv.ParseUint(matches[5], 10, 64)
			inCache, _ := strconv.ParseUint(matches[6], 10, 64)
			failures, _ := strconv.ParseUint(matches[7], 10, 64)

			pools = append(pools, system.HAProxyPool{
				Name:      matches[1],
				Size:      size,
				Allocated: allocated,
				Used:      used,
				InCache:   inCache,
				Failures:  failures,
			})
			continue
		}

		// Try to match total line
		if matches := poolTotalRegex.FindStringSubmatch(line); len(matches) == 5 {
			totalPools, _ := strconv.ParseUint(matches[1], 10, 64)
			totalAllocated, _ := strconv.ParseUint(matches[2], 10, 64)
			totalUsed, _ := strconv.ParseUint(matches[3], 10, 64)
			inThreadCaches, _ := strconv.ParseUint(matches[4], 10, 64)

			summary = &system.HAProxyPoolSummary{
				TotalPools:     totalPools,
				TotalAllocated: totalAllocated,
				TotalUsed:      totalUsed,
				InThreadCaches: inThreadCaches,
			}
		}
	}

	if len(pools) == 0 {
		return nil, nil, fmt.Errorf("no pools found in HAProxy output")
	}

	return pools, summary, nil
}

// fetchActivity retrieves per-thread activity statistics from HAProxy via socket
func (hm *HAProxyManager) fetchActivity() ([]system.HAProxyActivity, error) {
	if hm.socketPath == "" {
		return nil, fmt.Errorf("socket path not configured for show activity")
	}

	conn, err := net.DialTimeout("unix", hm.socketPath, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("socket connection failed: %w", err)
	}
	defer conn.Close()

	if _, err := conn.Write([]byte("show activity\n")); err != nil {
		return nil, fmt.Errorf("socket write failed: %w", err)
	}

	return hm.parseActivity(conn)
}

// parseActivity parses HAProxy "show activity" output
func (hm *HAProxyManager) parseActivity(reader io.Reader) ([]system.HAProxyActivity, error) {
	scanner := bufio.NewScanner(reader)

	// Parse key-value pairs where value contains per-thread array
	data := make(map[string][]uint64)
	var threadCount int

	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		// Check if value contains array in brackets
		if bracketIdx := strings.Index(value, "["); bracketIdx != -1 {
			// Extract array values
			arrayPart := value[bracketIdx+1:]
			if closeIdx := strings.Index(arrayPart, "]"); closeIdx != -1 {
				arrayPart = arrayPart[:closeIdx]
			}
			values := strings.Fields(arrayPart)
			nums := make([]uint64, len(values))
			for i, v := range values {
				nums[i], _ = strconv.ParseUint(v, 10, 64)
			}
			data[key] = nums
			if threadCount == 0 || len(nums) < threadCount {
				threadCount = len(nums)
			}
		}
	}

	if threadCount == 0 {
		return nil, fmt.Errorf("no activity data found")
	}

	// Build per-thread activity structs
	activities := make([]system.HAProxyActivity, threadCount)
	for i := 0; i < threadCount; i++ {
		activities[i] = system.HAProxyActivity{
			ThreadID: uint64(i + 1),
		}
		if vals, ok := data["ctxsw"]; ok && i < len(vals) {
			activities[i].CtxSwitches = vals[i]
		}
		if vals, ok := data["tasksw"]; ok && i < len(vals) {
			activities[i].TaskSwitches = vals[i]
		}
		if vals, ok := data["loops"]; ok && i < len(vals) {
			activities[i].Loops = vals[i]
		}
		if vals, ok := data["avg_cpu_pct"]; ok && i < len(vals) {
			activities[i].AvgCpuPct = vals[i]
		}
		if vals, ok := data["avg_loop_us"]; ok && i < len(vals) {
			activities[i].AvgLoopUs = vals[i]
		}
		if vals, ok := data["accepted"]; ok && i < len(vals) {
			activities[i].Accepted = vals[i]
		}
		if vals, ok := data["poll_io"]; ok && i < len(vals) {
			activities[i].PollIO = vals[i]
		}
	}

	return activities, nil
}

// fetchServersState retrieves server state information from HAProxy via socket
func (hm *HAProxyManager) fetchServersState() ([]system.HAProxyServerState, error) {
	if hm.socketPath == "" {
		return nil, fmt.Errorf("socket path not configured for show servers state")
	}

	conn, err := net.DialTimeout("unix", hm.socketPath, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("socket connection failed: %w", err)
	}
	defer conn.Close()

	if _, err := conn.Write([]byte("show servers state\n")); err != nil {
		return nil, fmt.Errorf("socket write failed: %w", err)
	}

	return hm.parseServersState(conn)
}

// parseServersState parses HAProxy "show servers state" output
// Format: be_id be_name srv_id srv_name srv_addr srv_op_state srv_admin_state srv_uweight ...
func (hm *HAProxyManager) parseServersState(reader io.Reader) ([]system.HAProxyServerState, error) {
	var servers []system.HAProxyServerState

	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := scanner.Text()

		// Skip version line (just a number) and header line (starts with #)
		if strings.HasPrefix(line, "#") || len(strings.Fields(line)) == 1 {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}

		// Parse fields: be_id(0) be_name(1) srv_id(2) srv_name(3) srv_addr(4) srv_op_state(5) srv_admin_state(6) srv_uweight(7) srv_iweight(8) srv_time_since_last_change(9) ...
		port := uint16(0)
		// Check if address contains port
		addr := fields[4]
		if colonIdx := strings.LastIndex(addr, ":"); colonIdx != -1 {
			portStr := addr[colonIdx+1:]
			if p, err := strconv.ParseUint(portStr, 10, 16); err == nil {
				port = uint16(p)
				addr = addr[:colonIdx]
			}
		}

		opState, _ := strconv.ParseUint(fields[5], 10, 8)
		adminState, _ := strconv.ParseUint(fields[6], 10, 8)
		weight, _ := strconv.ParseUint(fields[7], 10, 16)
		lastChange, _ := strconv.ParseUint(fields[9], 10, 64)

		var checkStatus uint8
		if len(fields) > 10 {
			cs, _ := strconv.ParseUint(fields[10], 10, 8)
			checkStatus = uint8(cs)
		}

		servers = append(servers, system.HAProxyServerState{
			Backend:     fields[1],
			Server:      fields[3],
			Address:     addr,
			Port:        port,
			OpState:     uint8(opState),
			AdminState:  uint8(adminState),
			Weight:      uint16(weight),
			CheckStatus: checkStatus,
			LastChange:  lastChange,
		})
	}

	return servers, nil
}
