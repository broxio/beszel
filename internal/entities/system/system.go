package system

// TODO: this is confusing, make common package with common/types common/helpers etc

import (
	"encoding/json"
	"time"

	"github.com/henrygd/beszel/internal/entities/container"
	"github.com/henrygd/beszel/internal/entities/systemd"
)

type Stats struct {
	Cpu            float64             `json:"cpu" cbor:"0,keyasint"`
	MaxCpu         float64             `json:"cpum,omitempty" cbor:"1,keyasint,omitempty"`
	Mem            float64             `json:"m" cbor:"2,keyasint"`
	MemUsed        float64             `json:"mu" cbor:"3,keyasint"`
	MemPct         float64             `json:"mp" cbor:"4,keyasint"`
	MemBuffCache   float64             `json:"mb" cbor:"5,keyasint"`
	MemZfsArc      float64             `json:"mz,omitempty" cbor:"6,keyasint,omitempty"` // ZFS ARC memory
	Swap           float64             `json:"s,omitempty" cbor:"7,keyasint,omitempty"`
	SwapUsed       float64             `json:"su,omitempty" cbor:"8,keyasint,omitempty"`
	DiskTotal      float64             `json:"d" cbor:"9,keyasint"`
	DiskUsed       float64             `json:"du" cbor:"10,keyasint"`
	DiskPct        float64             `json:"dp" cbor:"11,keyasint"`
	DiskReadPs     float64             `json:"dr" cbor:"12,keyasint"`
	DiskWritePs    float64             `json:"dw" cbor:"13,keyasint"`
	MaxDiskReadPs  float64             `json:"drm,omitempty" cbor:"14,keyasint,omitempty"`
	MaxDiskWritePs float64             `json:"dwm,omitempty" cbor:"15,keyasint,omitempty"`
	NetworkSent    float64             `json:"ns,omitzero" cbor:"16,keyasint,omitzero"`
	NetworkRecv    float64             `json:"nr,omitzero" cbor:"17,keyasint,omitzero"`
	MaxNetworkSent float64             `json:"nsm,omitempty" cbor:"18,keyasint,omitempty"`
	MaxNetworkRecv float64             `json:"nrm,omitempty" cbor:"19,keyasint,omitempty"`
	Temperatures   map[string]float64  `json:"t,omitempty" cbor:"20,keyasint,omitempty"`
	ExtraFs        map[string]*FsStats `json:"efs,omitempty" cbor:"21,keyasint,omitempty"`
	GPUData        map[string]GPUData  `json:"g,omitempty" cbor:"22,keyasint,omitempty"`
	LoadAvg1       float64             `json:"l1,omitempty" cbor:"23,keyasint,omitempty"`
	LoadAvg5       float64             `json:"l5,omitempty" cbor:"24,keyasint,omitempty"`
	LoadAvg15      float64             `json:"l15,omitempty" cbor:"25,keyasint,omitempty"`
	Bandwidth      [2]uint64           `json:"b,omitzero" cbor:"26,keyasint,omitzero"`  // [sent bytes, recv bytes]
	MaxBandwidth   [2]uint64           `json:"bm,omitzero" cbor:"27,keyasint,omitzero"` // [sent bytes, recv bytes]
	// TODO: remove other load fields in future release in favor of load avg array
	LoadAvg           [3]float64           `json:"la,omitempty" cbor:"28,keyasint"`
	Battery           [2]uint8             `json:"bat,omitzero" cbor:"29,keyasint,omitzero"` // [percent, charge state, current]
	MaxMem            float64              `json:"mm,omitempty" cbor:"30,keyasint,omitempty"`
	NetworkInterfaces map[string][4]uint64 `json:"ni,omitempty" cbor:"31,keyasint,omitempty"`   // [upload bytes, download bytes, total upload, total download]
	DiskIO            [2]uint64            `json:"dio,omitzero" cbor:"32,keyasint,omitzero"`    // [read bytes, write bytes]
	MaxDiskIO         [2]uint64            `json:"diom,omitzero" cbor:"-"`                      // [max read bytes, max write bytes]
	CpuBreakdown      []float64            `json:"cpub,omitempty" cbor:"33,keyasint,omitempty"` // [user, system, iowait, steal, idle]
	CpuCoresUsage     Uint8Slice           `json:"cpus,omitempty" cbor:"34,keyasint,omitempty"` // per-core busy usage [CPU0..]
	HAProxy            []HAProxyStats        `json:"hap,omitempty" cbor:"35,keyasint,omitempty"`  // HAProxy frontend/backend stats
	HAProxyInfo        *HAProxyInfo          `json:"hapi,omitempty" cbor:"36,keyasint,omitempty"` // HAProxy process info
	HAProxyPools       []HAProxyPool         `json:"hpp,omitempty" cbor:"37,keyasint,omitempty"`  // HAProxy memory pools
	HAProxyPoolSummary *HAProxyPoolSummary   `json:"hpps,omitempty" cbor:"38,keyasint,omitempty"` // HAProxy pool summary
	HAProxyActivity    []HAProxyActivity     `json:"hpa,omitempty" cbor:"39,keyasint,omitempty"`  // HAProxy thread activity
	HAProxyServers     []HAProxyServerState  `json:"hpsv,omitempty" cbor:"40,keyasint,omitempty"` // HAProxy server states
}

// Uint8Slice wraps []uint8 to customize JSON encoding while keeping CBOR efficient.
// JSON: encodes as array of numbers (avoids base64 string).
// CBOR: falls back to default handling for []uint8 (byte string), keeping payload small.
type Uint8Slice []uint8

func (s Uint8Slice) MarshalJSON() ([]byte, error) {
	if s == nil {
		return []byte("null"), nil
	}
	// Convert to wider ints to force array-of-numbers encoding.
	arr := make([]uint16, len(s))
	for i, v := range s {
		arr[i] = uint16(v)
	}
	return json.Marshal(arr)
}

type GPUData struct {
	Name        string             `json:"n" cbor:"0,keyasint"`
	Temperature float64            `json:"-"`
	MemoryUsed  float64            `json:"mu,omitempty,omitzero" cbor:"1,keyasint,omitempty,omitzero"`
	MemoryTotal float64            `json:"mt,omitempty,omitzero" cbor:"2,keyasint,omitempty,omitzero"`
	Usage       float64            `json:"u" cbor:"3,keyasint,omitempty"`
	Power       float64            `json:"p,omitempty" cbor:"4,keyasint,omitempty"`
	Count       float64            `json:"-"`
	Engines     map[string]float64 `json:"e,omitempty" cbor:"5,keyasint,omitempty"`
	PowerPkg    float64            `json:"pp,omitempty" cbor:"6,keyasint,omitempty"`
}

type FsStats struct {
	Time           time.Time `json:"-"`
	Root           bool      `json:"-"`
	Mountpoint     string    `json:"-"`
	Name           string    `json:"-"`
	DiskTotal      float64   `json:"d" cbor:"0,keyasint"`
	DiskUsed       float64   `json:"du" cbor:"1,keyasint"`
	TotalRead      uint64    `json:"-"`
	TotalWrite     uint64    `json:"-"`
	DiskReadPs     float64   `json:"r" cbor:"2,keyasint"`
	DiskWritePs    float64   `json:"w" cbor:"3,keyasint"`
	MaxDiskReadPS  float64   `json:"rm,omitempty" cbor:"4,keyasint,omitempty"`
	MaxDiskWritePS float64   `json:"wm,omitempty" cbor:"5,keyasint,omitempty"`
	// TODO: remove DiskReadPs and DiskWritePs in future release in favor of DiskReadBytes and DiskWriteBytes
	DiskReadBytes     uint64 `json:"rb" cbor:"6,keyasint,omitempty"`
	DiskWriteBytes    uint64 `json:"wb" cbor:"7,keyasint,omitempty"`
	MaxDiskReadBytes  uint64 `json:"rbm,omitempty" cbor:"-"`
	MaxDiskWriteBytes uint64 `json:"wbm,omitempty" cbor:"-"`
}

type NetIoStats struct {
	BytesRecv uint64
	BytesSent uint64
	Time      time.Time
	Name      string
}

// HAProxyStats contains metrics for a HAProxy frontend or backend
type HAProxyStats struct {
	Name            string `json:"n" cbor:"0,keyasint"`                        // proxy name (frontend/backend)
	Type            string `json:"t" cbor:"1,keyasint"`                        // FRONTEND, BACKEND, or SERVER
	Status          string `json:"s" cbor:"2,keyasint"`                        // UP, DOWN, OPEN, etc.
	CurrentSess     uint64 `json:"sc" cbor:"3,keyasint"`                       // current sessions
	MaxSess         uint64 `json:"sm,omitempty" cbor:"4,keyasint,omitempty"`   // max sessions
	SessionLimit    uint64 `json:"sl,omitempty" cbor:"5,keyasint,omitempty"`   // configured session limit
	TotalSess       uint64 `json:"st" cbor:"6,keyasint"`                       // cumulative total sessions
	BytesIn         uint64 `json:"bi" cbor:"7,keyasint"`                       // bytes in (cumulative)
	BytesOut        uint64 `json:"bo" cbor:"8,keyasint"`                       // bytes out (cumulative)
	RequestRate     uint64 `json:"rr,omitempty" cbor:"9,keyasint,omitempty"`   // requests/sessions per second
	RequestTotal    uint64 `json:"rt,omitempty" cbor:"10,keyasint,omitempty"`  // total HTTP requests
	ResponseTime    uint64 `json:"rsp,omitempty" cbor:"11,keyasint,omitempty"` // avg response time (ms)
	Resp1xx         uint64 `json:"r1,omitempty" cbor:"12,keyasint,omitempty"`  // 1xx responses (cumulative)
	Resp2xx         uint64 `json:"r2,omitempty" cbor:"13,keyasint,omitempty"`  // 2xx responses (cumulative)
	Resp3xx         uint64 `json:"r3,omitempty" cbor:"14,keyasint,omitempty"`  // 3xx responses (cumulative)
	Resp4xx         uint64 `json:"r4,omitempty" cbor:"15,keyasint,omitempty"`  // 4xx responses (cumulative)
	Resp5xx         uint64 `json:"r5,omitempty" cbor:"16,keyasint,omitempty"`  // 5xx responses (cumulative)
	Resp1xxRate     uint64 `json:"r1r,omitempty" cbor:"17,keyasint,omitempty"` // 1xx per second
	Resp2xxRate     uint64 `json:"r2r,omitempty" cbor:"18,keyasint,omitempty"` // 2xx per second
	Resp3xxRate     uint64 `json:"r3r,omitempty" cbor:"19,keyasint,omitempty"` // 3xx per second
	Resp4xxRate     uint64 `json:"r4r,omitempty" cbor:"20,keyasint,omitempty"` // 4xx per second
	Resp5xxRate     uint64 `json:"r5r,omitempty" cbor:"21,keyasint,omitempty"` // 5xx per second
	HealthCheckFail uint64 `json:"hfl,omitempty" cbor:"22,keyasint,omitempty"` // failed health checks
	ActiveServers   uint64 `json:"as,omitempty" cbor:"23,keyasint,omitempty"`  // active servers (for backends)
	BackupServers   uint64 `json:"bs,omitempty" cbor:"24,keyasint,omitempty"`  // backup servers (for backends)
	BytesInRate     uint64 `json:"bir,omitempty" cbor:"25,keyasint,omitempty"` // bytes in per second
	BytesOutRate    uint64 `json:"bor,omitempty" cbor:"26,keyasint,omitempty"` // bytes out per second
}

// HAProxyInfo contains HAProxy process information from "show info"
type HAProxyInfo struct {
	Version        string `json:"v" cbor:"0,keyasint"`                       // HAProxy version
	Uptime         string `json:"up" cbor:"1,keyasint"`                      // uptime string
	UptimeSec      uint64 `json:"us" cbor:"2,keyasint"`                      // uptime in seconds
	MemMaxMB       uint64 `json:"mm,omitempty" cbor:"3,keyasint,omitempty"`  // max memory MB
	PoolAllocMB    uint64 `json:"pa,omitempty" cbor:"4,keyasint,omitempty"`  // pool allocated MB
	PoolUsedMB     uint64 `json:"pu,omitempty" cbor:"5,keyasint,omitempty"`  // pool used MB
	Nbthread       uint64 `json:"nt" cbor:"6,keyasint"`                      // number of threads
	Maxconn        uint64 `json:"mc" cbor:"7,keyasint"`                      // max connections
	CurrConns      uint64 `json:"cc" cbor:"8,keyasint"`                      // current connections
	CumConns       uint64 `json:"tc" cbor:"9,keyasint"`                      // cumulative connections
	CumReq         uint64 `json:"tr" cbor:"10,keyasint"`                     // cumulative requests
	MaxSslConns    uint64 `json:"msc,omitempty" cbor:"11,keyasint,omitempty"` // max SSL connections
	CurrSslConns   uint64 `json:"csc,omitempty" cbor:"12,keyasint,omitempty"` // current SSL connections
	CumSslConns    uint64 `json:"tsc,omitempty" cbor:"13,keyasint,omitempty"` // cumulative SSL connections
	ConnRate       uint64 `json:"cr,omitempty" cbor:"14,keyasint,omitempty"`  // connection rate
	MaxConnRate    uint64 `json:"mcr,omitempty" cbor:"15,keyasint,omitempty"` // max connection rate
	SessRate       uint64 `json:"sr,omitempty" cbor:"16,keyasint,omitempty"`  // session rate
	MaxSessRate    uint64 `json:"msr,omitempty" cbor:"17,keyasint,omitempty"` // max session rate
	SslRate        uint64 `json:"slr,omitempty" cbor:"18,keyasint,omitempty"`  // SSL rate
	MaxSslRate     uint64 `json:"mslr,omitempty" cbor:"19,keyasint,omitempty"` // max SSL rate
	SslReusePct    uint64 `json:"srp,omitempty" cbor:"27,keyasint,omitempty"`  // SSL frontend session reuse %
	Tasks          uint64 `json:"tk,omitempty" cbor:"20,keyasint,omitempty"`  // tasks
	RunQueue       uint64 `json:"rq,omitempty" cbor:"21,keyasint,omitempty"`  // run queue
	IdlePct        uint64 `json:"ip,omitempty" cbor:"22,keyasint,omitempty"`  // idle percent
	Node           string `json:"nd,omitempty" cbor:"23,keyasint,omitempty"`  // node name
	TotalBytesOut  uint64 `json:"bo,omitempty" cbor:"24,keyasint,omitempty"`  // total bytes out
	BytesOutRate   uint64 `json:"bor,omitempty" cbor:"25,keyasint,omitempty"` // bytes out rate
	Pid            uint64 `json:"pid,omitempty" cbor:"26,keyasint,omitempty"` // process ID
}

// HAProxyPool represents a single memory pool from "show pools"
type HAProxyPool struct {
	Name      string `json:"n" cbor:"0,keyasint"`                       // pool name
	Size      uint64 `json:"sz" cbor:"1,keyasint"`                      // element size (bytes)
	Allocated uint64 `json:"a" cbor:"2,keyasint"`                       // total allocated bytes
	Used      uint64 `json:"u" cbor:"3,keyasint"`                       // total used count
	InCache   uint64 `json:"ic,omitempty" cbor:"4,keyasint,omitempty"`  // in thread caches
	Failures  uint64 `json:"f,omitempty" cbor:"5,keyasint,omitempty"`   // allocation failures
}

// HAProxyPoolSummary contains total pool statistics
type HAProxyPoolSummary struct {
	TotalPools     uint64 `json:"tp" cbor:"0,keyasint"`                      // number of pools
	TotalAllocated uint64 `json:"ta" cbor:"1,keyasint"`                      // total allocated bytes
	TotalUsed      uint64 `json:"tu" cbor:"2,keyasint"`                      // total used bytes
	InThreadCaches uint64 `json:"tc,omitempty" cbor:"3,keyasint,omitempty"`  // bytes in thread caches
}

// HAProxyActivity represents per-thread activity from "show activity"
type HAProxyActivity struct {
	ThreadID     uint64 `json:"tid" cbor:"0,keyasint"`                     // thread ID
	CtxSwitches  uint64 `json:"cs" cbor:"1,keyasint"`                      // context switches
	TaskSwitches uint64 `json:"ts" cbor:"2,keyasint"`                      // task switches
	Loops        uint64 `json:"lp" cbor:"3,keyasint"`                      // main loops
	AvgCpuPct    uint64 `json:"cpu" cbor:"4,keyasint"`                     // average CPU %
	AvgLoopUs    uint64 `json:"lus" cbor:"5,keyasint"`                     // average loop time (us)
	Accepted     uint64 `json:"acc,omitempty" cbor:"6,keyasint,omitempty"` // accepted connections
	PollIO       uint64 `json:"pio,omitempty" cbor:"7,keyasint,omitempty"` // poll I/O events
}

// HAProxyServerState represents server state from "show servers state"
type HAProxyServerState struct {
	Backend     string `json:"bk" cbor:"0,keyasint"`                       // backend name
	Server      string `json:"sv" cbor:"1,keyasint"`                       // server name
	Address     string `json:"addr" cbor:"2,keyasint"`                     // server address
	Port        uint16 `json:"port" cbor:"3,keyasint"`                     // server port
	OpState     uint8  `json:"os" cbor:"4,keyasint"`                       // operational state (0=stopped, 2=running)
	AdminState  uint8  `json:"as" cbor:"5,keyasint"`                       // admin state
	Weight      uint16 `json:"w" cbor:"6,keyasint"`                        // current weight
	CheckStatus uint8  `json:"cks,omitempty" cbor:"7,keyasint,omitempty"`  // check status
	LastChange  uint64 `json:"lc,omitempty" cbor:"8,keyasint,omitempty"`   // seconds since last change
}

type Os = uint8

const (
	Linux Os = iota
	Darwin
	Windows
	Freebsd
)

type ConnectionType = uint8

const (
	ConnectionTypeNone ConnectionType = iota
	ConnectionTypeSSH
	ConnectionTypeWebSocket
)

// Core system data that is needed in All Systems table
type Info struct {
	Hostname      string `json:"h,omitempty" cbor:"0,keyasint,omitempty"` // deprecated - moved to Details struct
	KernelVersion string `json:"k,omitempty" cbor:"1,keyasint,omitempty"` // deprecated - moved to Details struct
	Cores         int    `json:"c,omitzero" cbor:"2,keyasint,omitzero"`   // deprecated - moved to Details struct
	// Threads is needed in Info struct to calculate load average thresholds
	Threads        int     `json:"t,omitempty" cbor:"3,keyasint,omitempty"`
	CpuModel       string  `json:"m,omitempty" cbor:"4,keyasint,omitempty"` // deprecated - moved to Details struct
	Uptime         uint64  `json:"u" cbor:"5,keyasint"`
	Cpu            float64 `json:"cpu" cbor:"6,keyasint"`
	MemPct         float64 `json:"mp" cbor:"7,keyasint"`
	DiskPct        float64 `json:"dp" cbor:"8,keyasint"`
	Bandwidth      float64 `json:"b" cbor:"9,keyasint"`
	AgentVersion   string  `json:"v" cbor:"10,keyasint"`
	Podman         bool    `json:"p,omitempty" cbor:"11,keyasint,omitempty"` // deprecated - moved to Details struct
	GpuPct         float64 `json:"g,omitempty" cbor:"12,keyasint,omitempty"`
	DashboardTemp  float64 `json:"dt,omitempty" cbor:"13,keyasint,omitempty"`
	Os             Os      `json:"os,omitempty" cbor:"14,keyasint,omitempty"`  // deprecated - moved to Details struct
	LoadAvg1       float64 `json:"l1,omitempty" cbor:"15,keyasint,omitempty"`  // deprecated - use `la` array instead
	LoadAvg5       float64 `json:"l5,omitempty" cbor:"16,keyasint,omitempty"`  // deprecated - use `la` array instead
	LoadAvg15      float64 `json:"l15,omitempty" cbor:"17,keyasint,omitempty"` // deprecated - use `la` array instead
	BandwidthBytes uint64  `json:"bb" cbor:"18,keyasint"`

	LoadAvg        [3]float64         `json:"la,omitempty" cbor:"19,keyasint"`
	ConnectionType ConnectionType     `json:"ct,omitempty" cbor:"20,keyasint,omitempty,omitzero"`
	ExtraFsPct     map[string]float64 `json:"efs,omitempty" cbor:"21,keyasint,omitempty"`
	Services       []uint16           `json:"sv,omitempty" cbor:"22,keyasint,omitempty"` // [totalServices, numFailedServices]
	Battery        [2]uint8           `json:"bat,omitzero" cbor:"23,keyasint,omitzero"`  // [percent, charge state]
}

// Data that does not change during process lifetime and is not needed in All Systems table
type Details struct {
	Hostname      string        `cbor:"0,keyasint"`
	Kernel        string        `cbor:"1,keyasint,omitempty"`
	Cores         int           `cbor:"2,keyasint"`
	Threads       int           `cbor:"3,keyasint"`
	CpuModel      string        `cbor:"4,keyasint"`
	Os            Os            `cbor:"5,keyasint"`
	OsName        string        `cbor:"6,keyasint"`
	Arch          string        `cbor:"7,keyasint"`
	Podman        bool          `cbor:"8,keyasint,omitempty"`
	MemoryTotal   uint64        `cbor:"9,keyasint"`
	SmartInterval time.Duration `cbor:"10,keyasint,omitempty"`
}

// Final data structure to return to the hub
type CombinedData struct {
	Stats           Stats              `json:"stats" cbor:"0,keyasint"`
	Info            Info               `json:"info" cbor:"1,keyasint"`
	Containers      []*container.Stats `json:"container" cbor:"2,keyasint"`
	SystemdServices []*systemd.Service `json:"systemd,omitempty" cbor:"3,keyasint,omitempty"`
	Details         *Details           `cbor:"4,keyasint,omitempty"`
}
