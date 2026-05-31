# Querying the DuckDB store

The `duck-ingest.sh` pipeline lands raw 1-minute samples in one table, `metrics`.
Because it's *raw* (not bucket-averaged), you can compute accurate percentiles, exact
peak times, and any rollup with plain SQL. `duck-report.sh` is just a canned version of
the capacity query below — everything here is the same data, queried directly.

## Schema

| column | type | meaning |
|---|---|---|
| `ts` | TIMESTAMP | sample minute, **UTC** |
| `host` | VARCHAR | system name |
| `vcpu` | INTEGER | provisioned vCPU (`info.c` else `info.t`) |
| `cpu` | DOUBLE | CPU utilisation % (0–100) |
| `steal` | DOUBLE | CPU steal % |
| `mem_used_gb` | DOUBLE | real used RAM (excl. buff/cache) |
| `mem_total_gb` | DOUBLE | total RAM |
| `mem_pct` | DOUBLE | used % |
| `swap_gb` | DOUBLE | swap used |
| `net_out_bps` / `net_in_bps` | UBIGINT | bytes/s |

Primary key `(host, ts)`.

## Connecting

```bash
DB=/var/lib/beszel/beszel.duckdb           # or your DUCK_DB path

# from the docker host (if duckdb is installed there)
duckdb -readonly "$DB" "SELECT count(*) FROM metrics"

# from inside the container (duckdb is always present there)
docker exec beszel-duck-ingest duckdb -readonly /data/beszel.duckdb "SELECT count(*) FROM metrics"

# interactive shell
duckdb -readonly "$DB"        #  .mode box  /  .tables  /  .schema metrics  /  .quit
```

**Always use `-readonly` for queries** — it signals intent and avoids fighting the ingester
for the write lock. The ingester only holds the lock for the few ms it writes (every 45 min),
so a reader almost never collides; if one ever does, just re-run.

### Timezone

`ts` is UTC. To read/group in local time (UTC+8) add an interval:

```sql
SELECT strftime(ts + INTERVAL '8 hours', '%Y-%m-%d %H:%M') AS local_ts, host, cpu
FROM metrics ORDER BY ts DESC LIMIT 5;
```

A handy time window: `ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '6 hours'`.

---

## Capacity planning (the core query)

Per-host avg / P95 / P99 / max CPU, real cores used, and the **exact minute** each peaked:

```sql
SELECT
  host,
  any_value(vcpu)                                   AS vcpu,
  count(*)                                          AS samples,
  round(avg(cpu),1)                                 AS cpu_avg,
  round(quantile_cont(cpu,0.95),1)                  AS cpu_p95,
  round(quantile_cont(cpu,0.99),1)                  AS cpu_p99,
  round(max(cpu),1)                                 AS cpu_max,
  round(any_value(vcpu)*quantile_cont(cpu,0.95)/100,2) AS cores_p95,
  strftime(arg_max(ts,cpu) + INTERVAL '8 hours','%Y-%m-%d %H:%M') AS cpu_peak_local
FROM metrics
WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '7 days'
  AND host LIKE 'ha-bop%'
GROUP BY host
ORDER BY cpu_p95 DESC;
```

`quantile_cont` = interpolated percentile; `arg_max(ts, cpu)` = the `ts` of the highest `cpu`.

## Right-sizing / consolidation candidates

Over-provisioned hosts — high vCPU, low real usage at P95:

```sql
SELECT host,
       any_value(vcpu)                                       AS vcpu,
       round(any_value(vcpu)*quantile_cont(cpu,0.95)/100,2)  AS cores_p95,
       round(any_value(vcpu) - any_value(vcpu)*quantile_cont(cpu,0.95)/100,1) AS reclaimable_vcpu
FROM metrics
WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '30 days'
GROUP BY host
HAVING quantile_cont(cpu,0.95) < 25      -- p95 below 25% util
ORDER BY reclaimable_vcpu DESC;
```

Fleet totals — provisioned vs actually used:

```sql
WITH per_host AS (
  SELECT host, any_value(vcpu) v,
         any_value(vcpu)*quantile_cont(cpu,0.95)/100 cp
  FROM metrics
  WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '30 days'
  GROUP BY host)
SELECT sum(v) AS vcpu_provisioned,
       round(sum(cp),1) AS cores_used_p95,
       round(100*sum(cp)/sum(v),1) AS fleet_util_pct,
       round(sum(v)-sum(cp),1) AS reclaimable_vcpu
FROM per_host;
```

## Trends & rollups

Hourly average/peak for one host (feed a chart):

```sql
SELECT time_bucket(INTERVAL '1 hour', ts) AS hour_utc,
       round(avg(cpu),1) avg_cpu, round(max(cpu),1) max_cpu,
       round(avg(mem_used_gb),1) avg_mem_gb
FROM metrics
WHERE host = 'ha-bop-1' AND ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '3 days'
GROUP BY 1 ORDER BY 1;
```

Daily P95 trend (is a host creeping up over weeks?):

```sql
SELECT (ts + INTERVAL '8 hours')::DATE AS day_local,
       round(quantile_cont(cpu,0.95),1) AS p95
FROM metrics WHERE host='ha-bop-1'
GROUP BY 1 ORDER BY 1;
```

Busiest hour-of-day across the fleet (capacity-window planning):

```sql
SELECT extract(hour FROM ts + INTERVAL '8 hours') AS hour_local,
       round(avg(cpu),1) avg_cpu, round(quantile_cont(cpu,0.95),1) p95
FROM metrics WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '14 days'
GROUP BY 1 ORDER BY p95 DESC;
```

## Grouping by host family (strip trailing -N)

```sql
SELECT regexp_replace(host,'-[0-9]+$','')            AS grp,
       count(DISTINCT host)                          AS hosts,
       round(avg(cpu),1)                             AS cpu_avg,
       round(quantile_cont(cpu,0.95),1)              AS cpu_p95
FROM metrics
WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '7 days'
GROUP BY 1 ORDER BY cpu_p95 DESC;
```

## Memory / swap pressure

```sql
-- hosts that touched swap, or ran hot on RAM
SELECT host, round(max(mem_pct),1) mem_pct_max,
       round(max(mem_used_gb),1) mem_used_max_gb,
       round(max(swap_gb),2) swap_max_gb,
       strftime(arg_max(ts,mem_used_gb)+INTERVAL '8 hours','%Y-%m-%d %H:%M') mem_peak_local
FROM metrics WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '7 days'
GROUP BY host
HAVING max(swap_gb) > 0 OR max(mem_pct) > 85
ORDER BY mem_pct_max DESC;
```

## Network top talkers

```sql
SELECT host,
       round(max(net_out_bps)*8/1e6,1) AS peak_out_mbps,
       round(max(net_in_bps)*8/1e6,1)  AS peak_in_mbps
FROM metrics WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '24 hours'
GROUP BY host ORDER BY peak_out_mbps DESC LIMIT 20;
```

## Data quality / gaps

Coverage per host (are minutes missing — ingester gap or host down?):

```sql
SELECT host, count(*) AS samples,
       strftime(min(ts),'%m-%d %H:%M') AS first_utc,
       strftime(max(ts),'%m-%d %H:%M') AS last_utc,
       date_diff('minute', min(ts), max(ts)) + 1 AS minutes_span,
       (date_diff('minute', min(ts), max(ts)) + 1) - count(*) AS missing_minutes
FROM metrics WHERE ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '24 hours'
GROUP BY host ORDER BY missing_minutes DESC LIMIT 20;
```

A few missing minutes is normal (agent push jitter); a large gap means the ingester missed a
window (cron interval crept past the 1m retention) or the host was down.

## Export & BI

```sql
-- CSV (for a spreadsheet / report)
COPY (
  SELECT host, any_value(vcpu) vcpu, round(quantile_cont(cpu,0.95),1) cpu_p95
  FROM metrics WHERE ts >= now() - INTERVAL '30 days' GROUP BY host ORDER BY host
) TO '/data/capacity_30d.csv' (HEADER, DELIMITER ',');

-- Parquet (for archival / external analytics; compresses well)
COPY (SELECT * FROM metrics) TO '/data/metrics.parquet' (FORMAT PARQUET);
```

DuckDB also speaks to Python/R/BI tools directly (e.g. `import duckdb; duckdb.connect(db, read_only=True)`),
and Grafana/Metabase can query it via the DuckDB driver — point them at the same file (read-only).

### Plotting / deeper analysis (planned — build once enough history exists)

Storing raw 1-minute data means rich offline analysis is possible later. Approaches, easiest →
most powerful:

1. **Spreadsheet** — `COPY (… aggregated query …) TO 'out.csv' (HEADER)`, chart in Excel/Sheets.
2. **Python (recommended for charts)** — DuckDB → pandas → matplotlib/plotly:
   ```python
   import duckdb, matplotlib.pyplot as plt
   con = duckdb.connect("data/beszel.duckdb", read_only=True)   # read-only: won't fight the ingester
   df = con.sql("""SELECT date_trunc('hour',ts) hour, quantile_cont(cpu,0.95) p95, avg(cpu) avg
                   FROM metrics WHERE host='es-prod-d-07' AND ts >= now() - INTERVAL 14 days
                   GROUP BY 1 ORDER BY 1""").df()
   df.plot(x="hour", y=["avg","p95"]); plt.savefig("es-prod-d-07.png")
   ```
3. **Grafana / Metabase** — DuckDB datasource on the same file (read-only) for live dashboards.

**Golden rule: aggregate in DuckDB, plot the small result** — push percentiles/rollups into SQL
(columnar, fast), return a compact frame; never load millions of raw rows into the plotter.
Candidate charts for capacity work: P95 trend over weeks (creep), hour-of-day × host heatmap,
provisioned-vs-used stacked area, utilization histograms/percentile bands.

> **Status:** intentionally NOT built yet — deferred until enough history accumulates. When
> ready, the plan is a `scripts/duck-plot.py` with these canned charts (saving PNGs to ./data),
> and/or a Grafana dashboard. Caveats to honor when building: open `read_only=True`; the data
> floor is 1-minute granularity (faster polling refreshes, doesn't add sub-minute detail).

## Housekeeping

The store grows ~`hosts × 1440 rows/day` (≈ tens of MB/year for 150 hosts — fine to keep).
If you ever want to cap history:

```sql
DELETE FROM metrics WHERE ts < now() - INTERVAL '180 days';
CHECKPOINT;     -- flush WAL to the main file
```

Re-ingesting overlapping windows never duplicates (PK `(host, ts)` + `ON CONFLICT DO NOTHING`),
so you can run ingest as often as you like.
