#!/usr/bin/env bash
# duck-daily-summary.sh — one capacity row per host "group" (NOT per host), in the
# exact order of the ops capacity spreadsheet, over a chosen window. Reads the
# capacity DuckDB built by duck-ingest.sh (the `metrics` table: per-host 1-min
# cpu%/mem). Group = a host-name prefix (e.g. ha-bop-1, ha-bop-2 -> group ha-bop).
#
# Same window args as duck-report.sh:
#   ./duck-daily-summary.sh [HOURS]              # relative: last N hours (default 24)
#   ./duck-daily-summary.sh 'FROM' 'TO'          # explicit range (LOCAL time, per TZ_OFFSET)
#
# Columns (capacity format, aggregated per group):
#   nodes        distinct hosts that reported in the window
#   vcpu         provisioned vCPU summed across the group's nodes
#   cpu_avg/p95/peak   group-wide cpu% over every node's 1-min samples
#   peak_host/at the node + local time that hit the cpu peak
#   cores_p95/peak     REAL cores used = sum over nodes of vcpu*cpu%/100 (p95 / max)
#   util_p95_pct 100*cores_p95/vcpu — how full the group is at p95
#   mem_used_gb/mem_tot_gb   used (avg) vs provisioned memory, summed across nodes
#
# Env:
#   DUCK_DB     DuckDB file (default: ./beszel.duckdb)   # in the duck container: /data/beszel.duckdb
#   TZ_OFFSET   local-time offset in hours (default: 8 = UTC+8). Used for the FROM/TO args + peak time.
#   FORMAT      box (default, pretty) | csv (paste into Excel)
#   GROUP_MODE  sheet (default) = the 19 fixed spreadsheet rows below;
#               auto           = derive the group from EVERY host name (strip trailing -N, so
#                                ha-bop-1/ha-bop-2 -> ha-bop) and aggregate all servers. Use this
#                                when your hosts don't match the fixed list, or to discover groups.
#
# Examples:
#   ./duck-daily-summary.sh 6                                  # last 6 hours
#   ./duck-daily-summary.sh 24                                 # last 24 hours
#   ./duck-daily-summary.sh '2026-06-01' '2026-06-02'          # whole local day
#   ./duck-daily-summary.sh '2026-06-01 09:00' '2026-06-01 17:00'   # business hours
#   FORMAT=csv ./duck-daily-summary.sh '2026-06-01' '2026-06-02' > 2026-06-01.csv
#   docker compose exec -T duck-ingest sh -lc \
#     'DUCK_DB=/data/beszel.duckdb FORMAT=csv duck-daily-summary.sh 6'
#
# Edit the GROUPS table below to add/rename rows or fix a prefix.

set -euo pipefail

DUCK_DB="${DUCK_DB:-./beszel.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"
FORMAT="${FORMAT:-box}"
GROUP_MODE="${GROUP_MODE:-sheet}"

command -v duckdb >/dev/null || { echo "duck-daily-summary.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$DUCK_DB" ]] || { echo "duck-daily-summary.sh: $DUCK_DB not found (run duck-ingest.sh first)" >&2; exit 1; }

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# Window: same two forms as duck-report.sh (arg1 integer => relative hours; else FROM/TO local range).
if [[ "${1:-24}" =~ ^[0-9]+$ ]]; then
  HOURS="${1:-24}"
  WINDOW_SQL="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"
  WINDOW_LABEL="window=${HOURS}h"
else
  FROM="$1"; TO="${2:-}"
  [[ -n "$TO" ]] || { echo "duck-daily-summary.sh: range mode needs FROM and TO, e.g. '2026-06-01' '2026-06-02'" >&2; exit 1; }
  for t in "$FROM" "$TO"; do
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([\ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]] || \
      { echo "duck-daily-summary.sh: bad timestamp '$t' (use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM')" >&2; exit 1; }
  done
  # args are local time -> convert to the UTC stored in `ts` by subtracting the offset
  WINDOW_SQL="ts >= TIMESTAMP '${FROM}' - INTERVAL '${OFF_MIN} minutes' AND ts < TIMESTAMP '${TO}' - INTERVAL '${OFF_MIN} minutes'"
  WINDOW_LABEL="from='${FROM}' to='${TO}' local${TZLABEL}"
fi

# ---- GROUPS: (seq, label, host LIKE pattern) — spreadsheet row order ----
# '%' = wildcard suffix, so 'ha-bop%' covers ha-bop, ha-bop-1, ha-bop-2, ...
GROUPS_SQL="VALUES
  ( 1, 'Credit Lvs',          'lvs-credit%'),
  ( 2, 'Credit Haproxy',      'ha-credit%'),
  ( 3, 'lvs-lic',             'lvs-lic%'),
  ( 4, 'lvs-bop',             'lvs-bop%'),
  ( 5, 'lvs-sgs',             'lvs-sgs%'),
  ( 6, 'ha-lic',              'ha-lic%'),
  ( 7, 'ha-bop',              'ha-bop%'),
  ( 8, 'ha-sgs',              'ha-sgs%'),
  ( 9, 'lvs-admin',           'lvs-admin%'),
  (10, 'lvs-candy',           'lvs-candy%'),
  (11, 'lvs-common',          'lvs-common%'),
  (12, 'lvs-3p',              'lvs-3p%'),
  (13, 'ha-admin',            'ha-admin%'),
  (14, 'ha-candy',            'ha-candy%'),
  (15, 'ha-common',           'ha-common%'),
  (16, 'ha-3p',               'ha-3p%'),
  (17, 'proxy-sw-jp',         'proxy-sw-jp%'),
  (18, 'proxy-sw-kr',         'proxy-sw-kr%'),
  (19, 'proxy-sw-th',         'proxy-sw-th%')"

FLAG="-box"; [[ "$FORMAT" == "csv" ]] && FLAG="-csv"

[[ "$FORMAT" == "box" ]] && echo && \
  echo "beszel capacity by group — mode=${GROUP_MODE} ${WINDOW_LABEL}  peak-time=local${TZLABEL}  db=${DUCK_DB}"

# Two CTEs in both modes:
#   gm  = group-wide stats on raw samples (cpu% + which node/when peaked)
#   ha  = per-host aggregation, then cores = SUM across the group's nodes (true capacity math,
#         matching duck-report.sh's fleet total).
# Difference is only how a host maps to a group:
#   sheet -> LIKE-join against the fixed GROUPS table (keeps empty rows via LEFT JOIN)
#   auto  -> grp = regexp_replace(host,'-[0-9]+$','')  (every host, no fixed list)
if [[ "$GROUP_MODE" == "auto" ]]; then
  duckdb -readonly "$FLAG" "$DUCK_DB" "
  WITH w AS (
    SELECT host, vcpu, cpu, mem_used_gb, mem_total_gb, ts,
           regexp_replace(host,'-[0-9]+\$','') AS grp
    FROM metrics WHERE ${WINDOW_SQL}
  ),
  gm AS (
    SELECT grp,
           count(DISTINCT host)                                      AS nodes,
           round(avg(cpu),1)                                         AS cpu_avg,
           round(quantile_cont(cpu,0.95),1)                          AS cpu_p95,
           round(max(cpu),1)                                         AS cpu_peak,
           arg_max(host, cpu)                                        AS peak_host,
           strftime(arg_max(ts, cpu) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS peak_at
    FROM w GROUP BY grp
  ),
  ha AS (
    SELECT grp, host,
           any_value(vcpu)                                  AS vcpu,
           any_value(vcpu)*quantile_cont(cpu,0.95)/100      AS c_p95,
           any_value(vcpu)*max(cpu)/100                     AS c_peak,
           any_value(mem_total_gb)                          AS mem_tot,
           avg(mem_used_gb)                                 AS mem_used
    FROM w GROUP BY grp, host
  ),
  cores AS (
    SELECT grp,
           sum(vcpu)                                        AS vcpu,
           round(sum(c_p95),2)                              AS cores_p95,
           round(sum(c_peak),2)                             AS cores_peak,
           round(100*sum(c_p95)/nullif(sum(vcpu),0),1)      AS util_p95_pct,
           round(sum(mem_used),1)                           AS mem_used_gb,
           round(sum(mem_tot),1)                            AS mem_tot_gb
    FROM ha GROUP BY grp
  )
  SELECT gm.grp AS group, gm.nodes, c.vcpu, gm.cpu_avg, gm.cpu_p95, gm.cpu_peak,
         gm.peak_host, gm.peak_at, c.cores_p95, c.cores_peak, c.util_p95_pct,
         c.mem_used_gb, c.mem_tot_gb
  FROM gm JOIN cores c USING (grp)
  ORDER BY regexp_replace(gm.grp,'[0-9]+\$',''),
           TRY_CAST(regexp_extract(gm.grp,'([0-9]+)\$',1) AS INTEGER) NULLS FIRST, gm.grp;
  "
else
  duckdb -readonly "$FLAG" "$DUCK_DB" "
  WITH groups(seq,label,pat) AS (
    ${GROUPS_SQL}
  ),
  w AS (
    SELECT host, vcpu, cpu, mem_used_gb, mem_total_gb, ts FROM metrics WHERE ${WINDOW_SQL}
  ),
  gm AS (
    SELECT g.seq, g.label,
           count(DISTINCT m.host)                                       AS nodes,
           round(avg(m.cpu),1)                                          AS cpu_avg,
           round(quantile_cont(m.cpu,0.95),1)                           AS cpu_p95,
           round(max(m.cpu),1)                                          AS cpu_peak,
           arg_max(m.host, m.cpu)                                       AS peak_host,
           strftime(arg_max(m.ts, m.cpu) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS peak_at
    FROM groups g LEFT JOIN w m ON m.host LIKE g.pat
    GROUP BY g.seq, g.label
  ),
  ha AS (
    SELECT g.seq AS seq, m.host AS host,
           any_value(m.vcpu)                                  AS vcpu,
           any_value(m.vcpu)*quantile_cont(m.cpu,0.95)/100    AS c_p95,
           any_value(m.vcpu)*max(m.cpu)/100                   AS c_peak,
           any_value(m.mem_total_gb)                          AS mem_tot,
           avg(m.mem_used_gb)                                 AS mem_used
    FROM groups g JOIN w m ON m.host LIKE g.pat
    GROUP BY g.seq, m.host
  ),
  cores AS (
    SELECT seq,
           sum(vcpu)                                          AS vcpu,
           round(sum(c_p95),2)                                AS cores_p95,
           round(sum(c_peak),2)                               AS cores_peak,
           round(100*sum(c_p95)/nullif(sum(vcpu),0),1)        AS util_p95_pct,
           round(sum(mem_used),1)                             AS mem_used_gb,
           round(sum(mem_tot),1)                              AS mem_tot_gb
    FROM ha GROUP BY seq
  )
  SELECT
    gm.seq        AS \"#\",
    gm.label      AS group,
    gm.nodes, c.vcpu, gm.cpu_avg, gm.cpu_p95, gm.cpu_peak,
    gm.peak_host, gm.peak_at, c.cores_p95, c.cores_peak, c.util_p95_pct,
    c.mem_used_gb, c.mem_tot_gb
  FROM gm LEFT JOIN cores c USING (seq)
  ORDER BY gm.seq;
  "
fi
[[ "$FORMAT" == "box" ]] && echo || true
