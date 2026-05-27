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

#### Opt-in model (different from HAProxy)
HAProxy requires explicit configuration (`HAPROXY_SOCKET` or `HAPROXY_URL`) because the agent can't discover where the admin socket lives. IPVS is the opposite: the kernel exposes everything directly, so the agent **auto-enables on any Linux host with the `ip_vs` module loaded**. No env vars to set. The hostname pattern (`lvs-*`) is the operator-facing opt-in — it controls *visibility* on the `/lvs` aggregate page, not whether the agent collects.

Trade-off: a Kubernetes node running kube-proxy in IPVS mode will also load the module and report data. The UI's hostname filter is the safety net — k8s nodes named `worker-*` won't appear on `/lvs` regardless of what they ship. Payload bloat is negligible (a few hundred bytes per stats push). If this becomes a real problem, add a `strings.HasPrefix(hostname, "lvs-")` gate in `NewIPVSManager`.

### Required Linux capability
The netlink call into the `ip_vs` family requires **`CAP_NET_ADMIN`**. `os.Stat("/proc/net/ip_vs")` works without it (file is world-readable, so the availability check passes), but `GetServices()` returns `EPERM`. The agent logs the failure at DEBUG level only — silent failure in default ops logs is the typical symptom.

**Fix is baked into the packaged systemd unit** (`supplemental/debian/beszel-agent.service`):
```
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
```

For hosts already running an older packaged unit, drop-in override (survives package upgrade):
```bash
sudo mkdir -p /etc/systemd/system/beszel-agent.service.d
sudo tee /etc/systemd/system/beszel-agent.service.d/ipvs.conf <<'EOF'
[Service]
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
EOF
sudo systemctl daemon-reload && sudo systemctl restart beszel-agent
```

### File Structure
- `agent/ipvs.go` — manager skeleton (cross-platform surface)
- `agent/ipvs_linux.go` — netlink collection, VIP-bound role detection, protocol/mode decoding, keepalived override-file reader
- `agent/ipvs_stub.go` — no-op for non-Linux builds
- `internal/entities/system/system.go` — `IPVSStats`, `IPVSService`, `IPVSDest` types (CBOR keys 60+)
- `internal/hub/api.go` — `getIPVSStats` handler at `/api/beszel/ipvs/stats`
- `internal/site/src/lib/ipvs-aggregate.ts` — zone/pair classifiers + group aggregation
- `internal/site/src/components/routes/lvs-aggregate.tsx` — `/lvs` aggregate route page
- `internal/site/src/components/charts/ipvs-panel.tsx` — per-system IPVS panel (used by `/system/<id>`)
- `supplemental/debian/beszel-agent.service` — systemd unit with `AmbientCapabilities=CAP_NET_ADMIN`

### Data Flow
1. Agent's `IPVSManager.fetch()` calls `moby/ipvs` netlink → list services + destinations + kernel rates
2. Build per-service entries (kernel rates as-is), sum destinations to derive service `InactiveConns`
3. Classify role via `classifyRole(vips)` (keepalived override file first, then VIP-bound check)
4. Aggregate to `data.Stats.IPVS` in agent `gatherStats`; ship via existing system_stats pipeline
5. UI polls `/api/beszel/ipvs/stats?ids=...` every 5s for compact payload (avoids full SystemStats blob)
6. Per-group aggregation sums service-level stats only; sparklines accumulate client-side (rolling 5-min window)

### UI status states (per-host badge on `/lvs`)
Computed in `deriveHostStatus(systemStatus, ipvs)`:
- **active** (green) — agent reporting IPVS data, all configured VIPs bound locally → keepalived master
- **standby** (gray) — agent reporting IPVS data, none of the configured VIPs bound locally → keepalived backup
- **unknown** (yellow) — agent reporting IPVS data but partial VIP bind, OR `classifyRole` couldn't enumerate local addresses
- **no-data** (orange) — system status is `up` but no IPVS field in stats. Hover tooltip explains likely causes (CAP_NET_ADMIN missing, ip_vs module not loaded, agent older than mp.1)
- **down** (red) — system status is `down`/`pending`/`paused` — host isn't reporting at all

The `no-data` orange badge is the most common deploy-time issue; surfacing it inline saves a debug round-trip.

### Configuration
- `IPVS_UPDATE_INTERVAL=10s` — override agent collection period (default 5s)
- Hostname pattern is convention only — rename hosts to `lvs-*` to surface them on the aggregate page

### Troubleshooting
Enable debug logging temporarily and inspect the IPVS init line:
```bash
echo 'LOG_LEVEL=debug' | sudo tee -a /etc/beszel-agent.conf
sudo systemctl restart beszel-agent
sleep 3
sudo journalctl -u beszel-agent -n 50 --no-pager | grep -iE 'ipvs'
# clean up:
sudo sed -i '/^LOG_LEVEL=debug$/d' /etc/beszel-agent.conf && sudo systemctl restart beszel-agent
```

Expected outcomes:
| Log line | Meaning | Fix |
|---|---|---|
| `INFO IPVS monitoring enabled` then `DEBUG IPVS role=... services=N` | Working | — |
| `DEBUG IPVS err="ipvs services: operation not permitted"` | Missing `CAP_NET_ADMIN` | Apply drop-in or upgrade agent package to mp.3+ |
| `DEBUG IPVS err="IPVS kernel module not loaded (/proc/net/ip_vs missing)"` | Module not loaded | `sudo modprobe ip_vs ip_vs_rr` (or whichever scheduler keepalived uses) |
| No IPVS line at all in debug | Agent older than mp.1 | Upgrade agent binary |

Hub-side check that the data is reaching the hub:
```bash
curl -s "https://hub.example/api/beszel/ipvs/stats?ids=<system_id>" -H "Authorization: $TOKEN" | jq
# expect: [{"system":"<id>","ipvs":{"r":"active",...}}]
# empty []  → agent isn't shipping the field (check agent-side log table above)
# 404       → hub binary doesn't have the endpoint (upgrade hub to mp.1+)
```

### Version history
| Tag | What it added |
|---|---|
| `v0.18.7-mp.1` | Initial LVS monitoring: agent + hub endpoint + `/lvs` aggregate page, alongside the merged-in HAProxy feature |
| `v0.18.7-mp.2` | Pure version bump to disambiguate "did the new binary actually deploy?" during prod rollout |
| `v0.18.7-mp.3` | `CAP_NET_ADMIN` baked into packaged systemd unit (the prod-blocker fix) |
| `v0.18.7-mp.4` | Per-host status badges on `/lvs` with no-data diagnostic tooltip; new IPVS panel on `/system/<id>` |

## Vector Aggregator Monitoring

### Architecture Decisions

#### Data source: Vector's GraphQL API
Vector ships a GraphQL endpoint (default `:8686`) that powers `vector top`. The agent issues one batched HTTP POST per poll containing `health`, `meta { versionString hostname }`, and `components(first: 10000)` with each component's `receivedEventsTotal`, `sentEventsTotal`, `receivedBytesTotal`, `sentBytesTotal`, `errorsTotal`, `discardedEventsTotal`. Cursor pagination is skipped — pipelines well under 10000 components is the assumption.

Vector exposes **cumulative counters only**. The agent ships them as-is and the UI derives per-second rates client-side from successive samples (parallels HAProxy, in contrast to LVS where the kernel estimator provides rates directly).

#### Opt-in via env var (different from LVS)
Unlike LVS (auto-enables on any host with the `ip_vs` module), Vector is **opt-in via `VECTOR_API_URL`** on the agent. Justification: Vector's GraphQL API has to be explicitly enabled in `vector.toml` (`api.enabled = true`) and bound to a port — there's no kernel-level discovery hook. When unset, `NewVectorManager` returns `(nil, errVectorDisabled)` and the agent skips Vector collection.

Accepted forms of `VECTOR_API_URL`:
- `http://127.0.0.1:8686`
- `http://127.0.0.1:8686/graphql`
- `127.0.0.1:8686` (scheme defaulted to `http://`, path to `/graphql`)

#### Visibility on `/vector` (no hostname pattern)
HAProxy/LVS gate visibility on the aggregate page by hostname (`ha-*`, `lvs-*`). Vector skips that convention because Vector deployments are heterogeneous (aggregators, edge collectors, single-tenant pipelines) and hostnames already encode other concerns. **Visibility = presence of the `vec` field in the latest stats record** — i.e. the operator's `VECTOR_API_URL` decision is the opt-in.

#### Polling cadence
- Agent → Vector: 5s default, override with `VECTOR_UPDATE_INTERVAL` env var
- Hub `/api/beszel/vector/stats` → UI: 5s on the `/vector` aggregate page
- Per-system panel on `/system/<id>` reads from the existing `systemStats` history (same cadence as the rest of that page)

The "live" feel of `vector top` would require either WebSocket subscriptions through the agent tunnel (significant new transport work) or hub→agent direct reachability (typically blocked by NAT). Decision: ship the polling version first; subscriptions are an explicit follow-up if 5s isn't tight enough in practice.

#### Aggregation rules
Vector pipelines are independent per host so a plain sum across hosts is correct (no double-counting concern like HAProxy frontend/backend or IPVS service/destination).

Per-host aggregates:
- `received_events / received_bytes` → summed across **source-kind** components only
- `sent_events / sent_bytes` → summed across **sink-kind** components only
- `errors_total / discarded_events_total` → summed across **all** components

This avoids triple-counting (events that flow source → transform → sink would otherwise show 3× the actual throughput in the host-level aggregate).

### File Structure
- `agent/vector.go` — `VectorManager`, HTTP+GraphQL client, endpoint normalization, polling state
- `internal/entities/system/system.go` — `VectorStats`, `VectorComponent` types (CBOR keys 80+)
- `internal/hub/api.go` — `getVectorStats` handler at `/api/beszel/vector/stats`
- `internal/site/src/lib/vector-aggregate.ts` — visibility filter, group totals, rate derivation, formatters, host status
- `internal/site/src/components/routes/vector-aggregate.tsx` — `/vector` aggregate route
- `internal/site/src/components/charts/vector-panel.tsx` — per-system Vector panel (mounted from `/system/<id>` when `vec` is present)

### Data Flow
1. Agent's `VectorManager.fetch()` POSTs one bundled GraphQL query to `VECTOR_API_URL`
2. Build per-component entries from the response; sum per-kind totals (sources / transforms / sinks)
3. Aggregate to `data.Stats.Vector` in agent `gatherStats`; ship via existing system_stats pipeline
4. UI polls `/api/beszel/vector/stats?ids=...` every 5s on the aggregate page; derives rates client-side from successive cumulative-counter samples
5. Per-system panel reads `systemStats.at(-1)?.stats?.vec` (no separate poll — same data cadence as the rest of the system page)

### UI status states (per-host badge on `/vector`)
Computed in `deriveHostStatus(systemStatus, vec)`:
- **healthy** (green) — agent reporting Vector data and `health: true`
- **unhealthy** (red) — agent reporting Vector data and `health: false`
- **no-data** (orange) — system status is `up` but no `vec` field. Hover tooltip explains likely causes (`VECTOR_API_URL` unset, Vector GraphQL endpoint unreachable, agent older than the build that introduced Vector support)
- **down** (gray) — host isn't reporting at all

### Configuration
- `VECTOR_API_URL=http://127.0.0.1:8686/graphql` — enables collection (required)
- `VECTOR_UPDATE_INTERVAL=5s` — override agent collection period (default 5s)
- Vector side: `api.enabled = true` and `api.address = "127.0.0.1:8686"` in `vector.toml`

### Troubleshooting
Enable debug logging temporarily and inspect the Vector init line:
```bash
echo 'LOG_LEVEL=debug' | sudo tee -a /etc/beszel-agent.conf
echo 'VECTOR_API_URL=http://127.0.0.1:8686/graphql' | sudo tee -a /etc/beszel-agent.conf
sudo systemctl restart beszel-agent
sleep 3
sudo journalctl -u beszel-agent -n 50 --no-pager | grep -iE 'vector'
```

Expected outcomes:
| Log line | Meaning | Fix |
|---|---|---|
| `INFO Vector monitoring enabled endpoint=...` | Working | — |
| `DEBUG Vector err="VECTOR_API_URL not set"` | env var missing | Set `VECTOR_API_URL` |
| `DEBUG Vector err="vector http: ... connection refused"` | Vector API not listening | Enable `api { enabled = true }` in `vector.toml` |
| `DEBUG Vector err="vector status 404: ..."` | Wrong path | Append `/graphql` to the URL |
| `DEBUG Vector err="vector graphql: ..."` | Schema mismatch (older Vector) | Upgrade Vector, or report the field that's missing |

Hub-side check that the data is reaching the hub:
```bash
curl -s "https://hub.example/api/beszel/vector/stats?ids=<system_id>" -H "Authorization: $TOKEN" | jq
# expect: [{"system":"<id>","vector":{"hl":true,"v":"0.43.0",...}}]
# empty []  → agent isn't shipping the field (check agent-side log table above)
# 404       → hub binary doesn't have the endpoint (upgrade hub)
```
