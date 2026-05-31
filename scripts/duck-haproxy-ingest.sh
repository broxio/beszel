#!/usr/bin/env bash
# duck-haproxy-ingest.sh — load the hub's HAProxy NDJSON spool into a dedicated
# DuckDB for troubleshooting. The hub (HAPROXY_DUCK_SPOOL set) writes
# daily-rotated spool files; this loader ingests them with PRIMARY-KEY dedup, so
# re-running is idempotent. Pairs with duck-haproxy-report.sh.
#
# Two tables:
#   haproxy_proxies  — one row per frontend/backend/server per sample, PK (system, ts, proxy, type)
#   haproxy_info     — one row per host per sample (process info),       PK (system, ts)
#
# After ingest, spool files OLDER than today (the hub only ever appends to
# today's file) are moved to <spool>/ingested/ so subsequent runs only re-scan
# today's file. Today's file is re-scanned each run; dedup drops what's already in.
#
# Usage:
#   ./duck-haproxy-ingest.sh
#
# Env (optional):
#   HAPROXY_DUCK_DB         dedicated DuckDB file (default: ./haproxy.duckdb)
#   HAPROXY_SPOOL_DIR       spool dir written by the hub (default: ./haproxy-spool)
#   HAPROXY_RETENTION_DAYS  if set, DELETE rows older than N days + prune ingested/ files
#
# Cron (every 5 min):
#   */5 * * * * HAPROXY_DUCK_DB=/data/haproxy.duckdb HAPROXY_SPOOL_DIR=/data/haproxy-spool \
#               /path/duck-haproxy-ingest.sh >> /var/log/haproxy-duck.log 2>&1

set -euo pipefail

DUCK_DB="${HAPROXY_DUCK_DB:-./haproxy.duckdb}"
SPOOL_DIR="${HAPROXY_SPOOL_DIR:-./haproxy-spool}"
RETENTION_DAYS="${HAPROXY_RETENTION_DAYS:-}"      # DuckDB row retention (optional)
SPOOL_KEEP_DAYS="${HAPROXY_SPOOL_KEEP_DAYS:-2}"   # archived NDJSON kept as a safety buffer; redundant with the DB

command -v duckdb >/dev/null || { echo "duck-haproxy-ingest.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -d "$SPOOL_DIR" ]] || { echo "duck-haproxy-ingest.sh: spool dir not found: $SPOOL_DIR" >&2; exit 1; }
if [[ -n "$RETENTION_DAYS" ]]; then
  case "$RETENTION_DAYS" in ''|*[!0-9]*) echo "duck-haproxy-ingest.sh: HAPROXY_RETENTION_DAYS must be an integer" >&2; exit 1 ;; esac
fi
case "$SPOOL_KEEP_DAYS" in ''|*[!0-9]*) echo "duck-haproxy-ingest.sh: HAPROXY_SPOOL_KEEP_DAYS must be an integer" >&2; exit 1 ;; esac

TODAY="$(date -u +%Y%m%d)"
mkdir -p "$(dirname "$DUCK_DB")" "$SPOOL_DIR/ingested"

# Top-level glob only (does NOT descend into ingested/). nullglob so an empty
# match yields an empty array rather than the literal pattern.
shopt -s nullglob
PROXY_FILES=("$SPOOL_DIR"/haproxy_proxies-*.ndjson)
INFO_FILES=("$SPOOL_DIR"/haproxy_info-*.ndjson)
shopt -u nullglob

if (( ${#PROXY_FILES[@]} == 0 && ${#INFO_FILES[@]} == 0 )); then
  echo "($(date -u +%H:%M) no spool files in $SPOOL_DIR)"; exit 0
fi

PROXY_GLOB="$SPOOL_DIR/haproxy_proxies-*.ndjson"
INFO_GLOB="$SPOOL_DIR/haproxy_info-*.ndjson"

duckdb "$DUCK_DB" <<SQL
CREATE TABLE IF NOT EXISTS haproxy_proxies (
  ts            TIMESTAMP,
  system        VARCHAR,
  host          VARCHAR,
  proxy         VARCHAR,
  type          VARCHAR,
  status        VARCHAR,
  scur          UBIGINT,
  smax          UBIGINT,
  slim          UBIGINT,
  stot          UBIGINT,
  bin           UBIGINT,
  bout          UBIGINT,
  bin_rate      UBIGINT,
  bout_rate     UBIGINT,
  req_rate      UBIGINT,
  req_tot       UBIGINT,
  rtime         UBIGINT,
  hrsp_1xx      UBIGINT,
  hrsp_2xx      UBIGINT,
  hrsp_3xx      UBIGINT,
  hrsp_4xx      UBIGINT,
  hrsp_5xx      UBIGINT,
  hrsp_1xx_rate UBIGINT,
  hrsp_2xx_rate UBIGINT,
  hrsp_3xx_rate UBIGINT,
  hrsp_4xx_rate UBIGINT,
  hrsp_5xx_rate UBIGINT,
  hchk_fail     UBIGINT,
  act_srv       UBIGINT,
  bck_srv       UBIGINT,
  PRIMARY KEY (system, ts, proxy, type)
);

CREATE TABLE IF NOT EXISTS haproxy_info (
  ts             TIMESTAMP,
  system         VARCHAR,
  host           VARCHAR,
  version        VARCHAR,
  uptime_sec     UBIGINT,
  maxconn        UBIGINT,
  nbthread       UBIGINT,
  curr_conns     UBIGINT,
  cum_conns      UBIGINT,
  cum_req        UBIGINT,
  conn_rate      UBIGINT,
  max_conn_rate  UBIGINT,
  sess_rate      UBIGINT,
  max_sess_rate  UBIGINT,
  curr_ssl_conns UBIGINT,
  ssl_rate       UBIGINT,
  tasks          UBIGINT,
  run_queue      UBIGINT,
  idle_pct       UBIGINT,
  pool_alloc_mb  UBIGINT,
  pool_used_mb   UBIGINT,
  mem_max_mb     UBIGINT,
  bytes_out_tot  UBIGINT,
  bytes_out_rate UBIGINT,
  PRIMARY KEY (system, ts)
);

INSERT INTO haproxy_proxies
  SELECT ts, system, host, proxy, type, status, scur, smax, slim, stot, bin, bout,
         bin_rate, bout_rate, req_rate, req_tot, rtime,
         hrsp_1xx, hrsp_2xx, hrsp_3xx, hrsp_4xx, hrsp_5xx,
         hrsp_1xx_rate, hrsp_2xx_rate, hrsp_3xx_rate, hrsp_4xx_rate, hrsp_5xx_rate,
         hchk_fail, act_srv, bck_srv
  FROM read_json_auto('${PROXY_GLOB}', format='newline_delimited', union_by_name=true)
  ON CONFLICT DO NOTHING;

INSERT INTO haproxy_info
  SELECT ts, system, host, version, uptime_sec, maxconn, nbthread, curr_conns, cum_conns,
         cum_req, conn_rate, max_conn_rate, sess_rate, max_sess_rate, curr_ssl_conns,
         ssl_rate, tasks, run_queue, idle_pct, pool_alloc_mb, pool_used_mb, mem_max_mb,
         bytes_out_tot, bytes_out_rate
  FROM read_json_auto('${INFO_GLOB}', format='newline_delimited', union_by_name=true)
  ON CONFLICT DO NOTHING;

SELECT '$(date -u +%H:%M) haproxy_proxies=' || (SELECT count(*) FROM haproxy_proxies) ||
       ' rows / ' || (SELECT count(DISTINCT host) FROM haproxy_proxies) || ' hosts, span ' ||
       (SELECT coalesce(strftime(min(ts),'%Y-%m-%d %H:%M'),'-') FROM haproxy_proxies) || ' .. ' ||
       (SELECT coalesce(strftime(max(ts),'%Y-%m-%d %H:%M'),'-') FROM haproxy_proxies) || ' UTC' AS status;
SQL

# Archive fully-closed spool files (date < today); the hub only appends to today's.
moved=0
for f in "${PROXY_FILES[@]}" "${INFO_FILES[@]}"; do
  base="$(basename "$f")"
  fdate="${base##*-}"; fdate="${fdate%.ndjson}"
  if [[ "$fdate" =~ ^[0-9]{8}$ && "$fdate" < "$TODAY" ]]; then
    mv -f "$f" "$SPOOL_DIR/ingested/"; moved=$((moved+1))
  fi
done
(( moved > 0 )) && echo "archived $moved closed spool file(s) to $SPOOL_DIR/ingested/"

# Prune the archive aggressively: once a file is in the DB it's redundant, so the
# raw NDJSON is just a short safety buffer. Decoupled from DB retention so the
# spool dir stays small even with a long DB history.
find "$SPOOL_DIR/ingested" -name '*.ndjson' -mtime +"${SPOOL_KEEP_DAYS}" -delete 2>/dev/null || true

# DuckDB row retention (optional, separate knob — the compact, long-term store).
if [[ -n "$RETENTION_DAYS" ]]; then
  duckdb "$DUCK_DB" <<SQL
DELETE FROM haproxy_proxies WHERE ts < (now() AT TIME ZONE 'UTC') - INTERVAL '${RETENTION_DAYS} days';
DELETE FROM haproxy_info    WHERE ts < (now() AT TIME ZONE 'UTC') - INTERVAL '${RETENTION_DAYS} days';
SQL
fi
