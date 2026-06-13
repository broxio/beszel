# beszel reporting scripts

Off-the-shelf snapshot/reporting tools that read beszel's PocketBase data — either
directly from SQLite (on the hub host) or through the REST API (from anywhere).
They exist because the web UI is good for *live* viewing but not for pulling a
single capacity/usage report or building history that outlives PB's retention.

## The scripts

| Script | Transport | Purpose |
|---|---|---|
| `stats.sh` | SQLite (on hub) | avg/max CPU, mem%, net + HAProxy/IPVS peak rates, per host / group / total |
| `stats-api.sh` | REST API (off-host) | same report as `stats.sh`, over HTTP |
| `capacity.sh` | SQLite (on hub) | **capacity planning**: vCPU vs real-core usage, CPU%/mem percentiles |
| `capacity-api.sh` | REST API (off-host) | same as `capacity.sh`, over HTTP |
| `peak-recorder.sh` | REST API (off-host) | harvest **minute-precise** CPU/mem peaks before PB prunes them; append-only CSV |
| `duck-ingest.sh` | REST API (off-host) | siphon raw **1m** samples into a local **DuckDB** before PB prunes them; idempotent, runs on a timer |
| `duck-report-capacity.sh` | DuckDB (local file) | capacity report from the DuckDB store: true percentiles + **exact** peak time + fleet totals |
| `duck-report-basics.sh` | DuckDB (local file) | generic **per-host basics for EVERY host**: CPU/load/mem/disk/disk-IO/net + conntrack-if-present, auto-grouped by name; `VIEW=host\|group`, `FORMAT=box\|csv\|json` |
| `duck-usage.sh` | DuckDB (local files) | **how many rows + how big** per store over a window (`[HOURS]`, default 24): DB on-disk size, total rows, per-table rows/hosts/span + zstd-Parquet footprint of the window |
| `duck-report-summary.sh` | DuckDB (local file) | capacity rolled up **per host-group** (+ optional `fe_*` request/throughput from the HAProxy DB); `usage` or cloud-`forecast` views |
| `duck-haproxy-ingest.sh` | NDJSON spool (from hub) | load the hub's **high-resolution HAProxy** spool into a dedicated DuckDB; idempotent, runs on a timer |
| `duck-report-haproxy.sh` | DuckDB (local file) | HAProxy troubleshooting report: per-frontend req/5xx/sessions, backend flaps, per-host idle%/conn-rate |

`stats*` and `capacity*` are read-only one-shot reports straight off PB. `peak-recorder.sh`
and `duck-ingest.sh` run on a timer to build long-term stores that outlive PB retention.

> **DuckDB supersedes `peak-recorder.sh`.** Once raw 1m is in DuckDB, exact peak time is
> just `arg_max(ts, cpu)` and percentiles are `quantile_cont(...)` — no awk, no peak-state
> CSV. Keep `peak-recorder.sh` only if you want a tiny no-DuckDB footprint. Prefer the
> DuckDB pipeline if you'll do any real analysis.

## Quick usage

```bash
# avg/max overview
BESZEL_DB=/srv/beszel/pb_data/data.db ./stats.sh 6 'ha-*'
BESZEL_URL=https://hub BESZEL_TOKEN=xxx ./stats-api.sh 6 'ha-*'

# capacity planning (percentiles + real cores/RAM)
./capacity.sh 12 'ha-bop*' --peak-time
BESZEL_URL=https://hub BESZEL_TOKEN=xxx ./capacity-api.sh 12 'ha-bop*' --peak-time

# CSV for long-term history (append, headerless)
./capacity-api.sh 24 '*' --csv --no-header >> capacity-history.csv

# minute-precise peak recording (run on cron, see peak-recorder.sh header)
BESZEL_URL=https://hub BESZEL_TOKEN=xxx PEAKS_FILE=/var/lib/beszel/peaks.csv ./peak-recorder.sh '*'
```

### Credentials & token caching (for ad-hoc / troubleshooting)

The `*-api.sh` scripts share `lib/beszel-auth.sh`, which resolves credentials and **caches the
auth token** so repeated interactive queries don't each re-login:

1. **Config file** — drop creds in `~/.config/beszel/env` (or point `BESZEL_ENV_FILE` at one)
   and you can run any `-api` script with no env juggling. Template: `beszel.env.example`.
   ```bash
   mkdir -p ~/.config/beszel && cp beszel.env.example ~/.config/beszel/env
   chmod 600 ~/.config/beszel/env       # set BESZEL_URL/EMAIL/PASSWORD (dedicated query account)
   ./capacity-api.sh 1 'ha-bop*' --peak-time   # just works, no exports
   ```
2. **Token cache** — first call logs in (a beszel `users` token lasts ~7 days); the token is
   cached under `~/.cache/beszel` (mode 0600) and reused until ~5 min before expiry. So a flurry
   of troubleshooting queries pays one login, not one per call. Disable with `BESZEL_NO_CACHE=1`.
3. **Precedence**: an explicit `BESZEL_TOKEN` env wins (no cache); else env vars; else the config
   file. `BESZEL_AUTH_COLLECTION` defaults to `users` (set `_superusers` for an admin account).

Realtime-troubleshooting tip: small windows give the freshest view, e.g.
`BUCKET=1m ./capacity-api.sh 1 'ha-bop*' --peak-time` (last hour, minute resolution) or
`./stats-api.sh 1 'ha-*'`. (`duck-ingest.sh` keeps its own inline auth — it's the container
ingester, not an interactive tool.)

### DuckDB pipeline (precise, long-term, analytical)

Architecture: **beszel keeps 1m for 1h (operational) → `duck-ingest.sh` siphons 1m into
DuckDB before the purge (analytical, kept forever) → reports become SQL.** Storing raw
samples means avg/P95/P99/peak **and the exact minute of each peak** are all derivable;
beszel's own rollups keep only the peak *value*, not its time (see Findings #3).

```bash
# 1. ingest on a timer MORE OFTEN than the 1h 1m-retention (every ~15 min)
*/15 * * * * BESZEL_URL=https://hub BESZEL_TOKEN=xxx DUCK_DB=/var/lib/beszel/beszel.duckdb \
             /path/duck-ingest.sh '*' >> /var/log/beszel-duck.log 2>&1

# 2. report any time (TZ_OFFSET controls peak-time display, default UTC+8)
DUCK_DB=/var/lib/beszel/beszel.duckdb ./duck-report-capacity.sh 168 'ha-bop*'   # last 7 days

# 3. or just write SQL — native percentiles, arg_max, time-bucketing
duckdb $DUCK_DB "SELECT host, quantile_cont(cpu,0.95) p95, arg_max(ts,cpu) peak_at
                 FROM metrics WHERE ts >= now() - INTERVAL 28 days GROUP BY host"
```

Schema (`metrics`, PK `(host, ts)`): `ts`(UTC), `host`, `vcpu`, `cpu`, `steal`,
`mem_used_gb`, `mem_total_gb`, `mem_pct`, `swap_gb`, `net_out_bps`, `net_in_bps`,
`disk_pct`, `disk_used_gb`, `disk_total_gb`, `disk_read_bps`, `disk_write_bps`,
`io_util`, `load1`, `load5`, `load15`. (The disk/IO/load columns are added by
`ALTER ... ADD COLUMN IF NOT EXISTS`, so an existing DB widens in place; rows
ingested before the change are NULL for them.) Requires the `duckdb` CLI on the
ingest/report host.

#### Generic per-host basics + machine-readable (JSON) output

`duck-report-basics.sh` is the all-hosts report (not just `ha-*`): CPU, load avg,
memory, disk usage, disk IO (throughput + `io_util%`), network bandwidth, and — if a
conntrack store sits next to the capacity DB — conntrack table util (NULL for hosts
without `nf_conntrack`). Hosts auto-group by name (`ha-bop-1`,`-2` → `ha-bop`).

```bash
DUCK_DB=/var/lib/beszel/beszel.duckdb ./duck-report-basics.sh 24 '*'      # per-host, last 24h
VIEW=group ./duck-report-basics.sh 168 'ha-*'                             # per-group rollup, 7d
FORMAT=json ./duck-report-basics.sh 24 '*' | jq .                        # array of host objects (webservice/AI)
```

All report scripts accept `FORMAT=box|csv|json`. `json` emits DuckDB's native array
of objects keyed by the column aliases — feed it straight to an HTTP endpoint / agent.
(Multi-section reports — summary/cross/haproxy — emit one JSON array *per section*.)

#### Retention & cold-tier archive (bounding the store)

`duck-ingest.sh` keeps everything forever unless `RETENTION_DAYS` is set. When set, it
ages rows out of the hot DuckDB by **whole UTC day** after each ingest. With
`ARCHIVE_DIR` also set, each expiring day is first written to
`<ARCHIVE_DIR>/metrics-YYYY-MM-DD.parquet` (zstd) and only then deleted — a queryable
cold tier:

```bash
RETENTION_DAYS=45 ARCHIVE_DIR=/var/lib/beszel/archive ./duck-ingest.sh '*'
# cold reads:
duckdb $DUCK_DB "SELECT * FROM read_parquet('/var/lib/beszel/archive/metrics-*.parquet') WHERE host='ha-bop-1'"
```

The compose `duck-ingest` service defaults `RETENTION_DAYS=45` + `ARCHIVE_DIR=/data/archive`.
Rough sizing (1-min resolution, ~175 hosts): **~10–35 MB/day** into the hot DB, so a
45-day hot window settles around **~0.5–1.6 GB** (it plateaus once daily archive ≈ daily
ingest). The zstd Parquet archive is materially smaller per day than the live store.
Measure your real rate with:
`duckdb -readonly $DUCK_DB "SELECT count(*) r, count(DISTINCT host) h, min(ts), max(ts) FROM metrics"`.

**All three stores share the same rotation** via the `duck_archive_prune` helper in
`duck-lib.sh` (sourced by every ingest). Same whole-day, archive-then-delete, idempotent
behavior; each store has its own knobs (defaults in compose):

| Store | Retention | Archive dir | Archive files |
|---|---|---|---|
| capacity (`beszel.duckdb`) | `RETENTION_DAYS=45` | `ARCHIVE_DIR=/data/archive` | `metrics-YYYY-MM-DD.parquet` |
| haproxy (`haproxy.duckdb`) | `HAPROXY_RETENTION_DAYS=14` | `HAPROXY_ARCHIVE_DIR=/data/archive` | `haproxy_proxies-*`, `haproxy_info-*` |
| conntrack (`conntrack.duckdb`) | `CONNTRACK_RETENTION_DAYS=14` | `CONNTRACK_ARCHIVE_DIR=/data/archive` | `conntrack-YYYY-MM-DD.parquet` |

Set an `*_ARCHIVE_DIR` to `""` to hard-delete that store instead of archiving.
**Watch `haproxy_proxies`** — it's high-volume, so its daily Parquet can be large; disable
its archive (`HAPROXY_ARCHIVE_DIR=""`) if you don't need the cold tier. The archive itself
is keep-forever unless you set `*_ARCHIVE_RETENTION_DAYS` (sweeps `<table>-*.parquet` older
than N days, keyed on the date in the filename).

### Report API (`duck-api`) — JSON over HTTP for an AI agent

`duck-api` is a tiny read-only HTTP wrapper (a static Go binary baked into the
`beszel-duck` image) that exposes the reports as JSON. It runs a **fixed, allowlisted**
set of GET endpoints with **strictly validated params** — it never exposes DuckDB SQL
(no `read_parquet`/`COPY`/`ATTACH` reachable by the caller). Brought up on the `api`
profile, fronted by the existing nginx `ui-proxy` at `/api/` (basic-auth + optional IP
allowlist + TLS):

```bash
docker compose --profile api up -d
curl -u user:pass 'https://<host>/api/v1/basics?hours=24&host=ha-*&view=group' | jq .
curl -u user:pass  'https://<host>/api/openapi.json'      # OpenAPI 3.0 spec (agent tool discovery)
```

| Endpoint | Report | Params |
|---|---|---|
| `/v1/basics` | per-host basics | `hours`, `host`, `view=host\|group` |
| `/v1/capacity` | capacity percentiles + peak time | `hours`, `host` |
| `/v1/haproxy` | HAProxy troubleshooting | `hours`, `host` |
| `/v1/conntrack` | conntrack util + drops | `hours`, `host` |
| `/v1/summary` | per-group rollup | `hours`, `view=usage\|forecast` |
| `/v1/cross` | conntrack ↔ haproxy ↔ cpu | `hours`, `host` |
| `/healthz`, `/v1`, `/openapi.json` | health / index / spec | — |

Validation: `hours` = int `1..API_MAX_HOURS` (default cap 2160 = 90d); `host` =
`^[A-Za-z0-9_.*?-]{1,64}$` (glob, default `*`); `view` = per-endpoint enum. Anything else
→ `400`, nothing executed. Non-GET → `405`. Response envelope:

```json
{ "report":"basics", "params":{"hours":24,"host":"ha-*","view":"group"},
  "generated_at":"2026-06-06T...Z",
  "sections":[ [ {"host_group":"ha-bop","cpu_p95_avg":55.3, ...}, ... ] ] }
```

`sections` holds one array per report section (basics = 1; capacity/summary/cross have
several). Knobs (compose env): `API_MAX_HOURS`, `API_QUERY_TIMEOUT` (s), `API_MAX_CONCURRENCY`,
`API_EXCLUDE_HOST` (default empty = all hosts visible). **Lock down access** by uncommenting
the `allow <CIDR>; deny all;` block in `docker/config/nginx-ui.conf` under `location /api/`.

### High-resolution HAProxy recording (hub → DuckDB)

Different source from `duck-ingest.sh`. The capacity pipeline above pulls 1m **system**
stats over REST. For HAProxy troubleshooting we want sub-minute resolution that beszel never
persists (the per-second data on `/system/<id>` is broadcast live and discarded). So the
**hub itself** samples HAProxy from every agent reporting it and appends an NDJSON spool;
this loader ingests the spool into a *dedicated* DuckDB.

**1. Enable recording on the hub** (opt-in via env — unset ⇒ feature off, zero overhead):

```
HAPROXY_DUCK_SPOOL=/data/haproxy-spool     # enables it; dir the hub writes spool files to
HAPROXY_RECORD_INTERVAL=5s                  # sample cadence; a volume knob
HAPROXY_PROBE_INTERVAL=60s                  # how often to rescan for new HAProxy hosts
HAPROXY_RECORD_TYPES=FRONTEND,BACKEND       # row types to record (default); add SERVER for per-server drill-down
                                            # SERVER is the volume bomb (1 row per backend server per sample) — off by default
HAPROXY_SPOOL_ROTATE=60s                    # how often the hub seals the live spool file for the loader to consume
```

The hub writes daily-rotated `haproxy_proxies-YYYYMMDD.ndjson` (one line per
frontend/backend/server per sample) and `haproxy_info-YYYYMMDD.ndjson` (per-host process
info). Pure-Go, append-only — no DB driver in the hub, so it never holds a DuckDB lock.

**2. Load + report** (the spool dir must be reachable by the loader — share a volume between
the hub and the duckdb container, or run the loader on the hub host):

```bash
# load on a timer (every ~5 min); idempotent via PK dedup, archives closed daily files
*/5 * * * * HAPROXY_DUCK_DB=/data/haproxy.duckdb HAPROXY_SPOOL_DIR=/data/haproxy-spool \
            HAPROXY_RETENTION_DAYS=30 /path/duck-haproxy-ingest.sh >> /var/log/haproxy-duck.log 2>&1

# troubleshoot (same relative [HOURS] / 'FROM' 'TO' local-time range mode as duck-report-capacity.sh)
HAPROXY_DUCK_DB=/data/haproxy.duckdb ./duck-report-haproxy.sh 1 'ha-*'
HAPROXY_DUCK_DB=/data/haproxy.duckdb ./duck-report-haproxy.sh '2026-06-01 10:00' '2026-06-01 10:30' 'ha-bop*'
```

Tables: `haproxy_proxies` PK `(system, ts, proxy, type)`, `haproxy_info` PK `(system, ts)`.
Traffic queries are **FRONTEND-only** (no double-count, per the project rule) but all proxy
types are stored so you can drill into backends/servers.

**Volume note:** at 2s, ~43.2k samples/day per series. e.g. 20 hosts × ~5 proxies ≈ 100
series ⇒ ~4.3M proxy rows/day. `HAPROXY_RECORD_INTERVAL=5s` cuts that 2.5×;
`HAPROXY_RETENTION_DAYS` bounds DB + spool growth.

### Containerised sidecars (`docker/`)

One `beszel-duck` image, **four services grouped by compose profile** so you run only
what you need. Entrypoints live in `docker/entrypoints/`; the proxy config in `docker/config/`.

| Profile | Services | Purpose |
|---|---|---|
| `capacity` | `duck-ingest` | loops `duck-ingest.sh` (needs hub URL + read-only creds); exports `metrics.parquet` for the UI |
| `haproxy` | `haproxy-duck` | HAProxy spool → DuckDB + rolling Parquet export (no hub creds) |
| `ui` | `duck-ui`, `ui-proxy` | Duck-UI (browser DuckDB-WASM) behind nginx basic-auth, querying the Parquet |

Both ingesters export Parquet into the shared `./parquet` dir, which `ui-proxy` serves at `/data/`. In Duck-UI:
`read_parquet('https://<host>/data/metrics.parquet')` (capacity) and `…/haproxy_proxies.parquet` (HAProxy).
Copy-paste Duck-UI queries (incl. ones that reproduce the CLI report's tables): **[DUCK-UI-QUERIES.md](DUCK-UI-QUERIES.md)**.

```bash
cd scripts/docker
cp .env.example .env        # fill BESZEL_URL + a DEDICATED read-only account (capacity only)

# capacity ingester:
docker compose --profile capacity up -d --build
docker compose logs -f duck-ingest                       # watch ingests
docker compose exec duck-ingest duck-report-capacity.sh 24 '*'    # report on demand

# HAProxy loader (set HAPROXY_SPOOL_HOST_DIR to the hub's spool dir):
docker compose --profile haproxy up -d
docker compose exec haproxy-duck duck-report-haproxy.sh 1 'ha-*'

# web UI: Duck-UI behind nginx basic-auth (create ui.htpasswd first, chmod 644):
docker run --rm -it httpd:alpine htpasswd -nB admin > ui.htpasswd && chmod 644 ui.htpasswd
docker compose --profile haproxy --profile ui up -d
# then browse the proxy (front with TLS); query in Duck-UI:
#   SELECT host,proxy,quantile_cont(rtime,0.95) FROM read_parquet('https://<host>/data/haproxy_proxies.parquet')
#   WHERE type='BACKEND' GROUP BY 1,2 ORDER BY 3 DESC;
```
The **official DuckDB UI doesn't fit** here: the musl DuckDB build has no `ui` extension and it needs runtime
egress to ui.duckdb.org (the prod box is air-gapped). **Duck-UI** is self-contained and runs DuckDB-WASM in the
browser, so the loader exports a rolling **Parquet** window it can read over HTTP.
**Note:** services are profile-gated, so a bare `docker compose up -d` (no `--profile`)
starts nothing — always pass the profile(s) you want, on `up`, `pull`, `logs`, and `down`.

- **Use email/password, not a token** — the container re-auths every run, so it never
  expires (a static token would die in ~7 days). A regular **`users`** account works
  (it can read all systems' stats); the `*-api`/`duck-ingest` scripts default to the
  `users` auth collection. Set `BESZEL_AUTH_COLLECTION=_superusers` only if the account
  is an admin. Validated on prod: 156 hosts / ~11k 1m-rows per run.
- **DuckDB file** lives in a **host bind mount** `./data/beszel.duckdb` (next to the compose
  file), so it's visible, back-up-able, and independent of the container lifecycle —
  `docker rm`/recreate never loses it (only deleting the folder does). The entrypoint starts
  as root solely to `chown /data` to the `duck` user, then drops via `su-exec` and runs all
  work unprivileged — so a plain bind mount "just works" with no manual `chown`.
  `duck-report` opens it `-readonly`.
  (Note: `docker exec …` lands as root by default; for reports that's harmless. For
  **cron-mode** ingest, run it as `duck` to keep `./data` files user-owned — see below.)
- **Reaching the hub:** if the container joins the hub's docker network, set
  `BESZEL_URL=http://<hub-service>:8090` (internal, no TLS hop); else use the public URL.
- **DuckDB on Alpine:** uses DuckDB's official **musl** CLI build
  (`duckdb_cli-linux-<arch>-musl.zip`) — native, no `gcompat`. A build-time
  `SELECT 'duckdb ok'` smoke-test confirms it runs on your arch. The `DUCKDB_VERSION`
  build ARG must point at a real release tag (assets are `amd64`/`arm64`, not `aarch64`).
  Build-tested on arm64 (alpine 3.20, DuckDB 1.5.3). A `debian:bookworm-slim` fallback is
  still noted at the bottom of the Dockerfile if you ever need glibc.
- **Resilient loop:** the entrypoint loops `duck-ingest.sh`, logs each run, and on failure
  (e.g. hub unreachable) logs it and retries next cycle instead of crashing. curl calls
  use `--connect-timeout 10 --max-time 120` so a network blip can't wedge the loop.

#### Scheduling: internal loop (default) vs host cron (opt-in)

The container schedules itself with an internal `while/sleep` loop — no cron needed. It's
self-contained and logs to `docker logs`. The only quirk: the period is `run + INTERVAL`
(~46 min for a ~1 min run, INTERVAL 2700s) and drifts slightly — fine here, since the 70-min
`LOOKBACK` overlap + dedup absorb it. Default `INGEST_MODE=loop`.

If you'd rather drive it from the **docker host crontab** (exact wall-clock, or you manage all
periodic jobs centrally), set `INGEST_MODE=cron`. The container then just idles, and you
trigger runs by `exec`-ing into it:

```bash
# .env:  INGEST_MODE=cron   then: docker compose up -d
# host crontab (every 45 min, on the clock). Run as 'duck' so files in ./data stay user-owned:
*/45 * * * * docker exec beszel-duck-ingest su-exec duck duck-ingest.sh '*' >> /var/log/beszel-duck.log 2>&1
```

Use one or the other, not both (the cron-mode container does not self-ingest). Either way the
DuckDB file is the same volume, and `duck-report-capacity.sh` works unchanged.

#### Polling cadence (freshness vs load)

`INGEST_INTERVAL` (seconds between runs) and `LOOKBACK_MIN` (minutes fetched per run) trade
data freshness against load. Rule: **`LOOKBACK_MIN ≥ (INGEST_INTERVAL/60) + margin`** and
**`INGEST_INTERVAL` comfortably under the 1m retention (3600s)**. The overlap is re-fetched
and deduped by `PK (host, ts)`, so margin is free insurance against agent jitter / late rows.

| Profile | INTERVAL | LOOKBACK_MIN | Freshness | Per-run (≈156 hosts) |
|---|---|---|---|---|
| Conservative (default) | 2700 (45m) | 70 | ~45 min | ~11k rows, ~22–29 pages, ~100s |
| **Semi-real-time** | **300 (5m)** | **15** | **~5–6 min** | **~2.3k rows, ~5 pages, ~15s** |

Key facts that make the fast profile safe and cheap:
- **Smaller *runs*, not smaller *calls*.** Each paginated GET is still capped at `perPage=500`;
  the 15-min window just needs ~⅕ the pages (~5 vs ~29) and ~⅕ the data per run. Gentler
  per-event bursts; ~2× total fetch/hour (12 small runs vs ~1.3 big ones) — trivial for the hub.
- **DuckDB size is unaffected by cadence** — dedup keeps only real minutes, not re-fetches.
- **Granularity floor stays 1 minute** (per-minute averages); 5-min polling *refreshes* faster,
  it does not add sub-minute detail (that would need the agent realtime path).
- Loop drift (~run_duration + INTERVAL) is negligible vs the 10-min margin at 5/15.

To switch: set `INGEST_INTERVAL=300` + `LOOKBACK_MIN=15` in `.env`, `docker compose up -d`.
If you later run ≤2-min intervals or grow the fleet a lot, add a `max(ts)` watermark to the
ingester to cut the (then larger) redundant re-fetch.

See **[QUERIES.md](QUERIES.md)** for how to query the store.

#### Build & publish to a registry, deploy by pull

`build-and-push.sh` builds a **multi-arch** image (amd64 + arm64, native musl duckdb) and
pushes it, so the production host just pulls — no build toolchain or source on prod.

```bash
# on a build host (docker buildx + `docker login <registry>` done first):
REGISTRY=registry.example.com/you ./build-and-push.sh v1
#   -> pushes registry.example.com/you/beszel-duck:v1  and  :latest  (amd64+arm64)
# options: IMAGE=, TAG=, PLATFORMS=linux/amd64, PUSH=false (local --load test), DUCKDB_VERSION=

# on the production host (only needs docker-compose.yml + .env, no source):
#   in .env:  DUCK_IMAGE=registry.example.com/you/beszel-duck:v1   (+ BESZEL_* etc.)
docker compose pull && docker compose up -d
```

The compose `image:` is `${DUCK_IMAGE:-beszel-duck:latest}` — set `DUCK_IMAGE` to the
registry tag on prod (the local `build:` section is then ignored because the pulled image is
already present). If you copy *only* `docker-compose.yml` + `.env` to prod (no `scripts/`
build context), that's fine for the pull flow; just don't pass `--build` there.
Validated: multi-arch build produces a working amd64 image (the build runs the duckdb smoke
test per-arch, so a broken arch fails the build, not prod).

### Running the reports (in the duck container)

Three read-only report scripts ship in the image. The `*-ingest.sh` scripts are loaders
(driven by the entrypoints/timers), not reports. Two DBs back the reports:

- **Capacity** (`metrics`: CPU/mem) → `/data/beszel.duckdb` — the `duck-ingest` service
- **HAProxy** (`haproxy_proxies`/`haproxy_info`) → `/data/haproxy.duckdb` — the `haproxy-duck` service

Run each from the service that owns its DB (or either if your `./data` volume is shared — just
point the env at the right file). Both invocation forms match across all three:
`<HOURS>` (relative) or `'FROM' 'TO'` (explicit **local** range).

```bash
# 1) Capacity per-host + fleet total
docker compose exec duck-ingest duck-report-capacity.sh 6 'ha-bop*'
docker compose exec duck-ingest duck-report-capacity.sh '2026-06-02 13:00' '2026-06-02 19:00' 'ha-*'

# 2) Capacity by host-GROUP (+ fe_* requests/throughput if the HAProxy DB is present)
docker compose exec duck-ingest duck-report-summary.sh 6
docker compose exec -e HAPROXY_DUCK_DB=/data/haproxy.duckdb duck-ingest duck-report-summary.sh 6
docker compose exec -e FORMAT=csv duck-ingest duck-report-summary.sh '2026-06-02' '2026-06-03'   # Excel

# 3) HAProxy troubleshooting (per-frontend, slowest backends, flaps, host health, fe_* by group)
docker compose exec haproxy-duck duck-report-haproxy.sh 6 'ha-*'
docker compose exec haproxy-duck duck-report-haproxy.sh '2026-06-02 13:00' '2026-06-02 19:00' 'ha-bop*'

# 4) Conntrack table pressure (per-host util% + drop deltas) — needs the conntrack profile
docker compose exec conntrack-duck duck-report-conntrack.sh 6 'lvs-*'

# 5) Cross-correlation: conntrack util <-> HAProxy 5xx <-> CPU steal, joined per-minute on (host,minute).
#    ATTACHes all three DuckDB stores read-only (conntrack required; haproxy/capacity optional). Run from
#    a container whose /data holds all three .duckdb files. UTIL_THRESHOLD (default 80) sets the "hot bucket" cutoff.
docker compose exec conntrack-duck duck-report-cross.sh 6 'lvs-*'
docker compose exec -e UTIL_THRESHOLD=70 conntrack-duck duck-report-cross.sh '2026-06-03 09:00' '2026-06-03 12:00' 'ha-bop*'
```

Knobs are **env vars — pass them with `-e` BEFORE the service name** (anything after the script
name is a positional arg, not an env var):

| Env | Default | Applies to |
|---|---|---|
| `EXCLUDE_HOST` | `ha-uat*,ha-pre*` | all three (comma globs, case-insensitive; `''` = include) |
| `EXCLUDE_PROXY` | `admin,stats` | `duck-report-haproxy.sh` (mgmt/stats frontends; `''` = include) |
| `TZ_OFFSET` | `8` (UTC+8) | all (peak times + range args) |
| `FORMAT` | `box` | **all reports** (`csv` for Excel/pipe; multi-table reports emit one CSV block per table) |
| `GROUP_MODE` | `sheet` | `duck-report-summary.sh` (`auto` = group every host by name) |
| `VIEW` | `usage` | `duck-report-summary.sh` (`forecast` = cloud right-sizing) |
| `SORT` | `name` | `duck-report-summary.sh` (`seq` = fixed spreadsheet order) |
| `HAPROXY_DUCK_DB` | `./haproxy.duckdb` | `duck-report-summary.sh` fe_* section |

```bash
# include the non-prod zones / mgmt frontends that are hidden by default:
docker compose exec -e EXCLUDE_HOST='' -e EXCLUDE_PROXY='' haproxy-duck duck-report-haproxy.sh 6 'ha-*'
# cloud capacity forecast over ~30 days, CSV, every host auto-grouped:
docker compose exec -e VIEW=forecast -e GROUP_MODE=auto -e FORMAT=csv duck-ingest duck-report-summary.sh 720
```

(Service names `duck-ingest`/`haproxy-duck` assume the bundled compose — adjust for yours.)

---

## Findings about beszel's data model (why the scripts are built the way they are)

### 1. `cores` is not a column — it's in `systems.info` JSON
The systems table has no `cores` field. vCPU count lives in `info.c` (cores), with
`info.t` (threads) as a fallback when `c` is omitted (`c` is `omitzero`). All scripts
resolve **vCPU = `info.c` else `info.t`**. (For a hyperthreaded VM, `t` is usually the
logical/vCPU count; `c` is physical cores.)

### 2. Stats are stored as JSON under `system_stats.stats`, keyed short
Relevant keys: `cpu` (CPU%), `cpum` (per-bucket max CPU%), `cpub[3]` (steal%),
`m` (mem total GB), `mu` (mem used GB, real — excludes buff/cache), `mp` (mem %),
`su` (swap used GB), `b[0]/b[1]` & `bm[0]/bm[1]` (net bytes/s, recv/sent).

### 3. Rollups keep the peak VALUE but **never the peak TIME**  ← key finding
The hub aggregates short records into longer buckets in `internal/records/records.go`:
```go
sum.MaxCpu = max(sum.MaxCpu, stats.MaxCpu, stats.Cpu)   // value only
```
It records the highest value in the bucket but discards *when* it happened. The agent
doesn't help — `MaxCpu` is `cbor:"-"`, computed hub-side, never timestamped. The only
timestamps in the DB are each record's `created`, i.e. **bucket boundaries**.
**Consequence: precise peak time is not recoverable from stored data — you must capture
it yourself from the 1m records before they're pruned.** That is what `peak-recorder.sh`
does.

### 4. Retention shrinks as buckets grow (`internal/records/records_deletion.go`)
| Bucket type | Peak-time precision | Retained for |
|---|---|---|
| `1m`   | ±1 min  | **1 hour** |
| `10m`  | ±10 min | 12 hours |
| `20m`  | ±20 min | 1 day |
| `120m` | ±2 h    | 7 days |
| `480m` | ±8 h    | 30 days |

So the best the DB ever offers is ±1 min, and only for the last hour. Beyond 30 days
nothing is kept at all — hence the append-CSV history pattern.

### 5. A `1m` value is itself a per-minute average
The agent pushes one value per minute; there's no instantaneous spike captured. So
"minute precision" is the realistic floor without a separate high-frequency poller.

---

## Decisions baked into the scripts

- **Percentiles computed client-side.** SQLite/PocketBase have no percentile aggregate,
  so `capacity*` pull per-sample rows and compute P95/P99 in awk (nearest-rank).
- **Avg=baseline, P95=sizing, P99=burst, Max=incident.** Avg/P95/P99 come from the
  `cpu` series; **Max comes from `cpum`** (per-bucket peak) so a real spike isn't smoothed
  away by averaging. This matches standard capacity-planning practice.
- **Real cores used = vCPU × util/100** at avg / p95 / peak — the provisioning-vs-usage
  signal for consolidation. Fleet utilization line = Σ cores used / Σ vCPU.
- **Memory reported in GB, not just %.** `mu` (real used, excl. buff/cache) is the
  working-set proxy; RAM is incompressible so peaks matter more than for CPU.
  Note: beszel does NOT collect per-process RSS, working-set breakdown, or hypervisor
  ballooning — those are guest/hypervisor metrics. `steal%` (`cpub[3]`) is the in-guest
  equivalent of ESXi "CPU Ready".
- **Large globs filter client-side.** A per-id `system="..." || ...` filter overflows the
  request URL and the hub returns **HTTP 400** once you select many hosts (e.g. `'*'`). So
  the `*-api`/`duck-ingest` scripts only send that filter when ≤30 hosts match; for larger
  selections they fetch all rows in the window and drop non-matching systems via the
  systems map in jq. Same results, no 400.
- **Auto bucket selection** (override with `BUCKET=...`):
  `≤24h→10m`, `≤96h→20m`, `≤480h→120m`, else `480m`. `1m` is never auto-selected (1h
  retention makes it unsafe for any window that can drift past 60 min); force `BUCKET=1m`
  for an explicit last-hour, minute-precise look.
- **`--peak-time` is experimental and table-only.** It adds a `MAX@`/`USED_MAX@` column
  (bucket-resolution timestamp). CSV schema is deliberately left unchanged so the
  long-term history file stays stable. Drop the flag to revert.
- **Peak times display in local time, default UTC+8.** beszel stores everything in UTC
  (`...Z`). The `--peak-time` columns and `peak-recorder.sh`'s `peak_at` convert to local
  via `TZ_OFFSET` (hours, default `8`; set `TZ_OFFSET=0` for UTC, `TZ_OFFSET=5.5` for
  half-hour zones). The column header shows the offset (`MAX@+8`) and the recorder CSV
  has a `tz` column, so timestamps are never ambiguous. Conversion uses a portable
  awk date-math helper (no `mktime`), so it works on BSD/gawk/mawk and handles
  month/year rollover. `detected_at` in the recorder CSV stays UTC.
- **`--csv` rows are self-describing** (`ts,window_h,bucket,...`) and `--no-header`
  enables clean appends — so a daily cron builds history that outlives the 30-day DB.
- **`peak-recorder.sh` uses the CSV as its own state.** It appends a row only when a host
  beats its previous all-time peak (idempotent across overlapping runs). Must run more
  often than the 1h `1m` retention (every ~15 min, `LOOKBACK_MIN=70`).
- **`duck-ingest.sh` is idempotent via `PRIMARY KEY (host, ts)` + `ON CONFLICT DO NOTHING`.**
  Overlapping fetch windows are safe, so it just pulls the last `LOOKBACK_MIN` each run (no
  watermark bookkeeping). Same cadence rule: run more often than the 1h `1m` retention.
  DuckDB is single-writer — one cron job is fine; don't let runs overlap (a flock) and run
  analysis read-only. `ts` is stored UTC; `duck-report-capacity.sh` shifts to local via `TZ_OFFSET`.
  Percentiles/peak-time use DuckDB natives (`quantile_cont`, `arg_max`) — accurate because
  the store holds raw 1m, unlike bucket-averaged reports off PB.

---

## Use cases

1. **Quick snapshot** — "what did CPU/mem/traffic look like over the last N hours?"
   → `stats.sh` / `stats-api.sh`.
2. **Capacity planning / right-sizing** — vCPU provisioned vs P95 real cores used; spot
   over-provisioned VMs (high vCPU, low P95). → `capacity*.sh`.
3. **Consolidation analysis** — sum reclaimable vCPU/RAM across a fleet; the `TOTAL` line
   + per-host P95 cores tells you how much you could pack down.
4. **Long-term trend beyond 30 days** — daily `capacity-api.sh --csv --no-header` appended
   to a history file; analyze provisioning-vs-usage over months (PB only keeps 30 days).
5. **Precise (minute-resolution) peak-time record** — `peak-recorder.sh` on a cron,
   harvesting `1m` data before the 1-hour purge; correlate spikes with deploys/incidents
   and keep an all-time peak log forever.
6. **Full analytical store (recommended for serious analysis)** — `duck-ingest.sh` on a
   cron into DuckDB keeps *every* raw 1m sample forever. `duck-report-capacity.sh` (or plain SQL)
   then gives accurate percentiles, exact peak times, hourly/daily rollups, and fleet
   totals. This is the superset of #4 and #5 — only skip it if you specifically want a
   zero-dependency (no DuckDB) setup.

## Caveats

- Percentiles on `10m`/`20m`+ buckets are over *averaged* points (smoothed); `Max`/`cpum`
  preserves the true peak. For tighter percentiles use a smaller bucket (shorter window).
- When comparing P95 across CSV history rows, compare like-bucket to like-bucket (the
  `bucket` column tells you which).
- Traffic counting follows the project's FRONTEND-only (HAProxy) / service-level (IPVS)
  rules — see the repo `CLAUDE.md` for the double-counting rationale.
