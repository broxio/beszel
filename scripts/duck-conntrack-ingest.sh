#!/usr/bin/env bash
# duck-conntrack-ingest.sh — load the hub's SEALED conntrack spool files into a
# dedicated DuckDB, then DELETE them. Gap-free by design (same model as
# duck-haproxy-ingest.sh): the hub writes a single "conntrack.live.ndjson" and
# seals it every CONNTRACK_SPOOL_ROTATE into "conntrack-<stamp>-<seq>.ndjson".
# The hub never touches a sealed file again, so this loader ingests sealed files
# and removes them with zero data loss; the live file is ignored until its seal.
#
# One table:
#   conntrack  PK (system, ts)   — per-host netfilter conntrack snapshot
# ON CONFLICT DO NOTHING makes a crash between ingest and delete harmless.
#
# Usage: ./duck-conntrack-ingest.sh
#
# Env (optional):
#   CONNTRACK_DUCK_DB         dedicated DuckDB file (default: ./conntrack.duckdb)
#   CONNTRACK_SPOOL_DIR       spool dir written by the hub (default: ./conntrack-spool)
#   CONNTRACK_RETENTION_DAYS  if set, DELETE DB rows older than N days
#   CONNTRACK_MAX_FILES       cap files processed per run (default 60; 0 = unlimited)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/duck-lib.sh"

DUCK_DB="${CONNTRACK_DUCK_DB:-./conntrack.duckdb}"
SPOOL_DIR="${CONNTRACK_SPOOL_DIR:-./conntrack-spool}"
RETENTION_DAYS="${CONNTRACK_RETENTION_DAYS:-}"
ARCHIVE_DIR="${CONNTRACK_ARCHIVE_DIR:-}"
ARCHIVE_RETENTION_DAYS="${CONNTRACK_ARCHIVE_RETENTION_DAYS:-}"   # cap the Parquet archive; empty = keep forever

command -v duckdb >/dev/null || { echo "duck-conntrack-ingest.sh: duckdb not found in PATH" >&2; exit 1; }
[[ -d "$SPOOL_DIR" ]] || { echo "duck-conntrack-ingest.sh: spool dir not found: $SPOOL_DIR" >&2; exit 1; }
if [[ -n "$RETENTION_DAYS" ]]; then
  case "$RETENTION_DAYS" in ''|*[!0-9]*) echo "duck-conntrack-ingest.sh: CONNTRACK_RETENTION_DAYS must be an integer" >&2; exit 1 ;; esac
fi
MAX_FILES="${CONNTRACK_MAX_FILES:-60}"
case "$MAX_FILES" in ''|*[!0-9]*) echo "duck-conntrack-ingest.sh: CONNTRACK_MAX_FILES must be an integer" >&2; exit 1 ;; esac

mkdir -p "$(dirname "$DUCK_DB")"

# Sealed files only. "conntrack-*.ndjson" matches sealed files; the live file
# "conntrack.live.ndjson" has no '-' after the prefix, so it is excluded.
shopt -s nullglob
FILES=("$SPOOL_DIR"/conntrack-*.ndjson)
shopt -u nullglob

# Oldest-first (lexical = chronological for <stamp>-<seq>), capped per run.
cap_oldest() {
  (( $# == 0 )) && return 0
  if (( MAX_FILES == 0 )); then printf '%s\n' "$@"; else printf '%s\n' "$@" | sort | head -n "$MAX_FILES"; fi
}
mapfile -t FILES < <(cap_oldest "${FILES[@]}")

if (( ${#FILES[@]} == 0 )); then
  echo "($(date -u +%H:%M) no sealed spool files in $SPOOL_DIR)"; exit 0
fi

# DuckDB list literal ['a','b',...] of EXACTLY the files we ingest and then delete.
duck_list() {
  local out="" f
  for f in "$@"; do out+="'${f}',"; done
  printf '[%s]' "${out%,}"
}

SQL="
CREATE TABLE IF NOT EXISTS conntrack (
  ts TIMESTAMP, system VARCHAR, host VARCHAR,
  conns UBIGINT, conns_max UBIGINT, found UBIGINT, invalid UBIGINT,
  insert_failed UBIGINT, pkt_drop UBIGINT, early_drop UBIGINT, search_restart UBIGINT,
  PRIMARY KEY (system, ts)
);
INSERT INTO conntrack
  SELECT ts, system, host, conns, conns_max, found, invalid,
         insert_failed, pkt_drop, early_drop, search_restart
  FROM read_json_auto($(duck_list "${FILES[@]}"), format='newline_delimited', union_by_name=true)
  ON CONFLICT DO NOTHING;
SELECT '$(date -u +%H:%M) ingested ' || ${#FILES[@]} || ' file(s); conntrack=' ||
       (SELECT count(*) FROM conntrack) || ' rows / ' ||
       (SELECT count(DISTINCT host) FROM conntrack) || ' hosts, span ' ||
       (SELECT coalesce(strftime(min(ts),'%Y-%m-%d %H:%M'),'-') FROM conntrack) || ' .. ' ||
       (SELECT coalesce(strftime(max(ts),'%Y-%m-%d %H:%M'),'-') FROM conntrack) || ' UTC' AS status;
"

# Ingest first; only delete the spool files if DuckDB succeeded (else retry next
# run — ON CONFLICT keeps re-ingest idempotent).
if duckdb "$DUCK_DB" "$SQL"; then
  rm -f "${FILES[@]}"
else
  echo "duck-conntrack-ingest.sh: ingest failed; leaving sealed files for retry" >&2
  exit 1
fi

# Cold-tier retention (shared helper), independent of the spool (emptied each run):
# age `conntrack` out after RETENTION_DAYS; with CONNTRACK_ARCHIVE_DIR each expiring
# day is archived to Parquet first.
duck_archive_prune "$DUCK_DB" "$ARCHIVE_DIR" "$RETENTION_DAYS" conntrack
duck_archive_sweep "$ARCHIVE_DIR" "$ARCHIVE_RETENTION_DAYS" conntrack
