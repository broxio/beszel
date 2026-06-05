#!/usr/bin/env bash
# duck-report-basics.sh — generic per-host "basics" report for EVERY beszel host
# (not just ha-*/lvs-*). Reads the capacity DuckDB built by duck-ingest.sh (the
# `metrics` table). Shows CPU, load avg, memory, disk usage, disk IO (throughput +
# io-util%), network bandwidth, and — when a conntrack store is present — netfilter
# conntrack table utilization. Auto-groups hosts by name (ha-bop-1, ha-bop-2 -> ha-bop).
#
# Output is standardized for machine consumption: FORMAT=json emits a clean array of
# host (or group) objects suitable for an HTTP endpoint / AI agent to parse verbatim.
#
# Usage (same window args as duck-report-capacity.sh):
#   ./duck-report-basics.sh [HOURS] [HOST_GLOB]            # relative: last N hours (default 24)
#   ./duck-report-basics.sh 'FROM' 'TO' [HOST_GLOB]        # explicit range (LOCAL time, per TZ_OFFSET)
#
# Views:
#   VIEW=host  (default) — one row per host, sorted so group members are adjacent
#   VIEW=group           — one row per host-name group (rollup of the host rows)
#
# Env:
#   DUCK_DB           capacity DuckDB file (default: ./beszel.duckdb)
#   CONNTRACK_DUCK_DB conntrack DuckDB to join for ct_util (default: <DUCK_DB dir>/conntrack.duckdb
#                     if it exists; else conntrack columns are NULL). A host only has
#                     conntrack data if nf_conntrack is loaded (iptables/netfilter).
#   FORMAT            box (default) | csv | json
#   VIEW              host (default) | group
#   TZ_OFFSET         local-time offset in hours for FROM/TO range args (default: 8)
#   EXCLUDE_HOST      comma-separated host globs dropped (case-insensitive).
#                     Default 'ha-uat*,ha-pre*'; EXCLUDE_HOST='' includes everything.
#
# Examples:
#   ./duck-report-basics.sh 6 '*'
#   FORMAT=json ./duck-report-basics.sh 24 '*' | jq .
#   VIEW=group FORMAT=json ./duck-report-basics.sh 168 'ha-*'
#
# Note: beszel does not expose true disk IOPS (ops/sec). The disk-pressure signals
# here are throughput (disk_read/write_mb_s) and io_util_p95 (% of time the device
# was busy), both straight from the agent's stats.

set -euo pipefail

DUCK_DB="${DUCK_DB:-./beszel.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"
FORMAT="${FORMAT:-box}"                        # box (pretty) | csv | json
VIEW="${VIEW:-host}"                           # host | group

case "$FORMAT" in
  box)  FLAG="-box" ;;
  csv)  FLAG="-csv" ;;
  json) FLAG="-json" ;;
  *) echo "duck-report-basics.sh: FORMAT must be box|csv|json (got '$FORMAT')" >&2; exit 1 ;;
esac
case "$VIEW" in host|group) ;; *) echo "duck-report-basics.sh: VIEW must be host|group (got '$VIEW')" >&2; exit 1 ;; esac

command -v duckdb >/dev/null || { echo "duck-report-basics.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$DUCK_DB" ]] || { echo "duck-report-basics.sh: $DUCK_DB not found (run duck-ingest.sh first)" >&2; exit 1; }

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# Two invocation forms (decided by whether arg 1 is a bare integer):
#   relative:  duck-report-basics.sh [HOURS] [HOST_GLOB]
#   range:     duck-report-basics.sh 'FROM' 'TO' [HOST_GLOB]   (timestamps are LOCAL, per TZ_OFFSET)
if [[ "${1:-24}" =~ ^[0-9]+$ ]]; then
  HOURS="${1:-24}"; GLOB="${2:-*}"
  WINDOW_SQL="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"
  WINDOW_LABEL="window=${HOURS}h"
else
  FROM="$1"; TO="${2:-}"; GLOB="${3:-*}"
  [[ -n "$TO" ]] || { echo "duck-report-basics.sh: range mode needs FROM and TO, e.g. '2026-05-30 09:00' '2026-05-30 17:00'" >&2; exit 1; }
  for t in "$FROM" "$TO"; do
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([\ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]] || \
      { echo "duck-report-basics.sh: bad timestamp '$t' (use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM')" >&2; exit 1; }
  done
  WINDOW_SQL="ts >= TIMESTAMP '${FROM}' - INTERVAL '${OFF_MIN} minutes' AND ts < TIMESTAMP '${TO}' - INTERVAL '${OFF_MIN} minutes'"
  WINDOW_LABEL="from='${FROM}' to='${TO}' local${TZLABEL}"
fi

# shell glob -> SQL LIKE (* -> %, ? -> _)
LIKE="${GLOB//\%/\\%}"; LIKE="${LIKE//_/\\_}"; LIKE="${LIKE//\*/%}"; LIKE="${LIKE//\?/_}"

# Exclude non-prod host zones by default (comma-separated globs, case-insensitive; '' disables).
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

# Optional conntrack store: default to a sibling conntrack.duckdb if present.
CONNTRACK_DUCK_DB="${CONNTRACK_DUCK_DB-$(dirname "$DUCK_DB")/conntrack.duckdb}"
ATTACH=""; CT_CTE=""; CT_JOIN=""; CT_COL="NULL AS ct_util_p95"
if [[ -n "${CONNTRACK_DUCK_DB:-}" && -f "$CONNTRACK_DUCK_DB" ]]; then
  ATTACH="ATTACH '${CONNTRACK_DUCK_DB}' AS ct (READ_ONLY);"
  CT_CTE="ct_per_host AS (
    SELECT host,
           round(quantile_cont(100.0*conns/nullif(conns_max,0),0.95),1) AS ct_util_p95
    FROM ct.conntrack
    WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL}
      AND ${WINDOW_SQL}
    GROUP BY host
  ),"
  CT_JOIN="LEFT JOIN ct_per_host USING (host)"
  CT_COL="ct_per_host.ct_util_p95"
fi

# Schema tolerance: the disk/IO/load columns are added by duck-ingest.sh's ALTER
# migration. If this report runs against a metrics table that hasn't been widened
# yet (ingest not upgraded/cycled), reference NULL instead so it still works (those
# fields just read empty) — same graceful-degradation as the optional conntrack join.
COLS="$(duckdb -readonly -noheader -list "$DUCK_DB" \
  "SELECT column_name FROM information_schema.columns WHERE table_name='metrics';")"
col_or_null() { if grep -qxF "$1" <<<"$COLS"; then printf '%s' "$1"; else printf 'CAST(NULL AS DOUBLE)'; fi; }
C_LOAD1="$(col_or_null load1)"
C_DISK_PCT="$(col_or_null disk_pct)"
C_DISK_USED="$(col_or_null disk_used_gb)"
C_IO_UTIL="$(col_or_null io_util)"
C_DREAD="$(col_or_null disk_read_bps)"
C_DWRITE="$(col_or_null disk_write_bps)"

# Header only for human (box) output; csv/json stay clean for machine consumption.
[[ "$FORMAT" == "box" ]] && { echo; echo "beszel host basics (DuckDB) — view=${VIEW}  ${WINDOW_LABEL}  glob=${GLOB}${EXCL_HOST_LABEL}  db=${DUCK_DB}"; } || true

# per_host: one tidy row per host (the building block for both views).
COMMON_CTES="
WITH w AS (
  SELECT * FROM metrics
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL}
    AND ${WINDOW_SQL}
),
${CT_CTE}
per_host AS (
  SELECT
    host,
    regexp_replace(host,'-?[0-9]+\$','')                  AS host_group,
    count(*)                                              AS sampl,
    round(avg(cpu),1)                                     AS cpu_avg,
    round(quantile_cont(cpu,0.95),1)                      AS cpu_p95,
    round(max(cpu),1)                                     AS cpu_peak,
    round(max(steal),1)                                   AS steal,
    round(avg(${C_LOAD1}),2)                              AS load1_avg,
    round(quantile_cont(${C_LOAD1},0.95),2)               AS load1_p95,
    round(avg(mem_pct),1)                                 AS mem_pct_avg,
    round(quantile_cont(mem_pct,0.95),1)                  AS mem_pct_p95,
    round(max(mem_used_gb),1)                             AS mem_used_gb_peak,
    round(any_value(mem_total_gb),1)                      AS mem_total_gb,
    round(arg_max(${C_DISK_PCT},ts),1)                    AS disk_pct,
    round(arg_max(${C_DISK_USED},ts),1)                   AS disk_used_gb,
    round(quantile_cont(${C_IO_UTIL},0.95),1)             AS io_util_p95,
    round(quantile_cont(${C_DREAD},0.95),2)               AS disk_read_mb_s,
    round(quantile_cont(${C_DWRITE},0.95),2)              AS disk_write_mb_s,
    round(quantile_cont(net_in_bps,0.95)/1e6,2)           AS net_in_mb_s,
    round(quantile_cont(net_out_bps,0.95)/1e6,2)          AS net_out_mb_s
  FROM w GROUP BY host
),
host_rows AS (
  SELECT per_host.*, ${CT_COL}
  FROM per_host ${CT_JOIN}
)"

if [[ "$VIEW" == "host" ]]; then
  SQL="${COMMON_CTES}
SELECT host, host_group, sampl,
       cpu_avg, cpu_p95, cpu_peak, steal,
       load1_avg, load1_p95,
       mem_pct_avg, mem_pct_p95, mem_used_gb_peak, mem_total_gb,
       disk_pct, disk_used_gb,
       io_util_p95, disk_read_mb_s, disk_write_mb_s,
       net_in_mb_s, net_out_mb_s,
       ct_util_p95
FROM host_rows
ORDER BY host_group,
         TRY_CAST(regexp_extract(host,'([0-9]+)\$',1) AS INTEGER) NULLS FIRST,
         host;"
else
  SQL="${COMMON_CTES}
SELECT host_group,
       count(*)                          AS nodes,
       sum(sampl)                        AS sampl,
       round(avg(cpu_p95),1)             AS cpu_p95_avg,
       round(max(cpu_peak),1)            AS cpu_peak,
       round(max(steal),1)              AS steal,
       round(max(load1_p95),2)           AS load1_p95_max,
       round(avg(mem_pct_p95),1)         AS mem_pct_p95_avg,
       round(sum(mem_used_gb_peak),1)    AS mem_used_gb,
       round(sum(mem_total_gb),1)        AS mem_total_gb,
       round(avg(disk_pct),1)            AS disk_pct_avg,
       round(max(io_util_p95),1)         AS io_util_p95_max,
       round(sum(disk_read_mb_s),2)      AS disk_read_mb_s,
       round(sum(disk_write_mb_s),2)     AS disk_write_mb_s,
       round(sum(net_in_mb_s),2)         AS net_in_mb_s,
       round(sum(net_out_mb_s),2)        AS net_out_mb_s,
       round(max(ct_util_p95),1)         AS ct_util_p95_max
FROM host_rows
GROUP BY host_group
ORDER BY host_group;"
fi

duckdb -readonly "$FLAG" "$DUCK_DB" "${ATTACH}
${SQL}"

[[ "$FORMAT" == "box" ]] && echo || true
