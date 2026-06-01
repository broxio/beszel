#!/usr/bin/env bash
# Container entrypoint for the HAProxy spool loader: run duck-haproxy-ingest.sh on
# a loop, logging to stdout (docker logs). Unlike the capacity entrypoint this needs
# NO hub URL / credentials — it only reads the local NDJSON spool the hub writes.
#
# Runs as root (does NOT drop to 'duck') so it can read the hub's root-owned spool
# files and archive closed daily files into <spool>/ingested/. It's a local-only
# loader with no network exposure, so root here is low-risk.
#
# duck-haproxy-report.sh is run on demand via `docker exec`.
set -uo pipefail

INTERVAL="${HAPROXY_INGEST_INTERVAL:-300}"   # seconds between runs (default 5 min)
export HAPROXY_DUCK_DB="${HAPROXY_DUCK_DB:-/data/haproxy.duckdb}"
export HAPROXY_SPOOL_DIR="${HAPROXY_SPOOL_DIR:-/spool}"
export HAPROXY_RETENTION_DAYS="${HAPROXY_RETENTION_DAYS:-14}"

# Optional Parquet export for the web UI (Duck-UI, browser-side DuckDB-WASM).
# We export a rolling window to version-stable Parquet (not the .duckdb, which a
# browser can't open across storage-format versions) so the UI can query it over
# HTTP with predicate pushdown. Done here, where no writer is active (our own
# ingest just finished); a temp+rename keeps nginx from serving a half-written file.
PARQUET_DIR="${HAPROXY_PARQUET_DIR:-}"            # e.g. /parquet; empty = off
PARQUET_DAYS="${HAPROXY_PARQUET_DAYS:-2}"         # rolling window exported to Parquet
EXPORT_EVERY="${HAPROXY_EXPORT_EVERY:-2}"         # export every N ingest cycles (2×5min = 10min)

export_parquet() {
  [[ -n "$PARQUET_DIR" ]] || return 0
  mkdir -p "$PARQUET_DIR"
  local ok=1 t
  for t in haproxy_proxies haproxy_info; do
    if duckdb -readonly "$HAPROXY_DUCK_DB" \
        "COPY (SELECT * FROM ${t} WHERE ts > (now() AT TIME ZONE 'UTC') - INTERVAL '${PARQUET_DAYS} days') TO '${PARQUET_DIR}/${t}.parquet.tmp' (FORMAT PARQUET);" >/dev/null 2>&1 \
       && mv -f "${PARQUET_DIR}/${t}.parquet.tmp" "${PARQUET_DIR}/${t}.parquet"; then
      :
    else
      ok=0; rm -f "${PARQUET_DIR}/${t}.parquet.tmp"
    fi
  done
  (( ok == 1 )) && echo "[haproxy-entrypoint] $(date -u +%FT%TZ) exported ${PARQUET_DAYS}d Parquet -> ${PARQUET_DIR}"
}

trap 'echo "[haproxy-entrypoint] stopping"; exit 0' TERM INT

echo "[haproxy-entrypoint] loop: interval=${INTERVAL}s db=${HAPROXY_DUCK_DB} spool=${HAPROXY_SPOOL_DIR} retention=${HAPROXY_RETENTION_DAYS}d parquet=${PARQUET_DIR:-off}"
cycle=0
while true; do
  echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest start"
  if duck-haproxy-ingest.sh; then
    echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest ok"
  else
    echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest FAILED rc=$? (will retry next cycle)"
  fi
  cycle=$((cycle + 1))
  if [[ -n "$PARQUET_DIR" ]] && (( cycle % EXPORT_EVERY == 0 )); then
    export_parquet
  fi
  sleep "$INTERVAL" &
  wait $!     # so a TERM during sleep stops promptly
done
