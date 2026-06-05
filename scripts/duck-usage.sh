#!/usr/bin/env bash
# duck-usage.sh — "how many records, how big" for each DuckDB store over a recent
# window. For every store present it prints the DB's on-disk size + total rows, then
# per table: rows in the window, distinct hosts, time span, and the window's
# zstd-Parquet footprint (≈ what one day of cold-tier archive costs; the live DuckDB
# on disk is larger because it compresses less aggressively).
#
# Usage:  ./duck-usage.sh [HOURS]        (default 24)
# Env:    DUCK_DB / HAPROXY_DUCK_DB / CONNTRACK_DUCK_DB
#         (default /data/{beszel,haproxy,conntrack}.duckdb; a missing file is skipped)

set -euo pipefail

HOURS="${1:-24}"
case "$HOURS" in ''|*[!0-9]*) echo "usage: duck-usage.sh [HOURS]" >&2; exit 1 ;; esac
command -v duckdb >/dev/null || { echo "duck-usage.sh: duckdb not found in PATH" >&2; exit 1; }

DUCK_DB="${DUCK_DB:-/data/beszel.duckdb}"
HAPROXY_DUCK_DB="${HAPROXY_DUCK_DB:-/data/haproxy.duckdb}"
CONNTRACK_DUCK_DB="${CONNTRACK_DUCK_DB:-/data/conntrack.duckdb}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
WINDOW="ts >= (now() AT TIME ZONE 'UTC') - INTERVAL '${HOURS} hours'"

filesize() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
human_mb() { awk "BEGIN{printf \"%.2f\", $1/1e6}"; }

# one store: <db> <table>[,<table>...]
report_store() {
  local db="$1" tables="$2"
  [[ -f "$db" ]] || return 0
  local dbbytes total; dbbytes="$(filesize "$db")"
  total="$(duckdb -readonly -noheader -list "$db" \
    "SELECT $(echo "$tables" | tr ',' '\n' | awk '{printf "(SELECT count(*) FROM %s)+", $0}')0;" 2>/dev/null || echo '?')"
  printf '\n== %s  (on-disk %s MB, total rows %s) — last %sh ==\n' \
    "$db" "$(human_mb "$dbbytes")" "$total" "$HOURS"
  printf '%-18s %12s %7s %-26s %12s\n' table rows hosts span_utc parquet_mb
  printf '%-18s %12s %7s %-26s %12s\n' ------------------ ------------ ------- -------------------------- ------------
  local t pq bytes line
  IFS=',' read -ra _tbls <<<"$tables"
  for t in "${_tbls[@]}"; do
    pq="$TMP/${t}.parquet"
    duckdb -readonly "$db" \
      "COPY (SELECT * FROM ${t} WHERE ${WINDOW}) TO '${pq}' (FORMAT PARQUET, COMPRESSION zstd);" 2>/dev/null \
      || { printf '%-18s %12s\n' "$t" "(no table)"; continue; }
    bytes="$(filesize "$pq")"
    line="$(duckdb -readonly -noheader -list "$db" "
      SELECT count(*) || chr(9) ||
             count(DISTINCT host) || chr(9) ||
             coalesce(strftime(min(ts),'%m-%d %H:%M'),'-') || '..' || coalesce(strftime(max(ts),'%H:%M'),'-')
      FROM ${t} WHERE ${WINDOW};")"
    IFS=$'\t' read -r rows hosts span <<<"$line"
    printf '%-18s %12s %7s %-26s %12s\n' "$t" "$rows" "$hosts" "$span" "$(human_mb "$bytes")"
  done
}

report_store "$DUCK_DB"          "metrics"
report_store "$HAPROXY_DUCK_DB"  "haproxy_proxies,haproxy_info"
report_store "$CONNTRACK_DUCK_DB" "conntrack"
echo
