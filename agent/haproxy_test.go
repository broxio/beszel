//go:build testing
// +build testing

package agent

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/henrygd/beszel/internal/entities/system"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Sample HAProxy CSV output for testing
const sampleHAProxyCSV = `# pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status,weight,act,bck,chkfail,chkdown,lastchg,downtime,qlimit,pid,iid,sid,throttle,lbtot,tracked,type,rate,rate_lim,rate_max,check_status,check_code,check_duration,hrsp_1xx,hrsp_2xx,hrsp_3xx,hrsp_4xx,hrsp_5xx,hrsp_other,hanafail,req_rate,req_rate_max,req_tot,cli_abrt,srv_abrt,comp_in,comp_out,comp_byp,comp_rsp,lastsess,last_chk,last_agt,qtime,ctime,rtime,ttime,
http_front,FRONTEND,,,10,100,2000,50000,1234567890,9876543210,0,0,5,,,,,OPEN,,,,,,,,,1,2,0,,,,0,50,,200,,,,0,45000,1000,150,25,,0,100,500,50000,,,,,,,-1,,,0,0,0,0,
api_back,api_server1,0,0,5,20,50,10000,500000000,400000000,,,0,0,0,0,0,UP,1,1,0,2,1,86400,0,,1,3,1,,5000,,2,25,,100,L7OK,200,5,0,9500,200,100,50,0,,,,0,0,,,,,,10,OK,,5,10,25,50,
api_back,api_server2,0,0,3,15,50,8000,300000000,250000000,,,0,0,0,0,0,UP,1,1,0,0,0,86400,0,,1,3,2,,4000,,2,15,,80,L7OK,200,3,0,7800,150,80,30,0,,,,0,0,,,,,,5,OK,,3,8,20,40,
api_back,BACKEND,0,0,8,35,100,18000,800000000,650000000,0,0,,0,0,0,0,UP,2,2,0,,0,86400,0,,1,3,0,,9000,,1,40,,180,,,,0,17300,350,180,80,0,,,,0,0,,,,,,15,,,4,9,22,45,
stats,FRONTEND,,,1,5,1000,500,10000,50000,0,0,0,,,,,OPEN,,,,,,,,,1,4,0,,,,0,1,,10,,,,0,490,5,3,2,,0,1,10,500,,,,,,,-1,,,0,0,0,0,
`

// Sample HAProxy CSV with minimal columns
const minimalHAProxyCSV = `# pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status
http_front,FRONTEND,,,5,50,1000,25000,500000,400000,0,0,0,,,,,OPEN
backend1,BACKEND,0,0,3,20,50,10000,200000,150000,0,0,,0,0,0,0,UP
`

func TestParseCSV(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		filter     map[string]struct{}
		wantCount  int
		wantNames  []string
		wantTypes  []string
		wantStatus []string
	}{
		{
			name:       "parse full CSV",
			input:      sampleHAProxyCSV,
			filter:     nil,
			wantCount:  5,
			wantNames:  []string{"http_front", "api_back", "api_back", "api_back", "stats"},
			wantTypes:  []string{"FRONTEND", "SERVER", "SERVER", "BACKEND", "FRONTEND"},
			wantStatus: []string{"OPEN", "UP", "UP", "UP", "OPEN"},
		},
		{
			name:   "parse with filter",
			input:  sampleHAProxyCSV,
			filter: map[string]struct{}{"api_back": {}},
			wantCount: 3,
			wantNames: []string{"api_back", "api_back", "api_back"},
			wantTypes: []string{"SERVER", "SERVER", "BACKEND"},
		},
		{
			name:       "parse minimal CSV",
			input:      minimalHAProxyCSV,
			filter:     nil,
			wantCount:  2,
			wantNames:  []string{"http_front", "backend1"},
			wantTypes:  []string{"FRONTEND", "BACKEND"},
			wantStatus: []string{"OPEN", "UP"},
		},
		{
			name:      "empty input",
			input:     "",
			filter:    nil,
			wantCount: 0,
		},
		{
			name:      "only header",
			input:     "# pxname,svname,scur\n",
			filter:    nil,
			wantCount: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hm := &HAProxyManager{filter: tt.filter}
			stats, err := hm.parseCSV(strings.NewReader(tt.input))

			if tt.wantCount == 0 {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err)
			assert.Len(t, stats, tt.wantCount)

			for i, stat := range stats {
				if i < len(tt.wantNames) {
					assert.Equal(t, tt.wantNames[i], stat.Name, "name mismatch at index %d", i)
				}
				if i < len(tt.wantTypes) {
					assert.Equal(t, tt.wantTypes[i], stat.Type, "type mismatch at index %d", i)
				}
				if i < len(tt.wantStatus) {
					assert.Equal(t, tt.wantStatus[i], stat.Status, "status mismatch at index %d", i)
				}
			}
		})
	}
}

func TestParseCSVValues(t *testing.T) {
	hm := &HAProxyManager{}
	stats, err := hm.parseCSV(strings.NewReader(sampleHAProxyCSV))
	require.NoError(t, err)
	require.Len(t, stats, 5)

	// Test frontend stats (http_front)
	frontend := stats[0]
	assert.Equal(t, "http_front", frontend.Name)
	assert.Equal(t, "FRONTEND", frontend.Type)
	assert.Equal(t, "OPEN", frontend.Status)
	assert.Equal(t, uint64(10), frontend.CurrentSess)
	assert.Equal(t, uint64(100), frontend.MaxSess)
	assert.Equal(t, uint64(2000), frontend.SessionLimit)
	assert.Equal(t, uint64(50000), frontend.TotalSess)
	assert.Equal(t, uint64(1234567890), frontend.BytesIn)
	assert.Equal(t, uint64(9876543210), frontend.BytesOut)
	assert.Equal(t, uint64(100), frontend.RequestRate)
	assert.Equal(t, uint64(50000), frontend.RequestTotal)

	// Test server stats (api_server1)
	server := stats[1]
	assert.Equal(t, "api_back", server.Name)
	assert.Equal(t, "SERVER", server.Type)
	assert.Equal(t, "UP", server.Status)
	assert.Equal(t, uint64(5), server.CurrentSess)
	assert.Equal(t, uint64(500000000), server.BytesIn)
	assert.Equal(t, uint64(2), server.HealthCheckFail)

	// Test backend stats (api_back BACKEND)
	backend := stats[3]
	assert.Equal(t, "api_back", backend.Name)
	assert.Equal(t, "BACKEND", backend.Type)
	assert.Equal(t, uint64(8), backend.CurrentSess)
	assert.Equal(t, uint64(2), backend.ActiveServers)
}

func TestParseUint64(t *testing.T) {
	tests := []struct {
		name   string
		record []string
		idx    int
		want   uint64
	}{
		{
			name:   "valid number",
			record: []string{"100", "200", "300"},
			idx:    1,
			want:   200,
		},
		{
			name:   "empty string",
			record: []string{"", "200"},
			idx:    0,
			want:   0,
		},
		{
			name:   "index out of range",
			record: []string{"100"},
			idx:    5,
			want:   0,
		},
		{
			name:   "invalid number",
			record: []string{"abc"},
			idx:    0,
			want:   0,
		},
		{
			name:   "whitespace",
			record: []string{" 500 "},
			idx:    0,
			want:   500,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseUint64(tt.record, tt.idx)
			assert.Equal(t, tt.want, got)
		})
	}
}

func TestFetchStatsHTTP(t *testing.T) {
	// Create a test HTTP server that returns HAProxy stats
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte(sampleHAProxyCSV))
	}))
	defer server.Close()

	hm := &HAProxyManager{
		httpURL:    server.URL,
		httpClient: server.Client(),
	}

	stats, err := hm.fetchStatsHTTP()
	require.NoError(t, err)
	assert.Len(t, stats, 5)
	assert.Equal(t, "http_front", stats[0].Name)
}

func TestFetchStatsHTTPError(t *testing.T) {
	// Test with server returning error status
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	hm := &HAProxyManager{
		httpURL:    server.URL,
		httpClient: server.Client(),
	}

	_, err := hm.fetchStatsHTTP()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "500")
}

func TestFetchStatsHTTPURLFormatting(t *testing.T) {
	tests := []struct {
		name       string
		inputURL   string
		wantSuffix string
	}{
		{
			name:       "URL without csv",
			inputURL:   "http://localhost:8404/stats",
			wantSuffix: "?stats;csv",
		},
		{
			name:       "URL with existing query",
			inputURL:   "http://localhost:8404/stats?auth=secret",
			wantSuffix: ";csv",
		},
		{
			name:       "URL already has csv",
			inputURL:   "http://localhost:8404/stats;csv",
			wantSuffix: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var requestedURL string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requestedURL = r.URL.String()
				w.Write([]byte(sampleHAProxyCSV))
			}))
			defer server.Close()

			// Replace localhost with test server URL
			testURL := server.URL + strings.TrimPrefix(tt.inputURL, "http://localhost:8404")

			hm := &HAProxyManager{
				httpURL:    testURL,
				httpClient: server.Client(),
			}

			_, err := hm.fetchStatsHTTP()
			require.NoError(t, err)

			if tt.wantSuffix != "" {
				assert.True(t, strings.Contains(requestedURL, "csv"), "URL should contain csv")
			}
		})
	}
}

func TestFetchStatsSocket(t *testing.T) {
	// Create a temporary Unix socket
	dir := t.TempDir()
	socketPath := filepath.Join(dir, "haproxy.sock")

	// Start a listener on the Unix socket
	listener, err := net.Listen("unix", socketPath)
	require.NoError(t, err)
	defer listener.Close()

	// Handle connections
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 1024)
				n, _ := c.Read(buf)
				cmd := strings.TrimSpace(string(buf[:n]))
				if cmd == "show stat" {
					c.Write([]byte(sampleHAProxyCSV))
				}
			}(conn)
		}
	}()

	hm := &HAProxyManager{
		socketPath: socketPath,
	}

	stats, err := hm.fetchStats()
	require.NoError(t, err)
	assert.Len(t, stats, 5)
	assert.Equal(t, "http_front", stats[0].Name)
}

func TestGetStats(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(sampleHAProxyCSV))
	}))
	defer server.Close()

	hm := &HAProxyManager{
		httpURL:    server.URL,
		httpClient: server.Client(),
		prevCounters: make(map[string]*haproxyPrevCounters),
	}

	// First call should fetch fresh stats
	stats := hm.GetStats()
	assert.Len(t, stats, 5)

	// Second immediate call should return cached stats
	stats2 := hm.GetStats()
	assert.Equal(t, stats, stats2)
}

func TestNewHAProxyManagerNoConfig(t *testing.T) {
	// Clear any existing env vars
	os.Unsetenv("HAPROXY_SOCKET")
	os.Unsetenv("HAPROXY_URL")
	os.Unsetenv("BESZEL_AGENT_HAPROXY_SOCKET")
	os.Unsetenv("BESZEL_AGENT_HAPROXY_URL")

	_, err := NewHAProxyManager()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not configured")
}

func TestNewHAProxyManagerWithHTTP(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(sampleHAProxyCSV))
	}))
	defer server.Close()

	t.Setenv("BESZEL_AGENT_HAPROXY_URL", server.URL)

	hm, err := NewHAProxyManager()
	require.NoError(t, err)
	assert.NotNil(t, hm)

	stats := hm.GetStats()
	assert.Len(t, stats, 5)
}

func TestNewHAProxyManagerWithFilter(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(sampleHAProxyCSV))
	}))
	defer server.Close()

	t.Setenv("BESZEL_AGENT_HAPROXY_URL", server.URL)
	t.Setenv("BESZEL_AGENT_HAPROXY_FILTER", "api_back, stats")

	hm, err := NewHAProxyManager()
	require.NoError(t, err)
	assert.NotNil(t, hm)
	assert.Len(t, hm.filter, 2)

	stats := hm.GetStats()
	// Should only have api_back (3 entries) + stats (1 entry) = 4 entries
	assert.Len(t, stats, 4)

	for _, stat := range stats {
		assert.True(t, stat.Name == "api_back" || stat.Name == "stats",
			"unexpected proxy name: %s", stat.Name)
	}
}

func TestHAProxyStatsDataStructure(t *testing.T) {
	// Test that the HAProxyStats structure has all required fields
	stats := system.HAProxyStats{
		Name:            "test_proxy",
		Type:            "BACKEND",
		Status:          "UP",
		CurrentSess:     10,
		MaxSess:         100,
		SessionLimit:    1000,
		TotalSess:       50000,
		BytesIn:         1234567890,
		BytesOut:        9876543210,
		RequestRate:     100,
		RequestTotal:    500000,
		ResponseTime:    25,
		Resp4xx:         150,
		Resp5xx:         25,
		HealthCheckFail: 5,
		ActiveServers:   3,
		BackupServers:   1,
	}

	assert.Equal(t, "test_proxy", stats.Name)
	assert.Equal(t, "BACKEND", stats.Type)
	assert.Equal(t, uint64(10), stats.CurrentSess)
	assert.Equal(t, uint64(3), stats.ActiveServers)
	assert.Equal(t, uint64(150), stats.Resp4xx)
	assert.Equal(t, uint64(25), stats.Resp5xx)
}

func TestParseInfo(t *testing.T) {
	input := `Name: HAProxy
Version: 2.9.6
Release_date: 2024/02/15
Nbthread: 4
Maxconn: 4000
CurrConns: 150
CumConns: 5000000
CumReq: 12000000
MaxSslConns: 2000
CurrSslConns: 75
CumSslConns: 1000000
ConnRate: 25
MaxConnRate: 500
SessRate: 30
MaxSessRate: 600
SslRate: 10
MaxSslRate: 200
Tasks: 50
Run_queue: 3
Idle_pct: 85
node: haproxy-prod-1
Uptime: 5d 3h 20m 15s
Uptime_sec: 443415
Memmax_MB: 512
PoolAlloc_MB: 128
PoolUsed_MB: 96
TotalBytesOut: 9876543210
BytesOutRate: 1234567
Pid: 12345
SslFrontendSessionReuse_pct: 42
`

	hm := &HAProxyManager{}
	info, err := hm.parseInfo(strings.NewReader(input))
	require.NoError(t, err)

	assert.Equal(t, "2.9.6", info.Version)
	assert.Equal(t, "haproxy-prod-1", info.Node)
	assert.Equal(t, "5d 3h 20m 15s", info.Uptime)
	assert.Equal(t, uint64(443415), info.UptimeSec)
	assert.Equal(t, uint64(4), info.Nbthread)
	assert.Equal(t, uint64(4000), info.Maxconn)
	assert.Equal(t, uint64(150), info.CurrConns)
	assert.Equal(t, uint64(5000000), info.CumConns)
	assert.Equal(t, uint64(12000000), info.CumReq)
	assert.Equal(t, uint64(75), info.CurrSslConns)
	assert.Equal(t, uint64(25), info.ConnRate)
	assert.Equal(t, uint64(85), info.IdlePct)
	assert.Equal(t, uint64(512), info.MemMaxMB)
	assert.Equal(t, uint64(128), info.PoolAllocMB)
	assert.Equal(t, uint64(96), info.PoolUsedMB)
	assert.Equal(t, uint64(9876543210), info.TotalBytesOut)
	assert.Equal(t, uint64(12345), info.Pid)
	assert.Equal(t, uint64(42), info.SslReusePct)
}

func TestParseInfoEmpty(t *testing.T) {
	hm := &HAProxyManager{}
	_, err := hm.parseInfo(strings.NewReader(""))
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "failed to parse")
}

func TestParsePools(t *testing.T) {
	input := `Dumping pools usage. Use SIGQUIT to flush them.
  - Pool ssl_sock_ct (128 bytes) : 260 allocated (33280 bytes), 260 used (~174 by thread caches), needed_avg 91, 0 failures, 6 users
  - Pool connection (416 bytes) : 1020 allocated (424320 bytes), 1020 used (~512 by thread caches), needed_avg 300, 3 failures, 2 users
Total: 2 pools, 457600 bytes allocated, 457600 used (~686 by thread caches).
`

	hm := &HAProxyManager{}
	pools, summary, err := hm.parsePools(strings.NewReader(input))
	require.NoError(t, err)

	assert.Len(t, pools, 2)
	assert.Equal(t, "ssl_sock_ct", pools[0].Name)
	assert.Equal(t, uint64(128), pools[0].Size)
	assert.Equal(t, uint64(33280), pools[0].Allocated)
	assert.Equal(t, uint64(260), pools[0].Used)
	assert.Equal(t, uint64(174), pools[0].InCache)
	assert.Equal(t, uint64(0), pools[0].Failures)

	assert.Equal(t, "connection", pools[1].Name)
	assert.Equal(t, uint64(3), pools[1].Failures)

	require.NotNil(t, summary)
	assert.Equal(t, uint64(2), summary.TotalPools)
	assert.Equal(t, uint64(457600), summary.TotalAllocated)
	assert.Equal(t, uint64(457600), summary.TotalUsed)
	assert.Equal(t, uint64(686), summary.InThreadCaches)
}

func TestParsePoolsEmpty(t *testing.T) {
	hm := &HAProxyManager{}
	_, _, err := hm.parsePools(strings.NewReader("no pools here\n"))
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "no pools found")
}

func TestParseActivity(t *testing.T) {
	input := `ctxsw: 0 [100 200 300 400]
tasksw: 0 [50 60 70 80]
loops: 0 [1000 2000 3000 4000]
avg_cpu_pct: 0 [25 30 35 40]
avg_loop_us: 0 [100 150 200 250]
accepted: 0 [500 600 700 800]
poll_io: 0 [10 20 30 40]
`

	hm := &HAProxyManager{}
	activities, err := hm.parseActivity(strings.NewReader(input))
	require.NoError(t, err)

	assert.Len(t, activities, 4)
	assert.Equal(t, uint64(1), activities[0].ThreadID)
	assert.Equal(t, uint64(100), activities[0].CtxSwitches)
	assert.Equal(t, uint64(50), activities[0].TaskSwitches)
	assert.Equal(t, uint64(1000), activities[0].Loops)
	assert.Equal(t, uint64(25), activities[0].AvgCpuPct)
	assert.Equal(t, uint64(100), activities[0].AvgLoopUs)
	assert.Equal(t, uint64(500), activities[0].Accepted)
	assert.Equal(t, uint64(10), activities[0].PollIO)

	assert.Equal(t, uint64(4), activities[3].ThreadID)
	assert.Equal(t, uint64(400), activities[3].CtxSwitches)
}

func TestParseActivityEmpty(t *testing.T) {
	hm := &HAProxyManager{}
	_, err := hm.parseActivity(strings.NewReader(""))
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "no activity data")
}

func TestParseServersState(t *testing.T) {
	input := `1
# be_id be_name srv_id srv_name srv_addr srv_op_state srv_admin_state srv_uweight srv_iweight srv_time_since_last_change srv_check_status
3 api_back 1 api_server1 192.168.1.10:8080 2 0 1 1 86400 6
3 api_back 2 api_server2 192.168.1.11:8080 2 0 1 1 43200 6
`

	hm := &HAProxyManager{}
	servers, err := hm.parseServersState(strings.NewReader(input))
	require.NoError(t, err)

	assert.Len(t, servers, 2)
	assert.Equal(t, "api_back", servers[0].Backend)
	assert.Equal(t, "api_server1", servers[0].Server)
	assert.Equal(t, "192.168.1.10", servers[0].Address)
	assert.Equal(t, uint16(8080), servers[0].Port)
	assert.Equal(t, uint8(2), servers[0].OpState)
	assert.Equal(t, uint8(0), servers[0].AdminState)
	assert.Equal(t, uint16(1), servers[0].Weight)
	assert.Equal(t, uint64(86400), servers[0].LastChange)
	assert.Equal(t, uint8(6), servers[0].CheckStatus)
}

func TestParseServersStateEmpty(t *testing.T) {
	hm := &HAProxyManager{}
	servers, err := hm.parseServersState(strings.NewReader("1\n# header line\n"))
	require.NoError(t, err)
	assert.Len(t, servers, 0)
}

func TestCalculateRatesBasic(t *testing.T) {
	hm := &HAProxyManager{
		prevCounters: make(map[string]*haproxyPrevCounters),
	}

	// First call — no previous data, rates should be 0
	stats := []system.HAProxyStats{
		{Name: "web", Type: "FRONTEND", BytesIn: 1000, BytesOut: 2000, Resp2xx: 100},
	}
	hm.calculateRates(stats)
	assert.Equal(t, uint64(0), stats[0].BytesInRate)
	assert.Equal(t, uint64(0), stats[0].BytesOutRate)

	// Simulate time passing — manually set prev time in the past
	for k, v := range hm.prevCounters {
		v.time = v.time.Add(-5 * time.Second)
		hm.prevCounters[k] = v
	}

	// Second call — should calculate rates
	stats2 := []system.HAProxyStats{
		{Name: "web", Type: "FRONTEND", BytesIn: 6000, BytesOut: 12000, Resp2xx: 600},
	}
	hm.calculateRates(stats2)
	assert.InDelta(t, 1000, stats2[0].BytesInRate, 2)   // (6000-1000)/5
	assert.InDelta(t, 2000, stats2[0].BytesOutRate, 2)   // (12000-2000)/5
	assert.InDelta(t, 100, stats2[0].Resp2xxRate, 2)     // (600-100)/5
}

func TestCalculateRatesCounterWrap(t *testing.T) {
	hm := &HAProxyManager{
		prevCounters: make(map[string]*haproxyPrevCounters),
	}

	// Set initial counters
	stats := []system.HAProxyStats{
		{Name: "web", Type: "FRONTEND", BytesIn: 1000, BytesOut: 2000},
	}
	hm.calculateRates(stats)

	// Simulate time passing
	for k, v := range hm.prevCounters {
		v.time = v.time.Add(-5 * time.Second)
		hm.prevCounters[k] = v
	}

	// Counter wrap: new value < old value — rate should be 0 (not negative)
	stats2 := []system.HAProxyStats{
		{Name: "web", Type: "FRONTEND", BytesIn: 500, BytesOut: 800},
	}
	hm.calculateRates(stats2)
	assert.Equal(t, uint64(0), stats2[0].BytesInRate)
	assert.Equal(t, uint64(0), stats2[0].BytesOutRate)
}

func TestCalculateRatesCleanupStaleEntries(t *testing.T) {
	hm := &HAProxyManager{
		prevCounters: make(map[string]*haproxyPrevCounters),
	}

	// First call with two proxies
	stats := []system.HAProxyStats{
		{Name: "web", Type: "FRONTEND", BytesIn: 1000},
		{Name: "api", Type: "FRONTEND", BytesIn: 2000},
	}
	hm.calculateRates(stats)
	assert.Len(t, hm.prevCounters, 2)

	// Second call with only one proxy — stale entry should be cleaned up
	stats2 := []system.HAProxyStats{
		{Name: "web", Type: "FRONTEND", BytesIn: 3000},
	}
	hm.calculateRates(stats2)
	assert.Len(t, hm.prevCounters, 1)
}

func TestParseCSVMalformedLines(t *testing.T) {
	malformedCSV := `# pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status
http_front,FRONTEND,,,10,100,2000,50000,1234567890,9876543210,0,0,5,,,,,OPEN
this,is,a,short,line
backend1,BACKEND,0,0,3,20,50,10000,200000,150000,0,0,,0,0,0,0,UP
`

	hm := &HAProxyManager{}
	stats, err := hm.parseCSV(strings.NewReader(malformedCSV))
	require.NoError(t, err)
	// Should skip the malformed line and parse valid ones
	assert.Len(t, stats, 2)
}

func TestFetchStatsFallback(t *testing.T) {
	// Test that HTTP fallback works when socket fails
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(sampleHAProxyCSV))
	}))
	defer server.Close()

	hm := &HAProxyManager{
		socketPath: "/nonexistent/socket.sock", // Invalid socket
		httpURL:    server.URL,                 // Valid HTTP URL
		httpClient: server.Client(),
	}

	stats, err := hm.fetchStats()
	require.NoError(t, err)
	assert.Len(t, stats, 5)
}
