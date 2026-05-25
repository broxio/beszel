# Project Notes

## HAProxy Monitoring

### Architecture Decisions

#### Traffic Calculation (Frontend Only)
**Problem:** When aggregating traffic across HAProxy instances, counting both FRONTEND and BACKEND stats results in double-counting. This is because:
- Frontend In → Backend Out (same traffic)
- Backend In → Frontend Out (same traffic)

**Solution:** Only count FRONTEND stats for traffic metrics:
- `bytesIn`, `bytesOut`, `bytesInRate`, `bytesOutRate`
- `requestRate`, `totalRequests`
- HTTP responses (`resp1xx` - `resp5xx`)
- Sessions (`currentSessions`, `totalSessions`)

BACKEND stats are only used for:
- `activeServers`, `backupServers`
- `backendCount`

This aligns with network monitoring tools like Cacti that measure actual client-facing traffic.

#### Zone/Pre-Group Classification
HAProxy systems are classified into zones based on hostname patterns:
- `ha-pre-*` → **PRE** (Pre-production)
- `ha-uat-*` → **UAT** (User Acceptance Testing)
- `ha-lan*` → **LAN** (Internal/Local)
- `ha-*` (others) → **WAN** (External/Internet-facing)

#### Traffic Sparklines
- Client-side accumulation of polling data (no extra backend calls)
- 30 data points at 10-second intervals = 5-minute rolling window
- History stored in ref to avoid unnecessary re-renders
- Combined sparklines for filtered/selected groups in Summary and Traffic Overview cards

#### Connection Retry Logic (Agent)
HAProxy socket connections use exponential backoff for resilience:
- **Max retries:** 3 attempts per operation
- **Initial backoff:** 100ms
- **Backoff multiplier:** 2.0x (100ms → 200ms → 400ms)
- **Max backoff cap:** 2 seconds
- **Health tracking:** Consecutive failures tracked, warning logged after 5+ failures

Key functions in `agent/haproxy.go`:
- `dialSocketWithRetry()` - Socket connection with exponential backoff
- `executeSocketCommand()` - Unified helper for all socket commands
- `GetConnectionHealth()` - Exposes failure count for monitoring

All fetch operations use retry logic: `fetchInfo`, `fetchStats`, `fetchPools`, `fetchActivity`, `fetchServersState`

### File Structure
- `internal/site/src/components/routes/haproxy-aggregate.tsx` - Main aggregate page
- `internal/site/src/lib/haproxy-aggregate.ts` - Calculation utilities and types
- `agent/haproxy.go` - HAProxy agent with stats collection and retry logic

### Data Flow
1. Page polls `system_stats` collection every 10 seconds
2. Filters systems matching `ha-*` pattern
3. Groups systems by pattern (e.g., `ha-web-1`, `ha-web-2` → `ha-web`)
4. Calculates aggregates per group (FRONTEND stats only for traffic)
5. Accumulates traffic history for sparklines
6. Displays combined data based on zone/group selection

## Build Notes

### Docker Multi-Platform Build

**ARM v7 Not Supported** (as of upstream v0.18.x)

The upstream added GPU NVML support using the `purego` library (`github.com/ebitengine/purego`), which does not support ARM v7 architecture.

**Error when building for `linux/arm/v7`:**
```
# github.com/ebitengine/purego/internal/fakecgo
undefined: threadentry
undefined: x_cgo_init
undefined: _cgo_sys_thread_start
```

**Workaround:** Exclude ARM v7 from build platforms:
```bash
# Build without ARM v7
PLATFORMS="linux/amd64,linux/arm64" REGISTRY=docker.io/username PUSH=true ./build-docker.sh
```

**Supported platforms:**
- `linux/amd64` ✓
- `linux/arm64` ✓
- `linux/arm/v7` ✗ (purego incompatibility)

### Git Workflow

**Remotes:**
- `origin` → GitHub (upstream fork)
- `gitlab` → Self-hosted GitLab
- `upstream` → Original upstream repo

**Sync main from GitHub to GitLab:**
```bash
git checkout main
git pull origin main
git push gitlab main
```

**Update feature branch (merge strategy):**
```bash
git checkout feature/haproxy-monitoring
git merge main
git push gitlab feature/haproxy-monitoring
```

## LVS / IPVS Monitoring

### Architecture Decisions

#### Data source: netlink via `moby/ipvs` (Linux only)
`/proc/net/ip_vs` exposes service/destination *config* and `/proc/net/ip_vs_stats` exposes only *global totals*. Per-service rates (CPS/BPS/PPS) are only available via netlink — same path `ipvsadm --stats` uses. Build is gated by `agent/ipvs_linux.go` (`//go:build linux`) and `agent/ipvs_stub.go` (`//go:build !linux`).

#### Traffic counting (service-level only)
`service.bytes_in == sum(destination.bytes_in)` because every client connection becomes one backend connection. Counting both double-counts. The agent reports per-service AND per-destination stats; the UI aggregates **only service-level** for group totals (parallels HAProxy's "FRONTEND only" rule).

#### Active/Standby detection
IPVS has no active/standby concept — that's keepalived/VRRP. Detection precedence:
1. **Override file** `/var/run/beszel-vrrp-state` — if present, content of `master`/`active` or `backup`/`standby` wins. Wire via keepalived `notify_master` / `notify_backup` scripts.
2. **VIP-bound check** (default) — if every IPVS-configured VIP is bound to a local non-loopback interface → `active`; if none are → `standby`; partial bind → `unknown`. Cheapest reliable signal, requires zero keepalived config.

Sample keepalived snippet for the override:
```
notify_master "/bin/sh -c 'echo master > /var/run/beszel-vrrp-state'"
notify_backup "/bin/sh -c 'echo backup > /var/run/beszel-vrrp-state'"
```

#### Kernel-provided rates
IPVS estimator already computes CPS/BPS/PPS per service every 2s. Agent reports these as-is; **no client-side delta calculation** unlike the HAProxy path. Counters (BytesIn/Out, Connections) are also reported for cumulative views.

#### Zone classification
Same convention as HAProxy:
- `lvs-pre-*` → **PRE**
- `lvs-uat-*` → **UAT**
- `lvs-lan*` → **LAN**
- `lvs-*` (others) → **WAN**

Pair grouping strips trailing `-<n>` suffix (`lvs-web-1` + `lvs-web-2` → group `lvs-web`).

### File Structure
- `agent/ipvs.go` — manager skeleton (cross-platform surface)
- `agent/ipvs_linux.go` — netlink collection, VIP-bound role detection, protocol/mode decoding
- `agent/ipvs_stub.go` — no-op for non-Linux builds
- `internal/entities/system/system.go` — `IPVSStats`, `IPVSService`, `IPVSDest` types (CBOR keys 60+)
- `internal/hub/api.go` — `getIPVSStats` handler at `/api/beszel/ipvs/stats`
- `internal/site/src/lib/ipvs-aggregate.ts` — zone/pair classifiers + group aggregation
- `internal/site/src/components/routes/lvs-aggregate.tsx` — `/lvs` route page

### Data Flow
1. Agent's `IPVSManager.fetch()` calls `moby/ipvs` netlink → list services + destinations + kernel rates
2. Build per-service entries (kernel rates as-is), sum destinations to derive service `InactiveConns`
3. Classify role via `classifyRole(vips)` (keepalived override file first, then VIP-bound check)
4. Aggregate to `data.Stats.IPVS` in agent `gatherStats`; ship via existing system_stats pipeline
5. UI polls `/api/beszel/ipvs/stats?ids=...` every 5s for compact payload (avoids full SystemStats blob)
6. Per-group aggregation sums service-level stats only; sparklines accumulate client-side (rolling 5-min window)

### Configuration
- `IPVS_UPDATE_INTERVAL=10s` — override agent collection period (default 5s)
- Hostname pattern is convention; rename hosts to `lvs-*` to opt-in
