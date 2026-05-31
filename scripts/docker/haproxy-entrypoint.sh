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

trap 'echo "[haproxy-entrypoint] stopping"; exit 0' TERM INT

echo "[haproxy-entrypoint] loop: interval=${INTERVAL}s db=${HAPROXY_DUCK_DB} spool=${HAPROXY_SPOOL_DIR} retention=${HAPROXY_RETENTION_DAYS}d"
while true; do
  echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest start"
  if duck-haproxy-ingest.sh; then
    echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest ok"
  else
    echo "[haproxy-entrypoint] $(date -u +%FT%TZ) ingest FAILED rc=$? (will retry next cycle)"
  fi
  sleep "$INTERVAL" &
  wait $!     # so a TERM during sleep stops promptly
done
