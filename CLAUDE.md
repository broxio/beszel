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

### High-Resolution HAProxy Recording (hub → DuckDB)

**Problem:** The per-second HAProxy data on `/system/<id>` is *ephemeral* — `system_realtime.go`'s
1s worker only runs while a browser is subscribed and broadcasts without persisting. The durable
path (`system.go` → `createRecords` → `system_stats`) always runs but only at the ~60s system poll
`interval` and lands in PocketBase SQLite. So there's no high-resolution HAProxy history for
troubleshooting.

**Solution:** an always-on, UI-independent recorder in the hub that samples HAProxy from every
reporting agent and appends an NDJSON spool, loaded into a *dedicated* DuckDB by a script.

#### Why NDJSON spool + loader (not embedded cgo DuckDB)
- Keeps the hub **pure-Go** (go-duckdb is cgo → breaks the multi-arch build; see Build Notes ARM cgo pain).
- DuckDB is single-writer-per-process; a spool keeps the hub out of the DB lock so `duck-haproxy-report.sh` reads never contend.
- Append-only NDJSON is crash-safe and trivial; reuses the existing dockerized duckdb `read_json_auto` + `ON CONFLICT DO NOTHING` ingest pattern.

#### Concurrency-safety key fact
A naive loop calling `sys.fetchDataFromAgent()` would **race** the realtime worker — that returns the
*shared* `sys.data` buffer (`system.go:504/565`). The recorder instead calls `sys.fetchForRecorder()`,
which issues its **own** `GetData` into a **private** `system.CombinedData`, supporting **both
transports**:
- **WebSocket**: `transport.NewWebSocketTransport(sys.WsConn).Request(...)`. The WS connection
  multiplexes concurrent in-flight requests by id (`internal/hub/ws/request_manager.go`:
  `nextID atomic.Uint32` + mutexed pending map), so this is race-free.
- **SSH**: opens a session on the existing `sys.client` via `createSessionWithTimeout` and decodes the
  `GetData` response into the private buffer. It stays **passive** — never dials or closes the shared SSH
  connection (so it can't disrupt the updater). SSH multiplexes channels, and API handlers already open
  concurrent sessions on `sys.client`, so this matches the codebase's existing pattern.

Agent `CacheTimeMs` means an overlapping recorder+realtime fetch just shares the cached snapshot — no
extra agent load. **Note:** this WS-or-SSH support is why the feature works regardless of how agents
connect to the hub (early mp.9 was WS-only and silently recorded nothing for SSH-connected fleets).

#### What's captured (per-proxy rows, ALL types — status/sessions/traffic/response)
- `haproxy_proxies` (one row per FRONTEND/BACKEND/SERVER per sample): `status`, sessions
  (`scur`/`smax`/`stot`), traffic (`bin`/`bout` + `*_rate`), HTTP responses (`hrsp_1xx..5xx` + rates),
  `rtime` (avg response time ms), health-check fails, `act_srv`/`bck_srv`. PK `(system, ts, proxy, type)`.
- `haproxy_info` (per-host process info): version, conn/sess rates, curr/cum conns, `idle_pct`,
  `run_queue`, tasks, pool MB, SSL. PK `(system, ts)`.
- **Slow-backend caveat:** the agent currently parses only `rtime` (col 60). HAProxy also exposes
  `qtime`/`ctime`/`ttime` (cols 58/59/61) per backend/server — adding those (agent-side change) gives the
  full queue/connect/response/total latency breakdown for pinpointing *which* backend is slow.

#### Config (hub env — opt-in, unset ⇒ disabled, zero overhead)
- `HAPROXY_DUCK_SPOOL` — spool dir; **enables** the recorder. `HAPROXY_RECORD_INTERVAL` (default `2s`).
  `HAPROXY_PROBE_INTERVAL` (default `60s`, rescan for new HAProxy hosts).
- `HAPROXY_RECORD_TYPES` — comma list of row types to record, default **`FRONTEND,BACKEND`**. **SERVER rows
  are excluded by default** because they're the volume bomb: HAProxy emits one row *per backend server per
  sample*, so a fleet with many servers can write multiple GB/hour. Set `FRONTEND,BACKEND,SERVER` only if
  you need per-server drill-down. The two volume knobs that matter: this type filter and `HAPROXY_RECORD_INTERVAL`.
- `HAPROXY_SPOOL_ROTATE` (default `60s`) — how often the hub **seals** the live spool file (see spool model).

#### Spool model (gap-free consume-and-delete, mp.13+)
The hub writes a single `<prefix>.live.ndjson` and every `HAPROXY_SPOOL_ROTATE` **seals** it: flush, close,
atomically rename to a complete `<prefix>-<UTCstamp>-<seq>.ndjson`. The hub NEVER writes a sealed file again.
The loader ingests **sealed files only** (the live file is excluded by the `-*` glob) and **deletes them after
a successful DB write** — gap-free, because no row is ever appended to a file the loader is consuming. At any
moment the only un-ingested data is the live file (≤ one rotate interval). This replaced the earlier
daily-rotation + dedup-archive model, which let a single day's file grow unbounded and hoarded raw NDJSON.

#### File Structure
- `internal/hub/systems/haproxy_recorder.go` — recorder loop, private-buffer fetch, seal-by-age spool writer
- `internal/hub/systems/system_manager.go` — `go sm.startHAProxyRecorder()` in `Initialize()` (self-gates on env)
- `scripts/duck-haproxy-ingest.sh` — ingest **sealed** spool files → dedicated `haproxy.duckdb`, then delete them (ON CONFLICT DO NOTHING for crash-safety); optional `HAPROXY_RETENTION_DAYS` DB row retention
- `scripts/duck-haproxy-report.sh` — troubleshooting report (per-frontend req/5xx/sessions, slowest backends by `rtime`, backend flaps, per-host idle%/conn-rate); reuses `duck-report.sh`'s local-time `[HOURS]` / `'FROM' 'TO'` range mode
- `scripts/docker/` — `beszel-duck` image + services in a profiled `docker-compose.yml`
  (profiles: `capacity` = duck-ingest; `haproxy` = haproxy-duck; `ui` = duck-ui + ui-proxy).
  Entrypoints in `docker/entrypoints/` (`capacity.sh`, `haproxy.sh`; image keeps back-compat symlinks to the
  old `*-entrypoint.sh` names). `docker/config/nginx-ui.conf` is the proxy config.
- `entrypoints/haproxy.sh` (`haproxy-duck` service) — loader loop (no hub creds; runs as root to read the hub's
  root-owned spool + delete sealed files). Also **exports a rolling Parquet window** (`HAPROXY_PARQUET_DIR`,
  last `HAPROXY_PARQUET_DAYS` days, every `HAPROXY_EXPORT_EVERY` cycles) for the web UI.
- **Web UI = Duck-UI (browser DuckDB-WASM), not the official DuckDB UI.** The official UI was a dead end here:
  the image's DuckDB 1.5.3 **musl** CLI has **no `ui`/`httpserver` extensions published** (404), and the UI needs
  runtime egress to ui.duckdb.org — but the prod container is **air-gapped**. Duck-UI is self-contained/offline,
  binds 0.0.0.0, fits behind nginx. Because it runs DuckDB-WASM *in the browser* it can't open the live
  v1.5.3 `.duckdb` (storage-format + size), so the loader exports **version-stable Parquet** that Duck-UI reads
  over HTTP via `read_parquet()` (range requests + predicate pushdown). `duck-ui` + `ui-proxy` (nginx basic-auth,
  serves Duck-UI at `/` and the Parquet at `/data/`) are the `ui` profile; front with TLS.

#### Data Flow
1. Hub recorder ticks every `HAPROXY_RECORD_INTERVAL`; probes all systems every `HAPROXY_PROBE_INTERVAL` to maintain the HAProxy-host membership set
2. Per tick: bounded-concurrency private-buffer `GetData` per HAProxy host; appends NDJSON rows to the live spool file, sealed every `HAPROXY_SPOOL_ROTATE`
3. `duck-haproxy-ingest.sh` (timer, ~5min) ingests sealed files into `haproxy.duckdb` then deletes them; optional `HAPROXY_RETENTION_DAYS` prunes the DB
4. `duck-haproxy-report.sh` / ad-hoc SQL reads the dedicated DB (traffic queries FRONTEND-only; backend `rtime` answers which-backend-is-slow)

**Deploy note:** hub-only change (agents unchanged). The spool dir must be reachable by the loader —
share a volume between the hub container and the duckdb container, or run the loader on the hub host.

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
| `v0.18.7-mp.5` | Initial Vector aggregator monitoring (broken — agent used GraphQL but Vector's API is gRPC); UI/hub/types are sound and reused by mp.6 |
| `v0.18.7-mp.6` | Vector collector rewritten on grpc-go using Vector's `observability.proto`. Env var rename `VECTOR_API_URL` → `VECTOR_API_ADDR` (URL form still accepted for back-compat) |
| `v0.18.7-mp.7` | Client-only fix for `/vector` rate display flapping to 0: skip rate recomputation when polled counters are unchanged from prev sample. 60s polling commit was tried and reverted (5s polling kept). No data-path or hub-endpoint changes. (Second mp.7 attempt — first one that added a hub `Created` field broke Vector display and was reverted.) |
| `v0.18.7-mp.8` | `/vector` aggregate page now drives live updates from the `rt_metrics` realtime subscription (reuses `system_realtime.go`'s 1s-tick worker — same machinery the `/system/<id>` page uses). HTTP polling retained at 60s as initial-discovery + safety-net fallback. Hub-only deploy; agent unchanged. Set `VECTOR_UPDATE_INTERVAL=1s` on the agent for true sub-second freshness (default 5s cache otherwise). |
| `v0.18.7-mp.9` | High-resolution HAProxy recording: hub-side always-on collector (`internal/hub/systems/haproxy_recorder.go`, opt-in via `HAPROXY_DUCK_SPOOL`) samples HAProxy from every reporting agent into a daily NDJSON spool; `scripts/duck-haproxy-ingest.sh` loads it into a dedicated `haproxy.duckdb`; `scripts/duck-haproxy-report.sh` reports (incl. "slowest backends/servers" by `rtime`). Pure-Go, no cgo. **Hub-only deploy; agent unchanged.** Disabled by default. See "High-Resolution HAProxy Recording" section. (`qtime`/`ctime`/`ttime` full-latency breakdown deferred — needs an agent change.) **Bug: WS-only — recorded nothing for SSH-connected agents; fixed in mp.10.** |
| `v0.18.7-mp.10` | HAProxy recorder now fetches over **SSH as well as WebSocket** (`sys.fetchForRecorder` adds a passive SSH path on the existing `sys.client`). mp.9 only handled WS, so fleets where agents connect to the hub via SSH (the common case here) got an empty spool. Hub-only; agent unchanged. |
| `v0.18.7-mp.11` | HAProxy recorder **stderr diagnostics** (visible in `docker logs`, since PB app logs go to the DB Logs table): `[haproxy-recorder] enabled ...` on start, a per-probe summary (`systems/eligible/ok/failed/haproxy_members/rows` + a sample error), and a sample-sweep line only on stalls/failures. Added to debug an empty spool. No behavior change. |
| `v0.18.7-mp.12` | **Volume control: `HAPROXY_RECORD_TYPES` (default `FRONTEND,BACKEND`).** mp.10/11 recorded SERVER rows too — on a fleet with many backend servers that produced multi-GB/hour spool (a real 3.4 GB file in minutes). SERVER rows now excluded by default; opt back in with `FRONTEND,BACKEND,SERVER`. Backend-level `rtime` still answers "which backend is slow." Hub-only. |
| `v0.18.7-mp.13` | **Gap-free consume-and-delete spool.** Hub now writes a single `<prefix>.live.ndjson` and seals it every `HAPROXY_SPOOL_ROTATE` (default 60s) into `<prefix>-<stamp>-<seq>.ndjson`; the loader ingests sealed files then **deletes** them, so the spool no longer grows all day or hoards archived NDJSON. The previous daily-rotation + dedup-archive model is gone. Loader/image (`duck-haproxy-ingest.sh`) updated to match. Hub + duck-image rebuild. |
| `v0.18.7-mp.14` | **Conntrack monitoring (new module).** Agent collects netfilter conntrack table stats from `/proc` (auto-enabled wherever `nf_conntrack` is loaded; no `CAP_NET_ADMIN`, no full-table scan) → `ConntrackStats` (CBOR key 100). Hub `conntrack_recorder.go` (opt-in `CONNTRACK_DUCK_SPOOL`, mirrors the HAProxy recorder) samples all hosts into a sealed NDJSON spool; `scripts/duck-conntrack-ingest.sh` loads it into a dedicated `conntrack.duckdb`; `scripts/duck-conntrack-report.sh` reports per-host table util% + drop deltas. New `conntrack` docker profile. **Agent + hub + duck-image rebuild** (agent change is additive — new files + one Stats field). Branch `feature/conntrack-recorder`. |
| `v0.18.7-mp.15` | **Conntrack live charts on `/system/<id>`.** Two realtime time-series cards (Conntrack Utilization = 100×conns/max, Conntrack Connections) in the core grid, gated on `stats.ct` presence (`internal/site/src/components/charts/conntrack-chart.tsx` + `types.d.ts` `ConntrackStats` + `system.tsx` wiring). Fed by the same realtime stream as CPU/mem (no new hub data path — `ct` already rides the stats broadcast from mp.14). **Hub/UI-only rebuild; agent unchanged (no redeploy).** |
| `v0.18.7-mp.16` | **Conntrack chart polish.** Fixed grey fill (the `hsl(var(--chart-1))` double-wrap → invalid CSS; now explicit amber `hsl(35 92% 50%)` via the `CONNTRACK_COLOR` const). Utilization card pinned to a fixed **0–100%** Y-axis so fill level reads absolutely; Connections stays auto-scaled. Hub/UI-only; agent unchanged. |

## Vector Aggregator Monitoring

### Architecture Decisions

#### Data source: Vector's gRPC observability API
Vector ships a gRPC service (`vector.observability.v1.ObservabilityService`) defined in `proto/vector/observability.proto`. The agent issues two unary RPCs per poll: `GetMeta` (version + hostname) and `GetComponents` (per-component metrics with `received_bytes_total`, `received_events_total`, `sent_bytes_total`, `sent_events_total`). Vector's `vector top` CLI uses the same service via `StreamComponentMetrics`.

A trimmed copy of the proto lives in `agent/vectorpb/observability.proto` (drops the event-tapping RPC so we don't have to vendor Vector's full event proto chain). Generated Go bindings (`observability.pb.go`, `observability_grpc.pb.go`) are committed.

Vector exposes **cumulative counters only via GetComponents**. The agent ships them as-is and the UI derives per-second rates client-side from successive samples (parallels HAProxy, in contrast to LVS where the kernel estimator provides rates directly).

**Important gotcha:** the proto's `ComponentMetrics` does NOT include `errors_total` or `discarded_events_total` — those are only available via the streaming `StreamComponentMetrics` RPC (`MetricName.METRIC_NAME_ERRORS_TOTAL`). The agent leaves those fields zero rather than open a long-lived stream just for the count. If error visibility becomes the operator's primary question, add a side-stream goroutine.

#### Earlier wrong turn (mp.5)
The first cut shipped as `v0.18.7-mp.5` was built against a Vector GraphQL API that doesn't exist in current Vector. Older Vector versions did serve GraphQL on the `[api]` port but the project removed it — current `src/api/` in vectordotdev/vector has only `grpc/`, `grpc_server.rs`, `mod.rs`. Symptom on the agent was `DEBUG Vector err="vector decode: EOF"`; manual `curl -v` on the endpoint returned `content-type: application/grpc grpc-status: 12 UNIMPLEMENTED`. mp.6 swaps the agent's HTTP+JSON client for grpc-go with generated protobuf bindings.

#### Opt-in via env var (different from LVS)
Unlike LVS (auto-enables on any host with the `ip_vs` module), Vector is **opt-in via `VECTOR_API_ADDR`** on the agent. Justification: Vector's API has to be explicitly enabled in `vector.toml` (`api.enabled = true`) and bound to a port — there's no kernel-level discovery hook. When unset, `NewVectorManager` returns `(nil, errVectorDisabled)` and the agent skips Vector collection.

`VECTOR_API_ADDR` is a gRPC dial target (host:port), **not a URL**. The collector tolerates URL-shaped inputs to ease the upgrade path from mp.5:
- `127.0.0.1:8687` (canonical)
- `vector-host:8687`
- `http://127.0.0.1:8687` → scheme stripped
- `http://127.0.0.1:8687/graphql` → scheme + path stripped (so an mp.5 conf keeps working with a warning)

For ease of migration, `VECTOR_API_URL` is also accepted as a legacy alias and logged at WARN.

#### Port collision rule
Vector's `[api]` block AND the `vector` *source* (Vector-to-Vector pipeline ingest) are **both gRPC services**. They cannot share a port. The default API bind is `127.0.0.1:8686` and the `vector` source typically also wants `:8686`. If both are configured, the source wins the bind and the API silently fails to start. Symptom: `curl -v -X POST host:8686/anything` returns `content-type: application/grpc grpc-status: 12` (which is the source's gRPC handler rejecting an unknown service).

**Fix:** give the API its own port:
```toml
[api]
enabled = true
address = "127.0.0.1:8687"   # NOT 8686 if a `vector` source is configured
```

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
- `agent/vector.go` — `VectorManager`, gRPC client (grpc-go + insecure creds), addr normalization, polling state
- `agent/vectorpb/observability.proto` — trimmed copy of Vector's proto (event tapping dropped)
- `agent/vectorpb/observability.pb.go` + `observability_grpc.pb.go` — generated bindings (committed)
- `internal/entities/system/system.go` — `VectorStats`, `VectorComponent` types (CBOR keys 80+)
- `internal/hub/api.go` — `getVectorStats` handler at `/api/beszel/vector/stats`
- `internal/site/src/lib/vector-aggregate.ts` — visibility filter, group totals, rate derivation, formatters, host status
- `internal/site/src/components/routes/vector-aggregate.tsx` — `/vector` aggregate route
- `internal/site/src/components/charts/vector-panel.tsx` — per-system Vector panel (mounted from `/system/<id>` when `vec` is present)

### Data Flow
1. Agent's `VectorManager.fetch()` issues `GetMeta` + `GetComponents` gRPC calls against `VECTOR_API_ADDR`
2. Build per-component entries from the response; sum per-kind totals (sources / transforms / sinks)
3. Aggregate to `data.Stats.Vector` in agent `gatherStats`; ship via existing system_stats pipeline
4. UI polls `/api/beszel/vector/stats?ids=...` every 5s on the aggregate page; derives rates client-side from successive cumulative-counter samples
5. Per-system panel reads `systemStats.at(-1)?.stats?.vec` (no separate poll — same data cadence as the rest of the system page)

### Regenerating proto bindings
After editing `agent/vectorpb/observability.proto` (e.g. to track upstream proto changes), regenerate with:
```bash
cd agent/vectorpb
PATH=$HOME/go/bin:$PATH protoc \
  --go_out=. --go-grpc_out=. \
  --go_opt=paths=source_relative --go-grpc_opt=paths=source_relative \
  observability.proto
```
Requires `protoc` plus `protoc-gen-go` and `protoc-gen-go-grpc` in `$PATH` (install with `go install google.golang.org/protobuf/cmd/protoc-gen-go@latest` and `go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest`).

### UI status states (per-host badge on `/vector`)
Computed in `deriveHostStatus(systemStatus, vec)`:
- **healthy** (green) — agent reporting Vector data and `health: true`
- **unhealthy** (red) — agent reporting Vector data and `health: false`
- **no-data** (orange) — system status is `up` but no `vec` field. Hover tooltip explains likely causes (`VECTOR_API_URL` unset, Vector GraphQL endpoint unreachable, agent older than the build that introduced Vector support)
- **down** (gray) — host isn't reporting at all

### Configuration
- `VECTOR_API_ADDR=127.0.0.1:8687` — gRPC dial target, enables collection (required)
- `VECTOR_API_URL` — accepted as legacy alias from mp.5 (logged at WARN, URL-shaped inputs are normalized to host:port)
- `VECTOR_UPDATE_INTERVAL=5s` — override agent collection period (default 5s)
- Vector side: `api.enabled = true` and `api.address = "127.0.0.1:8687"` in `vector.toml` (use a different port than any configured `vector` source — see "Port collision rule" above)

### Troubleshooting
Enable debug logging temporarily and inspect the Vector init line:
```bash
echo 'LOG_LEVEL=debug' | sudo tee -a /etc/beszel-agent.conf
echo 'VECTOR_API_ADDR=127.0.0.1:8687' | sudo tee -a /etc/beszel-agent.conf
sudo systemctl restart beszel-agent
sleep 3
sudo journalctl -u beszel-agent -n 50 --no-pager | grep -iE 'vector'
```

Expected outcomes:
| Log line | Meaning | Fix |
|---|---|---|
| `INFO Vector monitoring enabled addr=...` | Working | — |
| `DEBUG Vector err="VECTOR_API_ADDR not set"` | env var missing | Set `VECTOR_API_ADDR` |
| `DEBUG Vector err="vector GetMeta: ... connection refused"` | Vector API not listening on that port | Check `[api] enabled = true` and `address` in `vector.toml`; verify with `ss -ltnp \| grep <port>` |
| `DEBUG Vector err="vector GetMeta: ... Unimplemented"` | Hit the wrong gRPC service (likely a `vector` source on that port) | Move the API to a different port from the `vector` source |
| `DEBUG Vector err="vector GetMeta: ... deadline exceeded"` | API reachable but slow | Bump `vectorRequestTimeout` or investigate Vector load |
| `WARN VECTOR_API_URL is deprecated, use VECTOR_API_ADDR (host:port)` | Operator still on mp.5-era conf | Rename env var (the agent still works via the alias) |

Manual gRPC probe from the Vector host (requires `grpcurl`):
```bash
grpcurl -plaintext 127.0.0.1:8687 vector.observability.v1.ObservabilityService/GetMeta
# expect: {"version":"0.xx.x","hostname":"..."}
```

Hub-side check that the data is reaching the hub:
```bash
curl -s "https://hub.example/api/beszel/vector/stats?ids=<system_id>" -H "Authorization: $TOKEN" | jq
# expect: [{"system":"<id>","vector":{"hl":true,"v":"0.43.0",...}}]
# empty []  → agent isn't shipping the field (check agent-side log table above)
# 404       → hub binary doesn't have the endpoint (upgrade hub)
```
