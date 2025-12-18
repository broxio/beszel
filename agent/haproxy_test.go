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
		prevBytes:  make(map[string]*haproxyPrevBytes),
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
		Name:           "test_proxy",
		Type:           "BACKEND",
		Status:         "UP",
		CurrentSess:    10,
		MaxSess:        100,
		SessionLimit:   1000,
		TotalSess:      50000,
		BytesIn:        1234567890,
		BytesOut:       9876543210,
		RequestRate:    100,
		RequestTotal:   500000,
		ResponseTime:   25,
		ConnRate:       50,
		ConnTotal:      100000,
		Errors4xx:      150,
		Errors5xx:      25,
		HealthCheckOK:  1000,
		HealthCheckFail: 5,
		ActiveServers:  3,
		BackupServers:  1,
	}

	assert.Equal(t, "test_proxy", stats.Name)
	assert.Equal(t, "BACKEND", stats.Type)
	assert.Equal(t, uint64(10), stats.CurrentSess)
	assert.Equal(t, uint64(3), stats.ActiveServers)
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
