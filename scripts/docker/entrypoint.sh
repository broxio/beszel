#!/usr/bin/env bash
# Container entrypoint: run duck-ingest.sh on a loop, logging to stdout (docker logs).
# A loop (not cron) keeps logs in the container's stream and lets the restart policy
# handle crashes. duck-report.sh is run on demand via `docker exec`.
set -uo pipefail

# Started as root only to fix ownership of a freshly-created host bind mount,
# then drop to the unprivileged 'duck' user for all real work. (Named volumes
# are already duck-owned from the image, so the chown is a harmless no-op there.)
if [ "$(id -u)" = "0" ]; then
  chown -R duck:duck /data 2>/dev/null || true
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

# Reap nicely on stop.
trap 'echo "[entrypoint] stopping"; exit 0' TERM INT

# INGEST_MODE=cron: don't self-schedule; just stay alive so the docker host can
# drive timing via:  docker exec <container> duck-ingest.sh '<glob>'
if [[ "$MODE" == "cron" ]]; then
  echo "[entrypoint] INGEST_MODE=cron: idle (no internal loop). Trigger runs from the host crontab, e.g.:"
  echo "             */45 * * * * docker exec ${HOSTNAME} duck-ingest.sh '${GLOB}'"
  while true; do sleep 86400 & wait $!; done
fi

echo "[entrypoint] duck-ingest loop: interval=${INTERVAL}s glob='${GLOB}' lookback=${LOOKBACK_MIN:-70}m db=${DUCK_DB}"
while true; do
  echo "[entrypoint] $(date -u +%FT%TZ) ingest start"
  if duck-ingest.sh "$GLOB"; then
    echo "[entrypoint] $(date -u +%FT%TZ) ingest ok"
  else
    rc=$?
    echo "[entrypoint] $(date -u +%FT%TZ) ingest FAILED rc=$rc (will retry next cycle)"
  fi
  sleep "$INTERVAL" &
  wait $!     # so a TERM during sleep stops promptly
done
