#!/usr/bin/env bash
# duck-daily-summary.sh — capacity rolled up per host "group" (NOT per host), over a
# chosen window. Reads the capacity DuckDB built by duck-ingest.sh (the `metrics`
# table: per-host 1-min cpu%/mem). Group = a host-name prefix (ha-bop-1, ha-bop-2 ->
# ha-bop). Two views: current usage, or a cloud capacity-planning forecast.
#
# Window args (same as duck-report.sh):
#   ./duck-daily-summary.sh [HOURS]              # relative: last N hours (default 24)
#   ./duck-daily-summary.sh 'FROM' 'TO'          # explicit range (LOCAL time, per TZ_OFFSET)
#
# VIEW=usage (default) — duck-report.sh column style, one row per GROUP:
#   nodes vcpu smpl  cpu_avg/p95/p99/max(%) steal  c_avg/c_p95/c_peak  cpu_max_at peak_host  mem_avg/p95/max/tot
#     cpu_*  = pooled over the group's samples (a single node's %, NOT a sum); cpu_max is the worst node-minute,
#              cpu_max_at/peak_host say when & which node. c_*  = REAL cores = sum over nodes of vcpu*cpu%/100
#              (c_avg==duck-report cores_used_avg). mem_* are GROUP TOTAL GB (summed across nodes).
#
# VIEW=forecast columns — "what to provision in cloud":
#   nodes  vcpu_prov  cores_p95 cores_peak  cpu_util_p95   provisioned vs CONSUMED cpu
#          mem_prov_gb mem_p95_gb mem_peak_gb mem_util_p95  provisioned vs CONSUMED ram
#          rec_vcpu   rec_mem_gb                            recommended cloud size for the GROUP
#     rec_vcpu  = ceil( (REC_BASIS cores) / TARGET_CPU_UTIL )   default: p95 cores at 70% target util
#     rec_mem_gb= ceil( mem_peak_gb * MEM_HEADROOM )            default: peak RAM * 1.2 (RAM isn't burstable)
#   Forecast off a REPRESENTATIVE window (weeks incl. busy days), e.g. a 30-day range, NOT 6h.
#
# Env:
#   DUCK_DB         DuckDB file (default: ./beszel.duckdb)   # in the duck container: /data/beszel.duckdb
#   TZ_OFFSET       local-time offset in hours (default: 8 = UTC+8). Used for FROM/TO args + peak time.
#   FORMAT          box (default, pretty) | csv (paste into Excel)
#   GROUP_MODE      sheet (default) = the 19 fixed spreadsheet rows below;
#                   auto           = derive the group from EVERY host name (strip trailing -N) and
#                                    aggregate all servers — no fixed list; also good for group discovery.
#   VIEW            usage (default) | forecast
#   TARGET_CPU_UTIL CPU headroom for rec_vcpu — how full to run cloud instances (default 0.7 = 70%)
#   MEM_HEADROOM    RAM multiplier for rec_mem_gb (default 1.2 = +20% over peak)
#   REC_BASIS       size rec_vcpu off 'p95' (default) or 'peak' cores
#   SORT            row order: name (default, by group name) | seq (the fixed spreadsheet order, sheet mode)
#
# Examples:
#   ./duck-daily-summary.sh 6                                       # last 6h, usage
#   VIEW=forecast ./duck-daily-summary.sh '2026-05-01' '2026-06-01' # 1-month cloud forecast (sheet rows)
#   VIEW=forecast GROUP_MODE=auto FORMAT=csv ./duck-daily-summary.sh '2026-05-01' '2026-06-01' > plan.csv
#   docker compose exec -T duck-ingest sh -lc \
#     'DUCK_DB=/data/beszel.duckdb VIEW=forecast duck-daily-summary.sh 720'   # ~30d
#
# Edit the GROUPS table below to add/rename rows or fix a prefix.

set -euo pipefail

DUCK_DB="${DUCK_DB:-./beszel.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"
FORMAT="${FORMAT:-box}"
GROUP_MODE="${GROUP_MODE:-sheet}"
VIEW="${VIEW:-usage}"
TARGET_CPU_UTIL="${TARGET_CPU_UTIL:-0.7}"
MEM_HEADROOM="${MEM_HEADROOM:-1.2}"
REC_BASIS="${REC_BASIS:-p95}"
SORT="${SORT:-name}"

command -v duckdb >/dev/null || { echo "duck-daily-summary.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$DUCK_DB" ]] || { echo "duck-daily-summary.sh: $DUCK_DB not found (run duck-ingest.sh first)" >&2; exit 1; }
[[ "$TARGET_CPU_UTIL" =~ ^[0-9]*\.?[0-9]+$ ]] || { echo "duck-daily-summary.sh: TARGET_CPU_UTIL must be a number (e.g. 0.7)" >&2; exit 1; }
[[ "$MEM_HEADROOM"    =~ ^[0-9]*\.?[0-9]+$ ]] || { echo "duck-daily-summary.sh: MEM_HEADROOM must be a number (e.g. 1.2)" >&2; exit 1; }

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# Window: same two forms as duck-report.sh (arg1 integer => relative hours; else FROM/TO local range).
if [[ "${1:-24}" =~ ^[0-9]+$ ]]; then
  HOURS="${1:-24}"
  WINDOW_SQL="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"
  WINDOW_LABEL="window=${HOURS}h"
else
  FROM="$1"; TO="${2:-}"
  [[ -n "$TO" ]] || { echo "duck-daily-summary.sh: range mode needs FROM and TO, e.g. '2026-05-01' '2026-06-01'" >&2; exit 1; }
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

# Membership CTE differs by mode; everything after it is shared.
#   sheet -> LEFT JOIN the fixed GROUPS table (keeps empty rows), ord = seq
#   auto  -> label = regexp_replace(host,'-[0-9]+$',''), every host, ord = NULL (order by label)
if [[ "$GROUP_MODE" == "auto" ]]; then
  MEMBER_CTE="
w AS (SELECT host, vcpu, cpu, steal, mem_used_gb, mem_total_gb, ts FROM metrics WHERE ${WINDOW_SQL}),
member AS (
  SELECT CAST(NULL AS INTEGER) AS ord,
         regexp_replace(host,'-[0-9]+\$','') AS label,
         host, vcpu, cpu, steal, mem_used_gb, mem_total_gb, ts
  FROM w
)"
else
  MEMBER_CTE="
groups(seq,label,pat) AS (${GROUPS_SQL}),
w AS (SELECT host, vcpu, cpu, steal, mem_used_gb, mem_total_gb, ts FROM metrics WHERE ${WINDOW_SQL}),
member AS (
  SELECT g.seq AS ord, g.label AS label,
         m.host, m.vcpu, m.cpu, m.steal, m.mem_used_gb, m.mem_total_gb, m.ts
  FROM groups g LEFT JOIN w m ON m.host LIKE g.pat
)"
fi

# Row order: by group name (default, natural sort) or the fixed spreadsheet seq (SORT=seq, sheet mode only).
if [[ "$SORT" == "seq" && "$GROUP_MODE" != "auto" ]]; then
  ORDER_SQL="gf.ord"
else
  ORDER_SQL="regexp_replace(gf.label,'[0-9]+\$',''), TRY_CAST(regexp_extract(gf.label,'([0-9]+)\$',1) AS INTEGER) NULLS FIRST, gf.label"
fi

# Column list differs by VIEW; the leading "#" only in sheet mode.
SEQCOL=""; [[ "$GROUP_MODE" != "auto" ]] && SEQCOL="gf.ord AS \"#\", "
if [[ "$VIEW" == "forecast" ]]; then
  COLS="${SEQCOL}gf.label AS \"group\", gf.nodes,
        gf.vcpu          AS vcpu_prov,
        gf.cores_p95, gf.cores_peak,
        gf.util_p95_pct  AS cpu_util_p95,
        gf.mem_tot_gb    AS mem_prov_gb,
        gf.mem_p95_gb, gf.mem_peak_gb,
        gf.mem_util_p95_pct AS mem_util_p95,
        gf.rec_vcpu, gf.rec_mem_gb"
else
  # usage view — duck-report.sh column style, but one row per GROUP (cpu% pooled over the
  # group's samples; c_*/mem_* summed across nodes like duck-report's fleet total).
  COLS="${SEQCOL}gf.label AS \"group\", gf.nodes, gf.vcpu, gf.smpl,
        gf.cpu_avg, gf.cpu_p95, gf.cpu_p99, gf.cpu_max, gf.steal,
        gf.cores_avg AS c_avg, gf.cores_p95 AS c_p95, gf.cores_peak AS c_peak,
        gf.cpu_max_at, gf.peak_host,
        gf.mem_used_gb AS mem_avg, gf.mem_p95_gb AS mem_p95, gf.mem_peak_gb AS mem_max, gf.mem_tot_gb AS mem_tot"
fi

[[ "$FORMAT" == "box" ]] && echo && \
  echo "beszel capacity by group — view=${VIEW} mode=${GROUP_MODE} ${WINDOW_LABEL}  peak-time=local${TZLABEL}  db=${DUCK_DB}" && \
  { [[ "$VIEW" == "forecast" ]] && echo "  rec_vcpu = ceil(${REC_BASIS} cores / ${TARGET_CPU_UTIL})   rec_mem_gb = ceil(peak RAM * ${MEM_HEADROOM})" || true; }

# Shared aggregation:
#   gm  = group-wide stats on raw samples (cpu% + which node/when peaked)
#   ha  = per-host rollup; agg = SUM across the group's nodes (true capacity math, like duck-report fleet total)
#   gf  = final per-group columns incl. memory percentiles + cloud sizing recommendation
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH ${MEMBER_CTE},
gm AS (
  SELECT ord, label,
         count(DISTINCT host)                                        AS nodes,
         count(cpu)                                                  AS smpl,
         round(avg(cpu),1)                                           AS cpu_avg,
         round(quantile_cont(cpu,0.95),1)                            AS cpu_p95,
         round(quantile_cont(cpu,0.99),1)                            AS cpu_p99,
         round(max(cpu),1)                                           AS cpu_max,
         round(max(steal),1)                                         AS steal,
         arg_max(host, cpu)                                          AS peak_host,
         strftime(arg_max(ts, cpu) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS cpu_max_at
  FROM member GROUP BY ord, label
),
ha AS (
  SELECT label, host,
         any_value(vcpu)                                  AS vcpu,
         any_value(vcpu)*avg(cpu)/100                      AS c_avg,
         any_value(vcpu)*quantile_cont(cpu,0.95)/100       AS c_p95,
         any_value(vcpu)*max(cpu)/100                      AS c_peak,
         any_value(mem_total_gb)                           AS mem_tot,
         avg(mem_used_gb)                                  AS mem_avg,
         quantile_cont(mem_used_gb,0.95)                   AS mem_p95,
         max(mem_used_gb)                                  AS mem_peak
  FROM member WHERE host IS NOT NULL GROUP BY label, host
),
agg AS (
  SELECT label,
         sum(vcpu)                                         AS vcpu,
         round(sum(c_avg),2)                               AS cores_avg,
         round(sum(c_p95),2)                               AS cores_p95,
         round(sum(c_peak),2)                              AS cores_peak,
         round(100*sum(c_p95)/nullif(sum(vcpu),0),1)       AS util_p95_pct,
         round(sum(mem_avg),1)                             AS mem_used_gb,
         round(sum(mem_p95),1)                             AS mem_p95_gb,
         round(sum(mem_peak),1)                            AS mem_peak_gb,
         round(sum(mem_tot),1)                             AS mem_tot_gb
  FROM ha GROUP BY label
),
gf AS (
  SELECT gm.ord, gm.label, gm.nodes, gm.smpl,
         gm.cpu_avg, gm.cpu_p95, gm.cpu_p99, gm.cpu_max, gm.steal, gm.peak_host, gm.cpu_max_at,
         a.vcpu, a.cores_avg, a.cores_p95, a.cores_peak, a.util_p95_pct,
         a.mem_used_gb, a.mem_p95_gb, a.mem_peak_gb, a.mem_tot_gb,
         round(100*a.mem_p95_gb/nullif(a.mem_tot_gb,0),1)                                   AS mem_util_p95_pct,
         CEIL((CASE WHEN '${REC_BASIS}'='peak' THEN a.cores_peak ELSE a.cores_p95 END)/${TARGET_CPU_UTIL}) AS rec_vcpu,
         CEIL(a.mem_peak_gb * ${MEM_HEADROOM})                                              AS rec_mem_gb
  FROM gm LEFT JOIN agg a USING (label)
)
SELECT ${COLS}
FROM gf
ORDER BY ${ORDER_SQL};
"
[[ "$FORMAT" == "box" ]] && echo || true
