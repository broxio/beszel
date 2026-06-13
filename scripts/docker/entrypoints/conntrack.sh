#!/usr/bin/env bash
# Container entrypoint for the conntrack spool loader: run duck-conntrack-ingest.sh
# on a loop, logging to stdout (docker logs). Like the HAProxy loader it needs NO
# hub URL / credentials — it only reads the local NDJSON spool the hub writes.
#
# Runs as root (does NOT drop to 'duck') so it can read + delete the hub's
# root-owned sealed spool files. Local-only loader, no network exposure.
#
# duck-report-conntrack.sh is run on demand via `docker exec`. No Parquet export
# (conntrack is queried via the CLI report, not Duck-UI).
set -uo pipefail

INTERVAL="${CONNTRACK_INGEST_INTERVAL:-300}"   # seconds between runs (default 5 min)
export CONNTRACK_DUCK_DB="${CONNTRACK_DUCK_DB:-/data/conntrack.duckdb}"
export CONNTRACK_SPOOL_DIR="${CONNTRACK_SPOOL_DIR:-/spool}"
export CONNTRACK_RETENTION_DAYS="${CONNTRACK_RETENTION_DAYS:-14}"

trap 'echo "[conntrack-entrypoint] stopping"; exit 0' TERM INT

echo "[conntrack-entrypoint] loop: interval=${INTERVAL}s db=${CONNTRACK_DUCK_DB} spool=${CONNTRACK_SPOOL_DIR} retention=${CONNTRACK_RETENTION_DAYS}d"
while true; do
  echo "[conntrack-entrypoint] $(date -u +%FT%TZ) ingest start"
  if duck-conntrack-ingest.sh; then
    echo "[conntrack-entrypoint] $(date -u +%FT%TZ) ingest ok"
  else
    echo "[conntrack-entrypoint] $(date -u +%FT%TZ) ingest FAILED rc=$? (will retry next cycle)"
  fi
  sleep "$INTERVAL" &
  wait $!     # so a TERM during sleep stops promptly
done
