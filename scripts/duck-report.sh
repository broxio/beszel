#!/usr/bin/env bash
# duck-report.sh — capacity report straight from the DuckDB store built by
# duck-ingest.sh. Because we keep raw 1m samples, DuckDB gives true percentiles
# AND the EXACT minute each peak occurred (arg_max) — the thing beszel's rollups
# throw away.
#
# Usage:
#   ./duck-report.sh [HOURS] [HOST_GLOB]                  # relative: last N hours
#   ./duck-report.sh 'FROM' 'TO' [HOST_GLOB]              # explicit range (local time)
#
# Env:
#   DUCK_DB      DuckDB file (default: ./beszel.duckdb)
#   TZ_OFFSET    local-time offset in hours, used for BOTH peak-time display and
#                the FROM/TO range args (default: 8 = UTC+8; 0 = UTC)
#
# Examples:
#   ./duck-report.sh 6 'ha-bop*'
#   DUCK_DB=/var/lib/beszel/beszel.duckdb ./duck-report.sh 168 '*'   # last 7 days
#   ./duck-report.sh '2026-05-30 09:00' '2026-05-30 17:00' 'ha-bop*' # explicit local range
#   ./duck-report.sh 2026-05-30 2026-05-31 '*'                       # whole day (local)
#
# Ad-hoc analysis is just SQL, e.g.:
#   duckdb $DUCK_DB "SELECT date_trunc('hour',ts) h, avg(cpu) FROM metrics
#                    WHERE host='ha-bop-1' GROUP BY 1 ORDER BY 1"

set -euo pipefail

DUCK_DB="${DUCK_DB:-./beszel.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"

command -v duckdb >/dev/null || { echo "duck-report.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$DUCK_DB" ]] || { echo "duck-report.sh: $DUCK_DB not found (run duck-ingest.sh first)" >&2; exit 1; }

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# Two invocation forms (decided by whether arg 1 is a bare integer):
#   relative:  duck-report.sh [HOURS] [HOST_GLOB]
#   range:     duck-report.sh 'FROM' 'TO' [HOST_GLOB]   (timestamps are LOCAL, per TZ_OFFSET)
if [[ "${1:-6}" =~ ^[0-9]+$ ]]; then
  HOURS="${1:-6}"; GLOB="${2:-*}"
  WINDOW_SQL="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"
  WINDOW_LABEL="window=${HOURS}h"
else
  FROM="$1"; TO="${2:-}"; GLOB="${3:-*}"
  [[ -n "$TO" ]] || { echo "duck-report.sh: range mode needs FROM and TO, e.g. '2026-05-30 09:00' '2026-05-30 17:00'" >&2; exit 1; }
  for t in "$FROM" "$TO"; do
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([\ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]] || \
      { echo "duck-report.sh: bad timestamp '$t' (use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM')" >&2; exit 1; }
  done
  # args are local time -> convert to the UTC stored in `ts` by subtracting the offset
  WINDOW_SQL="ts >= TIMESTAMP '${FROM}' - INTERVAL '${OFF_MIN} minutes' AND ts < TIMESTAMP '${TO}' - INTERVAL '${OFF_MIN} minutes'"
  WINDOW_LABEL="from='${FROM}' to='${TO}' local${TZLABEL}"
fi

# shell glob -> SQL LIKE (* -> %, ? -> _)
LIKE="${GLOB//\%/\\%}"; LIKE="${LIKE//_/\\_}"; LIKE="${LIKE//\*/%}"; LIKE="${LIKE//\?/_}"

echo
echo "beszel capacity (DuckDB) — ${WINDOW_LABEL}  glob=${GLOB}  peak-time=local${TZLABEL}  db=${DUCK_DB}"

# ---- per-host: percentiles + exact peak time + real cores ----
duckdb -readonly -box "$DUCK_DB" "
WITH w AS (
  SELECT * FROM metrics
  WHERE host LIKE '${LIKE}' ESCAPE '\\'
    AND ${WINDOW_SQL}
)
SELECT
  host,
  count(*)                                                     AS sampl,
  any_value(vcpu)                                              AS vcpu,
  round(avg(cpu),1)                                            AS cpu_avg,
  round(quantile_cont(cpu,0.95),1)                            AS cpu_p95,
  round(quantile_cont(cpu,0.99),1)                            AS cpu_p99,
  round(max(cpu),1)                                            AS cpu_peak,
  round(max(steal),1)                                          AS steal,
  round(any_value(vcpu)*avg(cpu)/100,2)                       AS cores_avg,
  round(any_value(vcpu)*quantile_cont(cpu,0.95)/100,2)        AS cores_p95,
  round(any_value(vcpu)*quantile_cont(cpu,0.99)/100,2)        AS cores_p99,
  round(any_value(vcpu)*max(cpu)/100,2)                       AS cores_peak,
  strftime(arg_max(ts,cpu)        + INTERVAL '${OFF_MIN} minutes','%Y-%m-%d %H:%M') AS cpu_peak_at,
  round(any_value(mem_total_gb),1)                            AS mem_total,
  round(avg(mem_used_gb),1)                                    AS mem_avg,
  round(quantile_cont(mem_used_gb,0.95),1)                    AS mem_p95,
  round(quantile_cont(mem_used_gb,0.99),1)                    AS mem_p99,
  round(max(mem_used_gb),1)                                    AS mem_peak,
  strftime(arg_max(ts,mem_used_gb) + INTERVAL '${OFF_MIN} minutes','%Y-%m-%d %H:%M') AS mem_peak_at
FROM w
GROUP BY host
ORDER BY regexp_replace(host,'[0-9]+\$',''),
         TRY_CAST(regexp_extract(host,'([0-9]+)\$',1) AS INTEGER) NULLS FIRST;
"

# ---- fleet total: provisioned vs real cores used ----
duckdb -readonly -box "$DUCK_DB" "
WITH w AS (
  SELECT * FROM metrics
  WHERE host LIKE '${LIKE}' ESCAPE '\\'
    AND ${WINDOW_SQL}
),
per_host AS (
  SELECT host, any_value(vcpu) v,
         any_value(vcpu)*avg(cpu)/100 ca,
         any_value(vcpu)*quantile_cont(cpu,0.95)/100 cp,
         any_value(vcpu)*quantile_cont(cpu,0.99)/100 cq,
         any_value(vcpu)*max(cpu)/100 ck,
         any_value(mem_total_gb) mt, avg(mem_used_gb) mu
  FROM w GROUP BY host
)
SELECT
  count(*)                              AS hosts,
  sum(v)                                AS vcpu,
  round(sum(ca),2)                      AS cores_avg,
  round(sum(cp),2)                      AS cores_p95,
  round(sum(cq),2)                      AS cores_p99,
  round(sum(ck),2)                      AS cores_peak,
  round(100*sum(cp)/nullif(sum(v),0),1) AS fleet_util_p95_pct,
  round(sum(mt),1)                      AS mem_total,
  round(sum(mu),1)                      AS mem_avg
FROM per_host;
"
echo
