# Duck-UI query guide (browser DuckDB-WASM over the Parquet exports)

Copy-paste queries for the web UI. Duck-UI runs DuckDB **in your browser** and reads the
Parquet the loaders export, served at `/data/`:

| File | Source | Contents |
|---|---|---|
| `/data/metrics.parquet` | capacity (`duck-ingest`) | per-host CPU/mem/net, 1-min samples |
| `/data/haproxy_proxies.parquet` | HAProxy loader | per frontend/backend sample (rolling ~2 days) |
| `/data/haproxy_info.parquet` | HAProxy loader | per-host HAProxy process info |

Replace `<host>` below with your UI host (e.g. `kl-haproxy-duck.jumbo98.com`).

## 1. One-time setup — make views (so you don't paste URLs every query)
Run these once per session (paste all together):
```sql
CREATE OR REPLACE VIEW metrics  AS SELECT * FROM read_parquet('https://<host>/data/metrics.parquet');
CREATE OR REPLACE VIEW proxies  AS SELECT * FROM read_parquet('https://<host>/data/haproxy_proxies.parquet');
CREATE OR REPLACE VIEW info     AS SELECT * FROM read_parquet('https://<host>/data/haproxy_info.parquet');
```

## 2. WASM rules (this build has no ICU — follow these or queries error)
- **Relative time:** cast `now()` → `now()::TIMESTAMP` before interval math.
  `WHERE ts > now()::TIMESTAMP - INTERVAL 1 hour`  (NOT `now() - INTERVAL …`).
- **Local time display:** no `AT TIME ZONE`; just add your offset — `ts + INTERVAL 8 hour` (UTC+8).
- **Host glob → LIKE:** `ha-bop*` → `host LIKE 'ha-bop%'`, `ha-*` → `host LIKE 'ha-%'`, `?` → `_`.
- **Always filter by `ts`** — it keeps the browser fetching only the row-groups it needs instead of the
  whole Parquet file.
- `ts` is **UTC**.

---

## Capacity (metrics)

Top CPU hosts, last 24h:
```sql
SELECT host,
       round(avg(cpu),1)                AS cpu_avg,
       round(quantile_cont(cpu,0.95),1) AS cpu_p95,
       round(max(cpu),1)                AS cpu_max
FROM metrics
WHERE ts > now()::TIMESTAMP - INTERVAL 24 hour
GROUP BY host ORDER BY cpu_p95 DESC LIMIT 25;
```

A host group (e.g. `ha-bop*`), real cores used at P95 (vcpu × cpu%):
```sql
SELECT host,
       any_value(vcpu)                                   AS vcpu,
       round(quantile_cont(cpu,0.95),1)                  AS cpu_p95,
       round(any_value(vcpu)*quantile_cont(cpu,0.95)/100,2) AS cores_p95,
       round(max(mem_used_gb),1)                         AS mem_max_gb
FROM metrics
WHERE host LIKE 'ha-bop%' AND ts > now()::TIMESTAMP - INTERVAL 24 hour
GROUP BY host ORDER BY cpu_p95 DESC;
```

Per-minute CPU trend for one host (good for Duck-UI's chart view — plot `minute_local` vs `cpu`):
```sql
SELECT (ts + INTERVAL 8 hour) AS minute_local, cpu, mem_pct
FROM metrics
WHERE host = 'ha-bop-1' AND ts > now()::TIMESTAMP - INTERVAL 6 hour
ORDER BY 1;
```

Memory pressure (highest mem% right now-ish):
```sql
SELECT host, round(max(mem_pct),1) AS mem_pct_max, round(max(mem_used_gb),1) AS used_gb
FROM metrics
WHERE ts > now()::TIMESTAMP - INTERVAL 1 hour
GROUP BY host ORDER BY mem_pct_max DESC LIMIT 25;
```

---

## HAProxy — same output as `duck-report-haproxy.sh`

These reproduce the CLI report's four tables (identical columns) so the **Parquet/Duck-UI output matches
the CLI**. Edit the window (`INTERVAL 1 hour`) and host filter (`host LIKE 'ha-%'`) to taste. Peak-time
columns are local UTC+8 via `+ INTERVAL 8 hour` (change `8` to your offset). The CLI equivalent of each is
`docker compose exec haproxy-duck duck-report-haproxy.sh <hours> '<glob>'`.

**① Per-frontend traffic / sessions / 5xx** (FRONTEND only):
```sql
SELECT host, proxy, count(*) AS smpl,
       round(avg(req_rate),1)                                          AS req_avg,
       round(quantile_cont(req_rate,0.95),1)                          AS req_p95,
       max(req_rate)                                                   AS req_max,
       strftime(arg_max(ts,req_rate)     + INTERVAL 8 hour,'%m-%d %H:%M') AS req_max_at,
       max(scur)                                                       AS sess_max,
       round(avg(hrsp_5xx_rate),2)                                     AS e5xx_avg,
       max(hrsp_5xx_rate)                                              AS e5xx_max,
       strftime(arg_max(ts,hrsp_5xx_rate)+ INTERVAL 8 hour,'%m-%d %H:%M') AS e5xx_max_at,
       round(max(bin_rate)/1e6,2)                                      AS in_mbps_max,
       round(max(bout_rate)/1e6,2)                                     AS out_mbps_max
FROM proxies
WHERE host LIKE 'ha-%' AND type='FRONTEND' AND ts > now()::TIMESTAMP - INTERVAL 1 hour
GROUP BY host, proxy
ORDER BY regexp_replace(host,'[0-9]+$',''), TRY_CAST(regexp_extract(host,'([0-9]+)$',1) AS INTEGER) NULLS FIRST, proxy;
```

**② Slowest backends / servers** (by `rtime`):
```sql
SELECT host, proxy, type, count(*) AS smpl,
       round(avg(rtime),1)                AS rtime_avg,
       round(quantile_cont(rtime,0.95),1) AS rtime_p95,
       max(rtime)                         AS rtime_max,
       strftime(arg_max(ts,rtime) + INTERVAL 8 hour,'%m-%d %H:%M') AS rtime_max_at,
       round(avg(req_rate),1)             AS req_avg,
       max(scur)                          AS sess_max
FROM proxies
WHERE host LIKE 'ha-%' AND type IN ('BACKEND','SERVER') AND rtime > 0
  AND ts > now()::TIMESTAMP - INTERVAL 1 hour
GROUP BY host, proxy, type
ORDER BY rtime_p95 DESC, rtime_max DESC LIMIT 25;
```

**③ Backend / server availability (flaps)**:
```sql
SELECT host, proxy, type,
       min(act_srv) AS act_min, max(act_srv) AS act_max,
       min(bck_srv) AS bck_min, max(bck_srv) AS bck_max,
       count(DISTINCT status) AS status_states, any_value(status) AS a_status,
       sum(hchk_fail) AS hchk_fail
FROM proxies
WHERE host LIKE 'ha-%' AND type IN ('BACKEND','SERVER') AND ts > now()::TIMESTAMP - INTERVAL 6 hour
GROUP BY host, proxy, type
HAVING min(act_srv) <> max(act_srv) OR count(DISTINCT status) > 1 OR sum(hchk_fail) > 0
ORDER BY regexp_replace(host,'[0-9]+$',''), TRY_CAST(regexp_extract(host,'([0-9]+)$',1) AS INTEGER) NULLS FIRST, proxy, type;
```

**④ Per-host process health**:
```sql
SELECT host, any_value(version) AS version,
       round(avg(conn_rate),1) AS cps_avg, max(conn_rate) AS cps_max, max(curr_conns) AS conns_max,
       round(avg(idle_pct),1)  AS idle_avg, min(idle_pct) AS idle_min,
       strftime(arg_min(ts,idle_pct) + INTERVAL 8 hour,'%m-%d %H:%M') AS idle_min_at,
       max(run_queue) AS runq_max, max(pool_used_mb) AS pool_mb_max
FROM info
WHERE host LIKE 'ha-%' AND ts > now()::TIMESTAMP - INTERVAL 1 hour
GROUP BY host
ORDER BY regexp_replace(host,'[0-9]+$',''), TRY_CAST(regexp_extract(host,'([0-9]+)$',1) AS INTEGER) NULLS FIRST;
```

> Difference from the CLI: the CLI sees the **full DB** (14-day retention) and uses real timezone handling;
> Duck-UI reads the **rolling ~2-day Parquet** with the WASM offset trick. For windows beyond ~2 days, or
> exact local-time ranges, use the CLI: `duck-report-haproxy.sh '2026-06-01 02:00' '2026-06-01 03:00' 'ha-*'`.

---

## Tips
- **Natural host order** (ha-bop-2 before ha-bop-10):
  `ORDER BY regexp_replace(host,'[0-9]+$',''), TRY_CAST(regexp_extract(host,'([0-9]+)$',1) AS INTEGER) NULLS FIRST`
- **Charts:** return a time column (e.g. `ts + INTERVAL 8 hour`) + a numeric column and use Duck-UI's chart view.
- **Window limits:** the HAProxy Parquet is the last ~2 days, capacity is full history (or `CAPACITY_PARQUET_DAYS`).
  For older/longer HAProxy windows, use the CLI: `docker compose exec haproxy-duck duck-report-haproxy.sh …`
  (full DB + proper timezone handling). Full CLI cookbooks: `HAPROXY-QUERIES.md`, `QUERIES.md`.
