#!/usr/bin/env bash
# duck-report-cross.sh — correlate conntrack table pressure with HAProxy errors and
# CPU steal across the THREE dedicated DuckDB stores, joined per-minute on (host,
# minute). Answers "when conntrack filled up, what else was happening on the box?"
#
# All three .duckdb files live in the same /data (the duck services share ./data),
# so this ATTACHes them READ_ONLY into an in-memory DB and joins. conntrack is
# required; haproxy + capacity are optional — their columns are NULL if absent.
#
# Two invocation forms (matching the other reports):
#   relative:  ./duck-report-cross.sh [HOURS] [HOST_GLOB]
#   range:     ./duck-report-cross.sh 'FROM' 'TO' [HOST_GLOB]   (timestamps LOCAL, per TZ_OFFSET)
#
# Env:
#   CONNTRACK_DUCK_DB  conntrack store (default: ./conntrack.duckdb)   [required]
#   HAPROXY_DUCK_DB    HAProxy store   (default: ./haproxy.duckdb)     [optional]
#   DUCK_DB            capacity store  (default: ./beszel.duckdb)      [optional]
#   TZ_OFFSET          local-time offset in hours (default: 8 = UTC+8)
#   EXCLUDE_HOST       comma-separated host globs to drop (default 'ha-uat*,ha-pre*'; '' = all)
#   UTIL_THRESHOLD     conntrack util%% a minute must hit to be a "hot bucket" (default 80)
#
# Examples:
#   ./duck-report-cross.sh 6 'lvs-*'
#   UTIL_THRESHOLD=70 ./duck-report-cross.sh '2026-06-03 09:00' '2026-06-03 12:00' 'ha-bop*'

set -euo pipefail

CT_DB="${CONNTRACK_DUCK_DB:-./conntrack.duckdb}"
HAP_DB="${HAPROXY_DUCK_DB:-./haproxy.duckdb}"
CAP_DB="${DUCK_DB:-./beszel.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"
UTIL_THRESHOLD="${UTIL_THRESHOLD:-80}"

command -v duckdb >/dev/null || { echo "duck-report-cross.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$CT_DB" ]] || { echo "duck-report-cross.sh: $CT_DB not found (conntrack store required)" >&2; exit 1; }
case "$UTIL_THRESHOLD" in ''|*[!0-9]*) echo "duck-report-cross.sh: UTIL_THRESHOLD must be an integer" >&2; exit 1 ;; esac

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# relative [HOURS] vs explicit 'FROM' 'TO' (local)
if [[ "${1:-6}" =~ ^[0-9]+$ ]]; then
  HOURS="${1:-6}"; GLOB="${2:-*}"
  WINDOW_SQL="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"
  WINDOW_LABEL="window=${HOURS}h"
else
  FROM="$1"; TO="${2:-}"; GLOB="${3:-*}"
  [[ -n "$TO" ]] || { echo "duck-report-cross.sh: range mode needs FROM and TO" >&2; exit 1; }
  for t in "$FROM" "$TO"; do
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([\ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]] || \
      { echo "duck-report-cross.sh: bad timestamp '$t' (use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM')" >&2; exit 1; }
  done
  WINDOW_SQL="ts >= TIMESTAMP '${FROM}' - INTERVAL '${OFF_MIN} minutes' AND ts < TIMESTAMP '${TO}' - INTERVAL '${OFF_MIN} minutes'"
  WINDOW_LABEL="from='${FROM}' to='${TO}' local${TZLABEL}"
fi

# shell glob -> SQL LIKE (* -> %, ? -> _)
LIKE="${GLOB//\%/\\%}"; LIKE="${LIKE//_/\\_}"; LIKE="${LIKE//\*/%}"; LIKE="${LIKE//\?/_}"

# Exclude non-prod host zones by default (comma globs, case-insensitive; '' disables).
EXCLUDE_HOST="${EXCLUDE_HOST-ha-uat*,ha-pre*}"
EXCL_HOST_SQL=""
if [[ -n "$EXCLUDE_HOST" ]]; then
  hconds=(); IFS=',' read -ra _hpats <<<"$EXCLUDE_HOST"
  for p in "${_hpats[@]}"; do
    read -r p <<<"$p"; [[ -z "$p" ]] && continue
    hl="${p//\%/\\%}"; hl="${hl//_/\\_}"; hl="${hl//\*/%}"; hl="${hl//\?/_}"
    hconds+=("host ILIKE '${hl}' ESCAPE '\\'")
  done
  (( ${#hconds[@]} )) && { hj="$(printf ' OR %s' "${hconds[@]}")"; EXCL_HOST_SQL=" AND NOT (${hj# OR })"; }
fi

HOST_SORT="regexp_replace(host,'[0-9]+\$',''), TRY_CAST(regexp_extract(host,'([0-9]+)\$',1) AS INTEGER) NULLS FIRST"

# ATTACH conntrack (required) + the optional stores that exist. Build each per-minute
# CTE from the attached table, or an empty typed CTE so the LEFT JOINs still resolve.
ATTACH="ATTACH '${CT_DB}' AS ct (READ_ONLY);"
SRC="conntrack"

if [[ -f "$HAP_DB" ]]; then
  ATTACH+=$'\n'"ATTACH '${HAP_DB}' AS hap (READ_ONLY);"
  HAP_CTE="hap_b AS (
    SELECT host, date_trunc('minute', ts) AS m,
           max(hrsp_5xx_rate) AS e5xx_max, max(scur) AS sess_max
    FROM hap.haproxy_proxies WHERE type='FRONTEND' AND ${WINDOW_SQL} GROUP BY 1,2
  )"
  SRC+="+haproxy"
else
  HAP_CTE="hap_b AS (SELECT NULL::VARCHAR host, NULL::TIMESTAMP m, NULL::UBIGINT e5xx_max, NULL::UBIGINT sess_max WHERE false)"
fi

if [[ -f "$CAP_DB" ]]; then
  ATTACH+=$'\n'"ATTACH '${CAP_DB}' AS cap (READ_ONLY);"
  CAP_CTE="cap_b AS (
    SELECT host, date_trunc('minute', ts) AS m,
           round(avg(cpu),1) AS cpu_avg, round(max(steal),1) AS steal_max
    FROM cap.metrics WHERE ${WINDOW_SQL} GROUP BY 1,2
  )"
  SRC+="+capacity"
else
  CAP_CTE="cap_b AS (SELECT NULL::VARCHAR host, NULL::TIMESTAMP m, NULL::DOUBLE cpu_avg, NULL::DOUBLE steal_max WHERE false)"
fi

echo
echo "cross-correlation (DuckDB) — ${WINDOW_LABEL}  glob=${GLOB}  sources=${SRC}  hot=util>=${UTIL_THRESHOLD}%  time=local${TZLABEL}"
echo "  [1] per-host summary   [2] hot buckets (the minute-by-minute timeline where conntrack util >= ${UTIL_THRESHOLD}%)"

duckdb -box <<SQL
${ATTACH}

-- per-minute join on (host, minute): conntrack drives, haproxy/capacity left-join in.
CREATE TEMP TABLE j AS
WITH ct_b AS (
  SELECT host, date_trunc('minute', ts) AS m,
         max(100.0*conns/nullif(conns_max,0)) AS util_max,
         max(pkt_drop) - min(pkt_drop)         AS drop_delta
  FROM ct.conntrack
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL} AND ${WINDOW_SQL}
  GROUP BY 1,2
),
${HAP_CTE},
${CAP_CTE}
SELECT ct_b.host, ct_b.m, ct_b.util_max, ct_b.drop_delta,
       h.e5xx_max, h.sess_max, c.cpu_avg, c.steal_max
FROM ct_b
LEFT JOIN hap_b h USING (host, m)
LEFT JOIN cap_b c USING (host, m);

-- [1] per-host summary over the window
SELECT
  host,
  round(quantile_cont(util_max,0.95),1) AS ct_util_p95,
  round(max(util_max),1)                AS ct_util_max,
  sum(drop_delta)                       AS ct_drops,
  max(e5xx_max)                         AS e5xx_max,
  max(sess_max)                         AS sess_max,
  round(max(cpu_avg),1)                 AS cpu_max,
  round(max(steal_max),1)               AS steal_max
FROM j
GROUP BY host
ORDER BY ct_util_max DESC NULLS LAST;

-- [2] hot buckets: minutes where conntrack util crossed the threshold, with the
-- concurrent HAProxy 5xx / sessions and CPU steal on the SAME minute.
SELECT
  host,
  strftime(m + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS minute_local,
  round(util_max,1) AS ct_util,
  drop_delta        AS ct_drops,
  e5xx_max,
  sess_max,
  cpu_avg,
  steal_max
FROM j
WHERE util_max >= ${UTIL_THRESHOLD}
ORDER BY ${HOST_SORT}, m;
SQL
echo
