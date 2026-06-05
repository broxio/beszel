#!/usr/bin/env bash
# duck-haproxy-ingest.sh — load the hub's SEALED HAProxy spool files into a
# dedicated DuckDB, then DELETE them. Gap-free by design: the hub writes a single
# "<prefix>.live.ndjson" and seals it every HAPROXY_SPOOL_ROTATE into a complete
# "<prefix>-<stamp>-<seq>.ndjson". The hub never touches a sealed file again, so
# this loader can ingest sealed files and remove them with zero data loss. The
# live file (still being appended) is ignored and picked up after its next seal.
#
# Two tables:
#   haproxy_proxies  PK (system, ts, proxy, type)   — per frontend/backend/server sample
#   haproxy_info     PK (system, ts)                — per-host process info
# ON CONFLICT DO NOTHING makes a crash between ingest and delete harmless.
#
# Usage: ./duck-haproxy-ingest.sh
#
# Env (optional):
#   HAPROXY_DUCK_DB         dedicated DuckDB file (default: ./haproxy.duckdb)
#   HAPROXY_SPOOL_DIR       spool dir written by the hub (default: ./haproxy-spool)
#   HAPROXY_RETENTION_DAYS  if set, DELETE DB rows older than N days (compact long-term store)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/duck-lib.sh"

DUCK_DB="${HAPROXY_DUCK_DB:-./haproxy.duckdb}"
SPOOL_DIR="${HAPROXY_SPOOL_DIR:-./haproxy-spool}"
RETENTION_DAYS="${HAPROXY_RETENTION_DAYS:-}"
ARCHIVE_DIR="${HAPROXY_ARCHIVE_DIR:-}"

command -v duckdb >/dev/null || { echo "duck-haproxy-ingest.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -d "$SPOOL_DIR" ]] || { echo "duck-haproxy-ingest.sh: spool dir not found: $SPOOL_DIR" >&2; exit 1; }
if [[ -n "$RETENTION_DAYS" ]]; then
  case "$RETENTION_DAYS" in ''|*[!0-9]*) echo "duck-haproxy-ingest.sh: HAPROXY_RETENTION_DAYS must be an integer" >&2; exit 1 ;; esac
fi
# Cap files processed per run so a backlog (e.g. after a misconfig) drains in bounded
# batches instead of one giant transaction/CPU spike. Steady state (~1 sealed/min) is
# well under this; 0 = unlimited.
MAX_FILES="${HAPROXY_MAX_FILES:-60}"
case "$MAX_FILES" in ''|*[!0-9]*) echo "duck-haproxy-ingest.sh: HAPROXY_MAX_FILES must be an integer" >&2; exit 1 ;; esac

mkdir -p "$(dirname "$DUCK_DB")"

# Sealed files only. "<prefix>-*.ndjson" matches sealed files; the live file
# "<prefix>.live.ndjson" has no '-' after the prefix, so it is excluded.
# nullglob => empty match yields an empty array, not the literal pattern.
shopt -s nullglob
PROXY_FILES=("$SPOOL_DIR"/haproxy_proxies-*.ndjson)
INFO_FILES=("$SPOOL_DIR"/haproxy_info-*.ndjson)
shopt -u nullglob

# Process oldest-first (lexical sort = chronological for the <stamp>-<seq> names),
# capped to MAX_FILES per run. Anything beyond is left for the next cycle.
cap_oldest() {
  (( $# == 0 )) && return 0                       # no files -> emit nothing (empty array)
  if (( MAX_FILES == 0 )); then printf '%s\n' "$@"; else printf '%s\n' "$@" | sort | head -n "$MAX_FILES"; fi
}
mapfile -t PROXY_FILES < <(cap_oldest "${PROXY_FILES[@]}")
mapfile -t INFO_FILES  < <(cap_oldest "${INFO_FILES[@]}")

if (( ${#PROXY_FILES[@]} == 0 && ${#INFO_FILES[@]} == 0 )); then
  echo "($(date -u +%H:%M) no sealed spool files in $SPOOL_DIR)"; exit 0
fi

# Build a DuckDB list literal ['a','b',...] from the captured file list. We ingest
# EXACTLY these files and delete EXACTLY these files, so anything sealed during the
# run is left for the next cycle (never deleted un-ingested).
duck_list() {
  local out="" f
  for f in "$@"; do out+="'${f}',"; done
  printf '[%s]' "${out%,}"
}

SQL="
CREATE TABLE IF NOT EXISTS haproxy_proxies (
  ts TIMESTAMP, system VARCHAR, host VARCHAR, proxy VARCHAR, type VARCHAR, status VARCHAR,
  scur UBIGINT, smax UBIGINT, slim UBIGINT, stot UBIGINT, bin UBIGINT, bout UBIGINT,
  bin_rate UBIGINT, bout_rate UBIGINT, req_rate UBIGINT, req_tot UBIGINT, rtime UBIGINT,
  hrsp_1xx UBIGINT, hrsp_2xx UBIGINT, hrsp_3xx UBIGINT, hrsp_4xx UBIGINT, hrsp_5xx UBIGINT,
  hrsp_1xx_rate UBIGINT, hrsp_2xx_rate UBIGINT, hrsp_3xx_rate UBIGINT, hrsp_4xx_rate UBIGINT,
  hrsp_5xx_rate UBIGINT, hchk_fail UBIGINT, act_srv UBIGINT, bck_srv UBIGINT,
  PRIMARY KEY (system, ts, proxy, type)
);
CREATE TABLE IF NOT EXISTS haproxy_info (
  ts TIMESTAMP, system VARCHAR, host VARCHAR, version VARCHAR, uptime_sec UBIGINT,
  maxconn UBIGINT, nbthread UBIGINT, curr_conns UBIGINT, cum_conns UBIGINT, cum_req UBIGINT,
  conn_rate UBIGINT, max_conn_rate UBIGINT, sess_rate UBIGINT, max_sess_rate UBIGINT,
  curr_ssl_conns UBIGINT, ssl_rate UBIGINT, tasks UBIGINT, run_queue UBIGINT, idle_pct UBIGINT,
  pool_alloc_mb UBIGINT, pool_used_mb UBIGINT, mem_max_mb UBIGINT, bytes_out_tot UBIGINT,
  bytes_out_rate UBIGINT,
  PRIMARY KEY (system, ts)
);
"

if (( ${#PROXY_FILES[@]} > 0 )); then
  SQL+="
INSERT INTO haproxy_proxies
  SELECT ts, system, host, proxy, type, status, scur, smax, slim, stot, bin, bout,
         bin_rate, bout_rate, req_rate, req_tot, rtime,
         hrsp_1xx, hrsp_2xx, hrsp_3xx, hrsp_4xx, hrsp_5xx,
         hrsp_1xx_rate, hrsp_2xx_rate, hrsp_3xx_rate, hrsp_4xx_rate, hrsp_5xx_rate,
         hchk_fail, act_srv, bck_srv
  FROM read_json_auto($(duck_list "${PROXY_FILES[@]}"), format='newline_delimited', union_by_name=true)
  ON CONFLICT DO NOTHING;
"
fi

if (( ${#INFO_FILES[@]} > 0 )); then
  SQL+="
INSERT INTO haproxy_info
  SELECT ts, system, host, version, uptime_sec, maxconn, nbthread, curr_conns, cum_conns,
         cum_req, conn_rate, max_conn_rate, sess_rate, max_sess_rate, curr_ssl_conns,
         ssl_rate, tasks, run_queue, idle_pct, pool_alloc_mb, pool_used_mb, mem_max_mb,
         bytes_out_tot, bytes_out_rate
  FROM read_json_auto($(duck_list "${INFO_FILES[@]}"), format='newline_delimited', union_by_name=true)
  ON CONFLICT DO NOTHING;
"
fi

SQL+="
SELECT '$(date -u +%H:%M) ingested ' || ${#PROXY_FILES[@]} || ' proxy + ' || ${#INFO_FILES[@]} ||
       ' info file(s); haproxy_proxies=' || (SELECT count(*) FROM haproxy_proxies) || ' rows / ' ||
       (SELECT count(DISTINCT host) FROM haproxy_proxies) || ' hosts, span ' ||
       (SELECT coalesce(strftime(min(ts),'%Y-%m-%d %H:%M'),'-') FROM haproxy_proxies) || ' .. ' ||
       (SELECT coalesce(strftime(max(ts),'%Y-%m-%d %H:%M'),'-') FROM haproxy_proxies) || ' UTC' AS status;
"

# Ingest. Only delete the spool files if DuckDB succeeded (else retry next run;
# ON CONFLICT keeps re-ingest idempotent).
if duckdb "$DUCK_DB" "$SQL"; then
  rm -f "${PROXY_FILES[@]}" "${INFO_FILES[@]}"
else
  echo "duck-haproxy-ingest.sh: ingest failed; leaving sealed files for retry" >&2
  exit 1
fi

# Cold-tier retention (shared helper) — the compact long-term store, independent of
# the spool (emptied every run). Both tables age out after RETENTION_DAYS; with
# HAPROXY_ARCHIVE_DIR each expiring day is archived to Parquet first.
# NOTE: haproxy_proxies is high-volume — archiving it can write large daily Parquet
# files; leave HAPROXY_ARCHIVE_DIR empty to hard-delete instead.
duck_archive_prune "$DUCK_DB" "$ARCHIVE_DIR" "$RETENTION_DAYS" haproxy_proxies haproxy_info
