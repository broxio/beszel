#!/usr/bin/env bash
# duck-report-haproxy.sh — troubleshooting report over the dedicated HAProxy
# DuckDB built by duck-haproxy-ingest.sh (high-resolution per-proxy samples
# recorded by the hub). Honors the project's FRONTEND-only traffic rule at
# query time; backend/server detail is still stored for drill-down.
#
# Two invocation forms (auto-selected by whether arg 1 is a bare integer),
# matching duck-report-capacity.sh:
#   relative:  ./duck-report-haproxy.sh [HOURS] [HOST_GLOB]
#   range:     ./duck-report-haproxy.sh 'FROM' 'TO' [HOST_GLOB]   (timestamps LOCAL, per TZ_OFFSET)
#
# Env:
#   HAPROXY_DUCK_DB  dedicated DuckDB file (default: ./haproxy.duckdb)
#   TZ_OFFSET        local-time offset in hours for peak display + range args (default: 8 = UTC+8)
#   EXCLUDE_PROXY    comma-separated PROXY-name globs to drop from the proxy tables (case-insensitive;
#                    plain names = exact match). Default 'admin,stats' (HAProxy mgmt/stats frontends,
#                    not externally exposed). Filters by proxy name, NOT host — the ha-admin-* host
#                    tier is unaffected. Set EXCLUDE_PROXY='' to include everything.
#   EXCLUDE_HOST     comma-separated HOST globs dropped from the whole report (case-insensitive).
#                    Default 'ha-uat*,ha-pre*' (non-prod zones). Set EXCLUDE_HOST='' to include them,
#                    e.g. EXCLUDE_HOST='' ./duck-report-haproxy.sh 1 'ha-uat*' to inspect UAT.
#
# Examples:
#   ./duck-report-haproxy.sh 1 'ha-bop*'
#   ./duck-report-haproxy.sh '2026-06-01 10:00' '2026-06-01 10:30' 'ha-*'
#   EXCLUDE_PROXY='admin,stats,health' ./duck-report-haproxy.sh 1 'ha-*'   # drop extra mgmt frontends
#   EXCLUDE_PROXY='' ./duck-report-haproxy.sh 1 'ha-*'                      # include admin/stats too

set -euo pipefail

DUCK_DB="${HAPROXY_DUCK_DB:-./haproxy.duckdb}"
TZ_OFFSET="${TZ_OFFSET:-8}"
FORMAT="${FORMAT:-box}"                       # box (pretty) | csv (for Excel/pipe)
case "$FORMAT" in box) FLAG="-box";; csv) FLAG="-csv";; json) FLAG="-json";; *) echo "$(basename "$0"): FORMAT must be box|csv|json (got '$FORMAT')" >&2; exit 1;; esac

command -v duckdb >/dev/null || { echo "duck-report-haproxy.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -f "$DUCK_DB" ]] || { echo "duck-report-haproxy.sh: $DUCK_DB not found (run duck-haproxy-ingest.sh first)" >&2; exit 1; }

OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

# relative [HOURS] vs explicit 'FROM' 'TO' (local), mirrors duck-report-capacity.sh
if [[ "${1:-1}" =~ ^[0-9]+$ ]]; then
  HOURS="${1:-1}"; GLOB="${2:-*}"
  WINDOW_SQL="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"
  WINDOW_LABEL="window=${HOURS}h"
else
  FROM="$1"; TO="${2:-}"; GLOB="${3:-*}"
  [[ -n "$TO" ]] || { echo "duck-report-haproxy.sh: range mode needs FROM and TO" >&2; exit 1; }
  for t in "$FROM" "$TO"; do
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([\ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ]] || \
      { echo "duck-report-haproxy.sh: bad timestamp '$t' (use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM')" >&2; exit 1; }
  done
  WINDOW_SQL="ts >= TIMESTAMP '${FROM}' - INTERVAL '${OFF_MIN} minutes' AND ts < TIMESTAMP '${TO}' - INTERVAL '${OFF_MIN} minutes'"
  WINDOW_LABEL="from='${FROM}' to='${TO}' local${TZLABEL}"
fi

# shell glob -> SQL LIKE (* -> %, ? -> _)
LIKE="${GLOB//\%/\\%}"; LIKE="${LIKE//_/\\_}"; LIKE="${LIKE//\*/%}"; LIKE="${LIKE//\?/_}"

# Exclude mgmt-only frontends (HAProxy stats/admin listeners, not externally exposed) from the
# proxy tables — matched by PROXY name, not host, so the ha-admin-* host tier is unaffected.
# Comma-separated globs (case-insensitive); plain names = exact match. '' disables.
EXCLUDE_PROXY="${EXCLUDE_PROXY-admin,stats}"
EXCL_SQL=""; EXCL_LABEL=""
if [[ -n "$EXCLUDE_PROXY" ]]; then
  conds=()
  IFS=',' read -ra _pats <<<"$EXCLUDE_PROXY"
  for p in "${_pats[@]}"; do
    read -r p <<<"$p"                                              # trim surrounding whitespace
    [[ -z "$p" ]] && continue
    xl="${p//\%/\\%}"; xl="${xl//_/\\_}"; xl="${xl//\*/%}"; xl="${xl//\?/_}"  # glob -> LIKE
    conds+=("proxy ILIKE '${xl}' ESCAPE '\\'")
  done
  if (( ${#conds[@]} )); then
    joined="$(printf ' OR %s' "${conds[@]}")"; joined="${joined# OR }"
    EXCL_SQL=" AND NOT (${joined})"
    EXCL_LABEL="  exclude-proxy=${EXCLUDE_PROXY}"
  fi
fi

# Exclude non-prod host zones (UAT / pre-prod) from the whole report by default.
# Comma-separated host globs (case-insensitive). '' disables (e.g. to inspect ha-uat*).
EXCLUDE_HOST="${EXCLUDE_HOST-ha-uat*,ha-pre*}"
EXCL_HOST_SQL=""; EXCL_HOST_LABEL=""
if [[ -n "$EXCLUDE_HOST" ]]; then
  hconds=()
  IFS=',' read -ra _hpats <<<"$EXCLUDE_HOST"
  for p in "${_hpats[@]}"; do
    read -r p <<<"$p"
    [[ -z "$p" ]] && continue
    hl="${p//\%/\\%}"; hl="${hl//_/\\_}"; hl="${hl//\*/%}"; hl="${hl//\?/_}"
    hconds+=("host ILIKE '${hl}' ESCAPE '\\'")
  done
  if (( ${#hconds[@]} )); then
    hjoined="$(printf ' OR %s' "${hconds[@]}")"; hjoined="${hjoined# OR }"
    EXCL_HOST_SQL=" AND NOT (${hjoined})"
    EXCL_HOST_LABEL="  exclude-host=${EXCLUDE_HOST}"
  fi
fi

# natural host sort: group by alpha prefix, then numeric suffix (ha-bop-2 before ha-bop-10).
# The optional trailing -<letter> handles the spnk node suffix (spnk-ha-lic-1-a, -2-b, ...).
HOST_SORT="regexp_replace(host,'[0-9]+(-[a-z]+)?\$',''), TRY_CAST(regexp_extract(host,'([0-9]+)(-[a-z]+)?\$',1) AS INTEGER) NULLS FIRST"

[[ "$FORMAT" == "box" ]] && { echo; echo "HAProxy troubleshooting (DuckDB) — ${WINDOW_LABEL}  glob=${GLOB}${EXCL_LABEL}${EXCL_HOST_LABEL}  peak-time=local${TZLABEL}  db=${DUCK_DB}"; } || true

# ---- per-frontend traffic & errors (FRONTEND only — no double-count) ----
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH w AS (
  SELECT * FROM haproxy_proxies
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL} AND type = 'FRONTEND' AND ${WINDOW_SQL}${EXCL_SQL}
)
SELECT
  host, proxy,
  count(*)                                                        AS smpl,
  round(avg(req_rate),1)                                          AS req_avg,
  round(quantile_cont(req_rate,0.95),1)                           AS req_p95,
  max(req_rate)                                                   AS req_max,
  strftime(arg_max(ts,req_rate) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS req_max_at,
  max(scur)                                                       AS sess_max,
  round(avg(hrsp_5xx_rate),2)                                     AS e5xx_avg,
  max(hrsp_5xx_rate)                                              AS e5xx_max,
  strftime(arg_max(ts,hrsp_5xx_rate) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS e5xx_max_at,
  round(max(bin_rate)/1e6,2)                                      AS in_mbps_max,
  round(max(bout_rate)/1e6,2)                                     AS out_mbps_max
FROM w
GROUP BY host, proxy
ORDER BY ${HOST_SORT}, proxy;
"

# ---- per-GROUP TOTAL requests + peak throughput (fe_* frontends only) ----
# group = host with trailing -N (and optional -<letter>) stripped (ha-bop-1,ha-bop-2 -> ha-bop;
# spnk-ha-lic-1-a,spnk-ha-lic-2-b -> spnk-ha-lic). total_req from the
# cumulative req_tot counter (max-min per frontend over the window; a HAProxy restart mid-window
# would undercount). GROUP AGGREGATE across nodes: req_avg = sum of per-node avg rates (exact group
# rate); req_peak & out_mbps_max = sum of per-node peaks (envelope — per-node peaks may not coincide);
# max_req_at = when the hottest node peaked. out_mbps_max in megabits/sec.
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH w AS (
  SELECT regexp_replace(host,'-[0-9]+(-[a-z]+)?\$','') AS grp, host, proxy, ts, req_rate, req_tot, bout_rate
  FROM haproxy_proxies
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL} AND type='FRONTEND' AND starts_with(proxy,'fe_') AND ${WINDOW_SQL}
),
per_fe AS (
  SELECT grp, host, proxy, max(req_tot) - min(req_tot) AS reqs FROM w GROUP BY grp, host, proxy
),
tot AS (
  SELECT grp, count(DISTINCT host) AS nodes, count(DISTINCT proxy) AS fe, sum(reqs) AS total_req
  FROM per_fe GROUP BY grp
),
per_host_ts AS (
  SELECT grp, host, ts, sum(req_rate) AS req_h, sum(bout_rate) AS bout_h FROM w GROUP BY grp, host, ts
),
per_host AS (
  SELECT grp, host, avg(req_h) AS req_avg_h, max(req_h) AS req_peak_h, max(bout_h) AS bout_peak_h
  FROM per_host_ts GROUP BY grp, host
),
agg AS (
  SELECT grp,
         round(sum(req_avg_h),1)         AS req_avg,
         sum(req_peak_h)                 AS req_peak,
         round(sum(bout_peak_h)*8/1e6,1) AS out_mbps_max
  FROM per_host GROUP BY grp
),
peak_at AS (
  SELECT grp, strftime(arg_max(ts, req_h) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS max_req_at
  FROM per_host_ts GROUP BY grp
)
SELECT t.grp AS \"group\", t.nodes, t.fe, t.total_req, a.req_avg, a.req_peak, p.max_req_at, a.out_mbps_max
FROM tot t JOIN agg a USING (grp) JOIN peak_at p USING (grp)
ORDER BY regexp_replace(t.grp,'[0-9]+(-[a-z]+)?\$',''), TRY_CAST(regexp_extract(t.grp,'([0-9]+)(-[a-z]+)?\$',1) AS INTEGER) NULLS FIRST, t.grp;
"

# ---- SLOWEST backends / servers (avg response time, ms) — the main signal ----
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH w AS (
  SELECT * FROM haproxy_proxies
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL} AND type IN ('BACKEND','SERVER')
        AND ${WINDOW_SQL} AND rtime > 0${EXCL_SQL}
)
SELECT
  host, proxy, type,
  count(*)                                                          AS smpl,
  round(avg(rtime),1)                                               AS rtime_avg,
  round(quantile_cont(rtime,0.95),1)                                AS rtime_p95,
  max(rtime)                                                        AS rtime_max,
  strftime(arg_max(ts,rtime) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS rtime_max_at,
  round(avg(req_rate),1)                                            AS req_avg,
  max(scur)                                                         AS sess_max
FROM w
GROUP BY host, proxy, type
ORDER BY rtime_p95 DESC, rtime_max DESC
LIMIT 25;
"

# ---- backend / server availability (detect flaps within the window) ----
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH w AS (
  SELECT * FROM haproxy_proxies
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL} AND type IN ('BACKEND','SERVER') AND ${WINDOW_SQL}${EXCL_SQL}
)
SELECT
  host, proxy, type,
  min(act_srv) AS act_min, max(act_srv) AS act_max,
  min(bck_srv) AS bck_min, max(bck_srv) AS bck_max,
  count(DISTINCT status) AS status_states,
  any_value(status)      AS a_status,
  sum(hchk_fail)         AS hchk_fail
FROM w
GROUP BY host, proxy, type
HAVING min(act_srv) <> max(act_srv) OR count(DISTINCT status) > 1 OR sum(hchk_fail) > 0
ORDER BY ${HOST_SORT}, proxy, type;
"

# ---- per-host process health (conn rate, idle %, queue) ----
duckdb -readonly "$FLAG" "$DUCK_DB" "
WITH w AS (
  SELECT * FROM haproxy_info
  WHERE host LIKE '${LIKE}' ESCAPE '\\'${EXCL_HOST_SQL} AND ${WINDOW_SQL}
)
SELECT
  host,
  any_value(version)                  AS version,
  round(avg(conn_rate),1)             AS cps_avg,
  max(conn_rate)                      AS cps_max,
  max(curr_conns)                     AS conns_max,
  round(avg(idle_pct),1)              AS idle_avg,
  min(idle_pct)                       AS idle_min,
  strftime(arg_min(ts,idle_pct) + INTERVAL '${OFF_MIN} minutes','%m-%d %H:%M') AS idle_min_at,
  max(run_queue)                      AS runq_max,
  max(pool_used_mb)                   AS pool_mb_max
FROM w
GROUP BY host
ORDER BY ${HOST_SORT};
"
[[ "$FORMAT" == "box" ]] && echo || true
