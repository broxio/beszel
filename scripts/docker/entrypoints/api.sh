#!/usr/bin/env bash
# Container entrypoint for duck-api — the read-only HTTP report API. Starts as root
# only to drop privileges; the API itself reads the DuckDB stores (mounted read-only)
# and runs the duck-report-*.sh scripts with FORMAT=json. No hub creds, no writes.
set -euo pipefail

if [ "$(id -u)" = "0" ]; then
  # nothing to chown (/data is mounted read-only); just drop to the unprivileged user
  exec su-exec duck:duck "$0" "$@"
fi

echo "[api] starting duck-api: listen=${API_LISTEN:-:8088} dbs: capacity=${DUCK_DB:-/data/beszel.duckdb} haproxy=${HAPROXY_DUCK_DB:-/data/haproxy.duckdb} conntrack=${CONNTRACK_DUCK_DB:-/data/conntrack.duckdb}"
exec duck-api
