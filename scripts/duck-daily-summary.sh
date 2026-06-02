#!/usr/bin/env bash
# duck-daily-summary.sh — one CPU Peak/Average row per reporting "group" for a
# single local day, in the exact order of the ops capacity spreadsheet. Reads the
# capacity DuckDB built by duck-ingest.sh (the `metrics` table: per-host 1-min
# cpu%/mem). Group = a host-name prefix (e.g. ha-bop-1, ha-bop-2 -> group ha-bop).
#
#   Average = mean cpu% over every node's 1-min samples that day (group-wide)
#   Peak    = single highest 1-min cpu% seen on any node in the group (+ which node, when)
#
# Usage:
#   ./duck-daily-summary.sh [DATE]            # DATE = local YYYY-MM-DD (default: yesterday)
#
# Env:
#   DUCK_DB     DuckDB file (default: ./beszel.duckdb)   # in the duck container: /data/beszel.duckdb
#   TZ_OFFSET   local-time offset in hours (default: 8 = UTC+8). Defines the day boundary + peak time.
#   FORMAT      box (default, pretty) | csv (paste into Excel)
#
# Examples:
#   ./duck-daily-summary.sh                       # yesterday, pretty
#   ./duck-daily-summary.sh 2026-06-01            # one specific day
#   FORMAT=csv ./duck-daily-summary.sh 2026-06-01 > 2026-06-01.csv
#   docker compose exec duck-ingest sh -lc \
#     'DUCK_DB=/data/beszel.duckdb FORMAT=csv duck-daily-summary.sh 2026-06-01'
#
# Edit the GROUPS table below to add/rename rows or fix a prefix.

set -euo pipefail

DUCK_DB="${DUCK_DB:-./beszel.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"
FORMAT="${FORMAT:-box}"

command -v duckdb >/dev/null || { echo "duck-daily-summary.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$DUCK_DB" ]] || { echo "duck-daily-summary.sh: $DUCK_DB not found (run duck-ingest.sh first)" >&2; exit 1; }

# ---- DATE arg (local) — default yesterday ----
if [[ -n "${1:-}" ]]; then
  DATE="$1"
else
  if date -v-1d +%F >/dev/null 2>&1; then DATE="$(date -v-1d +%F)"; else DATE="$(date -d 'yesterday' +%F)"; fi
fi
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "duck-daily-summary.sh: bad DATE '$DATE' (use YYYY-MM-DD)" >&2; exit 1; }

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# The local day [DATE 00:00, DATE+1 00:00) converted to the UTC stored in `ts`.
WINDOW_SQL="ts >= TIMESTAMP '${DATE} 00:00' - INTERVAL '${OFF_MIN} minutes'
        AND ts <  TIMESTAMP '${DATE} 00:00' - INTERVAL '${OFF_MIN} minutes' + INTERVAL '1 day'"

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
  echo "beszel daily CPU summary — day=${DATE} local${TZLABEL}  db=${DUCK_DB}"

# LEFT JOIN keeps every group row even when no node reported (nodes=0, blanks),
# so the output always has all 19 rows in spreadsheet order.
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH groups(seq,label,pat) AS (
  ${GROUPS_SQL}
),
w AS (
  SELECT host, cpu, ts FROM metrics WHERE ${WINDOW_SQL}
)
SELECT
  g.seq                                                        AS \"#\",
  g.label                                                      AS group,
  count(DISTINCT m.host)                                       AS nodes,
  round(avg(m.cpu),1)                                          AS cpu_avg,
  round(max(m.cpu),1)                                          AS cpu_peak,
  arg_max(m.host, m.cpu)                                       AS peak_host,
  strftime(arg_max(m.ts, m.cpu) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS peak_at
FROM groups g
LEFT JOIN w m ON m.host LIKE g.pat
GROUP BY g.seq, g.label
ORDER BY g.seq;
"
[[ "$FORMAT" == "box" ]] && echo || true
