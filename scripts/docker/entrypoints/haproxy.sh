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

# Optional read-only snapshot for the DuckDB UI. The UI holds its DB file open,
# which (per DuckDB's single-writer lock) would block this loader's writes — so
# the UI must read a SEPARATE snapshot, never the live DB. We refresh it here,
# where we know no writer is active (our own ingest just finished).
UI_SNAPSHOT="${HAPROXY_UI_SNAPSHOT:-}"               # e.g. /data/haproxy-ui.duckdb; empty = off
UI_SNAPSHOT_EVERY="${HAPROXY_UI_SNAPSHOT_EVERY:-6}"  # refresh every N ingest cycles (6×5min = 30min)

refresh_ui_snapshot() {
  [[ -n "$UI_SNAPSHOT" ]] || return 0
  # CHECKPOINT folds any WAL into the main file so a plain copy is consistent,
  # then publish via temp+rename (atomic; the UI keeps serving until it reconnects).
  duckdb "$HAPROXY_DUCK_DB" "CHECKPOINT;" >/dev/null 2>&1 || true
  if cp -f "$HAPROXY_DUCK_DB" "${UI_SNAPSHOT}.tmp" && mv -f "${UI_SNAPSHOT}.tmp" "$UI_SNAPSHOT"; then
    echo "[haproxy-entrypoint] $(date -u +%FT%TZ) refreshed UI snapshot ${UI_SNAPSHOT}"
  fi
}

trap 'echo "[haproxy-entrypoint] stopping"; exit 0' TERM INT

echo "[haproxy-entrypoint] loop: interval=${INTERVAL}s db=${HAPROXY_DUCK_DB} spool=${HAPROXY_SPOOL_DIR} retention=${HAPROXY_RETENTION_DAYS}d ui_snapshot=${UI_SNAPSHOT:-off}"
cycle=0
while true; do
  echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest start"
  if duck-haproxy-ingest.sh; then
    echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest ok"
  else
    echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest FAILED rc=$? (will retry next cycle)"
  fi
  cycle=$((cycle + 1))
  if [[ -n "$UI_SNAPSHOT" ]] && (( cycle % UI_SNAPSHOT_EVERY == 0 )); then
    refresh_ui_snapshot
  fi
  sleep "$INTERVAL" &
  wait $!     # so a TERM during sleep stops promptly
done
