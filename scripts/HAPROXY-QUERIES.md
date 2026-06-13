# HAProxy DuckDB — query cookbook (sysadmin reference)

Queries for the dedicated HAProxy store built by `duck-haproxy-ingest.sh`
(`haproxy.duckdb`). Companion to the capacity `QUERIES.md`.

- **`ts` is stored in UTC.** For local display add your offset, e.g. `ts + INTERVAL 8 hour`
  (UTC+8). For "recent" filters use `(now() AT TIME ZONE 'UTC')` so it compares against the
  naive-UTC `ts` column. When you pass an explicit local time as a *filter bound*, subtract the
  offset to get UTC (e.g. local 10:00 → `TIMESTAMP '... 02:00'`).
- **Traffic = FRONTEND only** (frontend in = backend out; counting both double-counts). Backend
  rows are for latency/availability, not traffic totals.
- **Rates vs counters:** `*_rate`, `req_rate`, `conn_rate`, `bin_rate`, `bout_rate` are
  per-second instantaneous (use these for "how busy"). `bin`, `bout`, `stot`, `hrsp_*`,
  `cum_*` are cumulative counters (use `max-min` deltas, not `sum`, over a window).
- **`rtime`** = avg response time (ms) over HAProxy's last ~1024 requests, per backend/server —
  this is the "which backend is slow" signal. (`qtime`/`ctime`/`ttime` aren't collected yet.)

## Open the database

```bash
# inside the loader container (recommended; readonly so it never blocks the loader)
docker compose exec haproxy-duck duckdb -readonly /data/haproxy.duckdb            # interactive REPL
docker compose exec haproxy-duck duckdb -readonly /data/haproxy.duckdb "SELECT 1" # one-shot

# or on a host with the duckdb CLI
duckdb -readonly /home/admin/beszel-duck/data/haproxy.duckdb
```

## Querying from Duck-UI (browser DuckDB-WASM) — read this first if using the web UI

Duck-UI does **not** connect to the server-side `haproxy.duckdb`. It runs DuckDB **in the
browser (WASM)** and reads the rolling **Parquet** the loader exports, served at `/data/`.
So query with `read_parquet(<url>)` (or make views once):

```sql
CREATE OR REPLACE VIEW proxies AS
  SELECT * FROM read_parquet('https://<your-host>/data/haproxy_proxies.parquet');
CREATE OR REPLACE VIEW info AS
  SELECT * FROM read_parquet('https://<your-host>/data/haproxy_info.parquet');
```

Two WASM differences from the CLI examples below (the browser build has **no ICU extension**):

- **No `now() - INTERVAL …`.** `now()` is `TIMESTAMP WITH TIME ZONE`, and tz arithmetic needs ICU →
  `Binder Error: No function matches '-(TIMESTAMP WITH TIME ZONE, INTERVAL)'`. **Cast it:**
  `now()::TIMESTAMP - INTERVAL 1 hour` (matches the UTC `ts` column). Or use a literal UTC bound:
  `ts > TIMESTAMP '2026-06-01 02:00:00'`.
- **No `AT TIME ZONE`.** For local-time display just add a fixed offset — `ts + INTERVAL 8 hour`
  (TIMESTAMP + INTERVAL is fine without ICU).

So in Duck-UI, anywhere the CLI cookbook says `(now() AT TIME ZONE 'UTC')`, write `now()::TIMESTAMP`,
and query the views (or `read_parquet(...)`) instead of the table names. Example:

```sql
SELECT host, proxy,
       round(quantile_cont(rtime,0.95),1) AS p95_ms, max(rtime) AS max_ms
FROM proxies
WHERE type='BACKEND' AND ts > now()::TIMESTAMP - INTERVAL 1 hour
GROUP BY host, proxy ORDER BY p95_ms DESC;
```

**Performance:** the Parquet is a rolling window (default 2 days, ~hundreds of MB). DuckDB-WASM range-fetches
only the row-groups a query needs **when you filter by `ts`** (data is time-ordered). A query with **no time
filter** downloads the whole file into the browser — always scope to a window.

## DuckDB CLI / meta commands (in the REPL)

```
.tables                         -- list tables
.schema haproxy_proxies         -- show CREATE TABLE
DESCRIBE haproxy_proxies;       -- columns + types
SUMMARIZE haproxy_proxies;      -- per-column min/max/avg/approx-unique/nulls (great first look)
PRAGMA database_size;           -- on-disk size + row counts
.mode box | csv | markdown | json   -- output format
.timer on                       -- show query time
.maxrows 200                    -- REPL row cap
.once out.csv  /  .output f.csv -- send next result(s) to a file
.read script.sql                -- run a .sql file
.help                           -- all dot-commands
.quit
```

## Schema

`haproxy_proxies` — PK `(system, ts, proxy, type)`; one row per FRONTEND/BACKEND (and SERVER if
enabled) per sample:
`ts, system, host, proxy, type, status, scur, smax, slim, stot, bin, bout, bin_rate, bout_rate,
req_rate, req_tot, rtime, hrsp_1xx..hrsp_5xx, hrsp_1xx_rate..hrsp_5xx_rate, hchk_fail, act_srv,
bck_srv`

`haproxy_info` — PK `(system, ts)`; one row per host per sample:
`ts, system, host, version, uptime_sec, maxconn, nbthread, curr_conns, cum_conns, cum_req,
conn_rate, max_conn_rate, sess_rate, max_sess_rate, curr_ssl_conns, ssl_rate, tasks, run_queue,
idle_pct, pool_alloc_mb, pool_used_mb, mem_max_mb, bytes_out_tot, bytes_out_rate`

---

## Latency — "which backend is slow"

Slowest backends, last hour (avg / p95 / p99 / max ms):
```sql
SELECT host, proxy,
       round(avg(rtime),1)                AS avg_ms,
       round(quantile_cont(rtime,0.95),1) AS p95_ms,
       round(quantile_cont(rtime,0.99),1) AS p99_ms,
       max(rtime)                         AS max_ms,
       count(*)                           AS samples
FROM haproxy_proxies
WHERE type='BACKEND' AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 1 hour
GROUP BY host, proxy
ORDER BY p95_ms DESC
LIMIT 20;
```

Exact moment each backend peaked (last 24h, local time):
```sql
SELECT host, proxy, max(rtime) AS max_ms,
       strftime(arg_max(ts, rtime) + INTERVAL 8 hour, '%Y-%m-%d %H:%M:%S') AS peak_at_local
FROM haproxy_proxies
WHERE type='BACKEND' AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 24 hour
GROUP BY host, proxy
ORDER BY max_ms DESC
LIMIT 20;
```

When did one backend get slow? Per-minute rtime trend:
```sql
SELECT time_bucket(INTERVAL 1 minute, ts) + INTERVAL 8 hour AS minute_local,
       round(avg(rtime),1) AS avg_ms, max(rtime) AS max_ms
FROM haproxy_proxies
WHERE type='BACKEND' AND host='ha-bop-1' AND proxy='web_backend'
  AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 6 hour
GROUP BY 1 ORDER BY 1;
```

Daily slow-backend leaderboard (creeping degradation over weeks):
```sql
SELECT (ts + INTERVAL 8 hour)::DATE AS day_local, host, proxy,
       round(quantile_cont(rtime,0.95),1) AS p95_ms
FROM haproxy_proxies WHERE type='BACKEND'
GROUP BY 1,2,3
ORDER BY day_local DESC, p95_ms DESC;
```

---

## Errors

5xx by frontend, last hour (use the rate; `hrsp_5xx` is cumulative):
```sql
SELECT host, proxy,
       round(avg(hrsp_5xx_rate),2) AS avg_5xx_per_s,
       max(hrsp_5xx_rate)          AS max_5xx_per_s,
       max(hrsp_5xx) - min(hrsp_5xx) AS total_5xx_in_window
FROM haproxy_proxies
WHERE type='FRONTEND' AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 1 hour
GROUP BY host, proxy
HAVING max(hrsp_5xx_rate) > 0
ORDER BY max_5xx_per_s DESC;
```

4xx vs 5xx split per frontend (window deltas):
```sql
SELECT host, proxy,
       max(hrsp_2xx)-min(hrsp_2xx) AS d2xx,
       max(hrsp_4xx)-min(hrsp_4xx) AS d4xx,
       max(hrsp_5xx)-min(hrsp_5xx) AS d5xx
FROM haproxy_proxies
WHERE type='FRONTEND' AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 1 hour
GROUP BY host, proxy ORDER BY d5xx DESC;
```

---

## Throughput & sessions

Busiest frontends by request rate:
```sql
SELECT host, proxy, round(avg(req_rate),0) AS avg_rps, max(req_rate) AS max_rps
FROM haproxy_proxies
WHERE type='FRONTEND' AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 1 hour
GROUP BY host, proxy ORDER BY max_rps DESC LIMIT 20;
```

Top traffic talkers (frontend only, MB/s):
```sql
SELECT host, proxy,
       round(max(bin_rate)/1e6,2)  AS max_in_MBps,
       round(max(bout_rate)/1e6,2) AS max_out_MBps
FROM haproxy_proxies
WHERE type='FRONTEND' AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 1 hour
GROUP BY host, proxy ORDER BY max_out_MBps DESC LIMIT 20;
```

Session saturation — anything approaching its configured limit:
```sql
SELECT host, proxy, type,
       max(scur) AS max_sessions, any_value(slim) AS limit_,
       round(100.0*max(scur)/nullif(any_value(slim),0),1) AS pct_of_limit
FROM haproxy_proxies
WHERE slim > 0 AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 1 hour
GROUP BY host, proxy, type
ORDER BY pct_of_limit DESC NULLS LAST LIMIT 20;
```

---

## Availability & host health

Backend flaps / health-check failures (last 6h):
```sql
SELECT host, proxy,
       min(act_srv) AS min_active, max(act_srv) AS max_active,
       count(DISTINCT status) AS status_states,
       max(hchk_fail) AS hchk_fail_max
FROM haproxy_proxies
WHERE type='BACKEND' AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 6 hour
GROUP BY host, proxy
HAVING min(act_srv) <> max(act_srv) OR count(DISTINCT status) > 1 OR max(hchk_fail) > 0
ORDER BY host, proxy;
```

Per-host HAProxy process health (low idle% = CPU-bound; growing run_queue = overload):
```sql
SELECT host, any_value(version) AS ver,
       round(avg(conn_rate),0) AS avg_cps, max(conn_rate) AS max_cps,
       max(curr_conns) AS max_conns,
       min(idle_pct)   AS min_idle_pct,
       max(run_queue)  AS max_run_queue,
       max(pool_used_mb) AS pool_mb
FROM haproxy_info
WHERE ts > (now() AT TIME ZONE 'UTC') - INTERVAL 1 hour
GROUP BY host ORDER BY min_idle_pct ASC;
```

Connections vs maxconn headroom:
```sql
SELECT host, max(curr_conns) AS peak_conns, any_value(maxconn) AS maxconn,
       round(100.0*max(curr_conns)/nullif(any_value(maxconn),0),1) AS pct_used
FROM haproxy_info
WHERE ts > (now() AT TIME ZONE 'UTC') - INTERVAL 24 hour
GROUP BY host ORDER BY pct_used DESC;
```

---

## Investigations

Compare a backend before/after a change (times are UTC — subtract your offset):
```sql
SELECT proxy,
  round(avg(rtime) FILTER (WHERE ts <  TIMESTAMP '2026-06-01 02:00'),1) AS before_ms,
  round(avg(rtime) FILTER (WHERE ts >= TIMESTAMP '2026-06-01 02:00'),1) AS after_ms
FROM haproxy_proxies
WHERE type='BACKEND' AND host='ha-bop-1'
  AND ts BETWEEN TIMESTAMP '2026-06-01 01:00' AND TIMESTAMP '2026-06-01 03:00'
GROUP BY proxy ORDER BY after_ms DESC;
```

Busiest hour-of-day for a frontend (capacity-window planning, local hour):
```sql
SELECT extract('hour' FROM ts + INTERVAL 8 hour) AS hour_local,
       round(avg(req_rate),0) AS avg_rps, max(req_rate) AS max_rps
FROM haproxy_proxies WHERE type='FRONTEND' AND proxy='web_frontend'
GROUP BY 1 ORDER BY max_rps DESC;
```

Data coverage / gaps per host (spot agents that stopped reporting):
```sql
SELECT host, count(*) AS samples,
       strftime(min(ts)+INTERVAL 8 hour,'%Y-%m-%d %H:%M') AS first_local,
       strftime(max(ts)+INTERVAL 8 hour,'%Y-%m-%d %H:%M') AS last_local
FROM haproxy_proxies GROUP BY host ORDER BY last_local;
```

---

## Maintenance & export

```sql
PRAGMA database_size;                                  -- size + row counts
SELECT count(*) FROM haproxy_proxies;                  -- rows (÷ size for bytes/row)

-- manual retention (the loader does this automatically when HAPROXY_RETENTION_DAYS is set)
DELETE FROM haproxy_proxies WHERE ts < (now() AT TIME ZONE 'UTC') - INTERVAL 7 day;
DELETE FROM haproxy_info    WHERE ts < (now() AT TIME ZONE 'UTC') - INTERVAL 7 day;
CHECKPOINT;   -- flush WAL to the main file
```
Note: DuckDB reuses freed pages but does not shrink the file in place. To truly reclaim disk
after a big delete, recreate: `COPY` the kept rows to Parquet, drop/recreate the DB, re-import.

Export a slice for a spreadsheet / sharing:
```sql
COPY (SELECT * FROM haproxy_proxies
      WHERE host='ha-bop-1' AND type='BACKEND'
        AND ts > (now() AT TIME ZONE 'UTC') - INTERVAL 24 hour)
  TO '/data/ha-bop-1-backends.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM haproxy_proxies) TO '/data/haproxy_proxies.parquet' (FORMAT PARQUET);
```

## The canned report (no SQL needed)
```bash
docker compose exec haproxy-duck duck-report-haproxy.sh 1 'ha-*'                       # last hour
docker compose exec haproxy-duck duck-report-haproxy.sh '2026-06-01 02:00' '2026-06-01 03:00' 'ha-bop*'
```
Prints: per-frontend traffic/5xx/sessions, slowest backends by `rtime`, backend flaps, per-host
process health — over the window (relative `[HOURS]` or explicit local `'FROM' 'TO'`).
