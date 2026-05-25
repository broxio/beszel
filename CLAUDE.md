# Project Notes

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

## Note on merging with HAProxy branch

This branch's `CLAUDE.md` only contains the LVS section. When merging into the
`production` branch (which by then includes the HAProxy branch's `CLAUDE.md`),
expect a small textual conflict — resolve by keeping both sections.
