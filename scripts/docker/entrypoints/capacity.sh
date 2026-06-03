#!/usr/bin/env bash
# Container entrypoint: run duck-ingest.sh on a loop, logging to stdout (docker logs).
# A loop (not cron) keeps logs in the container's stream and lets the restart policy
# handle crashes. duck-report-capacity.sh is run on demand via `docker exec`.
set -uo pipefail

# Started as root only to fix ownership of a freshly-created host bind mount,
# then drop to the unprivileged 'duck' user for all real work. (Named volumes
# are already duck-owned from the image, so the chown is a harmless no-op there.)
if [ "$(id -u)" = "0" ]; then
  chown -R duck:duck /data 2>/dev/null || true
  # let the duck user create metrics.parquet in the shared /parquet dir (haproxy's
  # root-owned files there keep their ownership; chown the dir only, not -R)
  [ -n "${CAPACITY_PARQUET_DIR:-}" ] && [ -d "${CAPACITY_PARQUET_DIR}" ] && chown duck:duck "${CAPACITY_PARQUET_DIR}" 2>/dev/null || true
  exec su-exec duck:duck "$0" "$@"
fi

: "${BESZEL_URL:?set BESZEL_URL}"
if [[ -z "${BESZEL_TOKEN:-}" && ( -z "${BESZEL_EMAIL:-}" || -z "${BESZEL_PASSWORD:-}" ) ]]; then
  echo "[entrypoint] need BESZEL_TOKEN, or BESZEL_EMAIL + BESZEL_PASSWORD" >&2
  exit 1
fi

INTERVAL="${INGEST_INTERVAL:-2700}"   # seconds between runs (default 45 min)
GLOB="${GLOB:-*}"
MODE="${INGEST_MODE:-loop}"           # loop = internal scheduler (default); cron = idle, host drives timing
export DUCK_DB="${DUCK_DB:-/data/beszel.duckdb}"

[[ -n "${BESZEL_TOKEN:-}" ]] && echo "[entrypoint] WARNING: using a static BESZEL_TOKEN — it will expire; prefer BESZEL_EMAIL/PASSWORD for a long-running container"

# Optional Parquet export of the metrics table for the web UI (Duck-UI). Served by
# nginx at /data/metrics.parquet alongside the HAProxy ones; query with read_parquet().
PARQUET_DIR="${CAPACITY_PARQUET_DIR:-}"            # e.g. /parquet; empty = off
PARQUET_DAYS="${CAPACITY_PARQUET_DAYS:-}"          # rolling window; empty = full history
EXPORT_EVERY="${CAPACITY_EXPORT_EVERY:-1}"         # export every N ingest cycles (default: every run)

export_parquet() {
  [[ -n "$PARQUET_DIR" ]] || return 0
  mkdir -p "$PARQUET_DIR"
  local where=""
  [[ -n "$PARQUET_DAYS" ]] && where="WHERE ts > (now() AT TIME ZONE 'UTC') - INTERVAL '${PARQUET_DAYS} days'"
  if duckdb -readonly "$DUCK_DB" \
       "COPY (SELECT * FROM metrics ${where}) TO '${PARQUET_DIR}/metrics.parquet.tmp' (FORMAT PARQUET);" >/dev/null 2>&1 \
     && mv -f "${PARQUET_DIR}/metrics.parquet.tmp" "${PARQUET_DIR}/metrics.parquet"; then
    echo "[entrypoint] $(date -u +%FT%TZ) exported metrics Parquet -> ${PARQUET_DIR}"
  else
    rm -f "${PARQUET_DIR}/metrics.parquet.tmp"
  fi
}

# Reap nicely on stop.
trap 'echo "[entrypoint] stopping"; exit 0' TERM INT

# INGEST_MODE=cron: don't self-schedule; just stay alive so the docker host can
# drive timing via:  docker exec <container> duck-ingest.sh '<glob>'
if [[ "$MODE" == "cron" ]]; then
  echo "[entrypoint] INGEST_MODE=cron: idle (no internal loop). Trigger runs from the host crontab, e.g.:"
  echo "             */45 * * * * docker exec ${HOSTNAME} duck-ingest.sh '${GLOB}'"
  while true; do sleep 86400 & wait $!; done
fi

echo "[entrypoint] duck-ingest loop: interval=${INTERVAL}s glob='${GLOB}' lookback=${LOOKBACK_MIN:-70}m db=${DUCK_DB} parquet=${PARQUET_DIR:-off}"
cycle=0
while true; do
  echo "[entrypoint] $(date -u +%FT%TZ) ingest start"
  if duck-ingest.sh "$GLOB"; then
    echo "[entrypoint] $(date -u +%FT%TZ) ingest ok"
  else
    rc=$?
    echo "[entrypoint] $(date -u +%FT%TZ) ingest FAILED rc=$rc (will retry next cycle)"
  fi
  cycle=$((cycle + 1))
  if [[ -n "$PARQUET_DIR" ]] && { (( cycle == 1 )) || (( cycle % EXPORT_EVERY == 0 )); }; then
    export_parquet
  fi
  sleep "$INTERVAL" &
  wait $!     # so a TERM during sleep stops promptly
done
