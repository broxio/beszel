#!/usr/bin/env bash
# duck-report-conntrack.sh — netfilter conntrack troubleshooting report over the
# dedicated DuckDB built by duck-conntrack-ingest.sh (high-resolution per-host
# samples recorded by the hub). The headline signal is table utilization
# (conns / conns_max); the cumulative drop counters (pkt_drop / insert_failed /
# early_drop) show whether the table actually overflowed in the window.
#
# Two invocation forms (auto-selected by whether arg 1 is a bare integer),
# matching duck-report-haproxy.sh:
#   relative:  ./duck-report-conntrack.sh [HOURS] [HOST_GLOB]
#   range:     ./duck-report-conntrack.sh 'FROM' 'TO' [HOST_GLOB]   (timestamps LOCAL, per TZ_OFFSET)
#
# Env:
#   CONNTRACK_DUCK_DB  dedicated DuckDB file (default: ./conntrack.duckdb)
#   TZ_OFFSET          local-time offset in hours for peak display + range args (default: 8 = UTC+8)
#   EXCLUDE_HOST       comma-separated host globs to drop (default 'ha-uat*,ha-pre*'; '' = all)
#
# Examples:
#   ./duck-report-conntrack.sh 6 'lvs-*'
#   ./duck-report-conntrack.sh '2026-06-02 13:00' '2026-06-02 19:00' 'ha-bop*'

set -euo pipefail

DUCK_DB="${CONNTRACK_DUCK_DB:-./conntrack.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"
FORMAT="${FORMAT:-box}"                       # box (pretty) | csv (for Excel/pipe)
case "$FORMAT" in box) FLAG="-box";; csv) FLAG="-csv";; json) FLAG="-json";; *) echo "$(basename "$0"): FORMAT must be box|csv|json (got '$FORMAT')" >&2; exit 1;; esac

command -v duckdb >/dev/null || { echo "duck-report-conntrack.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$DUCK_DB" ]] || { echo "duck-report-conntrack.sh: $DUCK_DB not found (run duck-conntrack-ingest.sh first)" >&2; exit 1; }

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# relative [HOURS] vs explicit 'FROM' 'TO' (local), mirrors duck-report-haproxy.sh
if [[ "${1:-6}" =~ ^[0-9]+$ ]]; then
  HOURS="${1:-6}"; GLOB="${2:-*}"
  WINDOW_SQL="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"
  WINDOW_LABEL="window=${HOURS}h"
else
  FROM="$1"; TO="${2:-}"; GLOB="${3:-*}"
  [[ -n "$TO" ]] || { echo "duck-report-conntrack.sh: range mode needs FROM and TO" >&2; exit 1; }
  for t in "$FROM" "$TO"; do
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([\ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]] || \
      { echo "duck-report-conntrack.sh: bad timestamp '$t' (use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM')" >&2; exit 1; }
  done
  WINDOW_SQL="ts >= TIMESTAMP '${FROM}' - INTERVAL '${OFF_MIN} minutes' AND ts < TIMESTAMP '${TO}' - INTERVAL '${OFF_MIN} minutes'"
  WINDOW_LABEL="from='${FROM}' to='${TO}' local${TZLABEL}"
fi

# shell glob -> SQL LIKE (* -> %, ? -> _)
LIKE="${GLOB//\%/\\%}"; LIKE="${LIKE//_/\\_}"; LIKE="${LIKE//\*/%}"; LIKE="${LIKE//\?/_}"

# Exclude non-prod host zones by default (comma globs, case-insensitive; '' disables).
EXCLUDE_HOST="${EXCLUDE_HOST-ha-uat*,ha-pre*}"
EXCL_HOST_SQL=""; EXCL_HOST_LABEL=""
if [[ -n "$EXCLUDE_HOST" ]]; then
  hconds=(); IFS=',' read -ra _hpats <<<"$EXCLUDE_HOST"
  for p in "${_hpats[@]}"; do
    read -r p <<<"$p"; [[ -z "$p" ]] && continue
    hl="${p//\%/\\%}"; hl="${hl//_/\\_}"; hl="${hl//\*/%}"; hl="${hl//\?/_}"
    hconds+=("host ILIKE '${hl}' ESCAPE '\\'")
  done
  (( ${#hconds[@]} )) && { hj="$(printf ' OR %s' "${hconds[@]}")"; EXCL_HOST_SQL=" AND NOT (${hj# OR })"; EXCL_HOST_LABEL="  exclude-host=${EXCLUDE_HOST}"; }
fi

HOST_SORT="regexp_replace(host,'[0-9]+\$',''), TRY_CAST(regexp_extract(host,'([0-9]+)\$',1) AS INTEGER) NULLS FIRST"

[[ "$FORMAT" == "box" ]] && { echo; echo "conntrack troubleshooting (DuckDB) — ${WINDOW_LABEL}  glob=${GLOB}${EXCL_HOST_LABEL}  peak-time=local${TZLABEL}  db=${DUCK_DB}"; } || true

# ---- per-host table utilization + drops ----
# util_pct = 100*conns/conns_max (the headline). Drop counters are cumulative, so
# the in-window delta (max-min) is how many packets/inserts were dropped during it.
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH w AS (
  SELECT * FROM conntrack
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL} AND ${WINDOW_SQL}
)
SELECT
  host,
  count(*)                                                          AS smpl,
  max(conns_max)                                                    AS conns_max,
  round(avg(conns),0)                                               AS conns_avg,
  max(conns)                                                        AS conns_peak,
  round(avg(100.0*conns/nullif(conns_max,0)),1)                     AS util_avg_pct,
  round(quantile_cont(100.0*conns/nullif(conns_max,0),0.95),1)      AS util_p95_pct,
  round(max(100.0*conns/nullif(conns_max,0)),1)                     AS util_max_pct,
  strftime(arg_max(ts, conns) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS peak_at,
  max(pkt_drop)      - min(pkt_drop)                                AS drops,
  max(insert_failed) - min(insert_failed)                           AS insert_fail,
  max(early_drop)    - min(early_drop)                              AS early_drops
FROM w
GROUP BY host
ORDER BY ${HOST_SORT};
"
[[ "$FORMAT" == "box" ]] && echo || true
