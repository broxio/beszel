#!/usr/bin/env bash
# DuckDB UI for the HAProxy store, exposed from the beszel-duck stack.
#
# Serves the READ-ONLY snapshot the loader refreshes (haproxy-ui.duckdb), NOT the
# live DB: DuckDB is single-writer across processes, so a UI holding the live file
# open would block the loader's ingestion (verified: "Could not set lock ...").
#
# The official DuckDB UI (a) binds 127.0.0.1 only and (b) serves its frontend from
# ui.duckdb.org. So this container needs OUTBOUND internet (to download the `ui`
# extension and load the frontend), and we socat-forward 0.0.0.0:$PORT ->
# 127.0.0.1:$UIPORT so Docker can publish it. The UI has NO auth — publish only on
# a trusted interface (host localhost + SSH tunnel, or a reverse proxy with auth).
set -uo pipefail

UI_DB="${HAPROXY_UI_DB:-/data/haproxy-ui.duckdb}"
PORT="${HAPROXY_UI_PORT:-4213}"             # published port (socat listens on 0.0.0.0)
UIPORT="${HAPROXY_UI_BACKEND_PORT:-4214}"   # duckdb UI server (127.0.0.1 only)
FIFO="$(mktemp -u)"

cleanup() { echo "[haproxy-ui] stopping"; exec 9>&- 2>/dev/null; kill 0 2>/dev/null; rm -f "$FIFO"; exit 0; }
trap cleanup TERM INT

echo "[haproxy-ui] waiting for snapshot ${UI_DB} (the loader creates it; set HAPROXY_UI_SNAPSHOT on haproxy-duck) ..."
while [[ ! -f "$UI_DB" ]]; do sleep 5; done

mkfifo "$FIFO"

start_ui() {
  duckdb -readonly "$UI_DB" < "$FIFO" &
  UIPID=$!
  exec 9>"$FIFO"   # keep stdin open so the REPL (and the UI server) stays alive
  echo "SET ui_local_port=${UIPORT}; CALL start_ui_server();" >&9
}
stop_ui() {
  exec 9>&- 2>/dev/null   # EOF -> duckdb exits cleanly
  kill "$UIPID" 2>/dev/null; wait "$UIPID" 2>/dev/null
}

# Expose the localhost-only UI server on all interfaces so Docker can publish it.
socat TCP-LISTEN:${PORT},fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:${UIPORT} &

echo "[haproxy-ui] DuckDB UI: db=${UI_DB} backend=127.0.0.1:${UIPORT} published=0.0.0.0:${PORT}"
start_ui
last="$(stat -c %Y "$UI_DB" 2>/dev/null || echo 0)"

# Reload the UI when the loader publishes a fresh snapshot, so data doesn't freeze.
while true; do
  sleep 30
  cur="$(stat -c %Y "$UI_DB" 2>/dev/null || echo 0)"
  if [[ "$cur" != "$last" ]]; then
    echo "[haproxy-ui] snapshot updated; reloading UI to serve fresh data"
    stop_ui; start_ui; last="$cur"
  elif ! kill -0 "$UIPID" 2>/dev/null; then
    echo "[haproxy-ui] UI process exited; restarting"
    start_ui
  fi
done
