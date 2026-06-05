#!/usr/bin/env bash
# duck-lib.sh — shared helpers for the DuckDB ingest scripts. Sourced (not executed)
# by duck-ingest.sh / duck-haproxy-ingest.sh / duck-conntrack-ingest.sh. Lives next
# to them so the same relative source works in the repo (scripts/) and in the image
# (/usr/local/bin/). No side effects on source — defines functions only.

# duck_archive_prune <db_file> <archive_dir|''> <retention_days|''> <table> [<table> ...]
#
# Consistent cold-tier retention for every DuckDB store. For each TABLE, ages rows
# out of the hot DB by WHOLE UTC DAY once they're older than <retention_days>:
#   - archive_dir non-empty: each expiring day is first written to
#       <archive_dir>/<table>-YYYY-MM-DD.parquet  (zstd)  and only THEN deleted —
#       a queryable cold tier (read_parquet('<archive_dir>/<table>-*.parquet')).
#   - archive_dir empty: hard delete (no archive).
# Empty retention_days => no-op (keep forever).
#
# Day granularity makes it idempotent: a day is either fully present in the hot DB
# or fully archived+deleted; a re-run overwrites the same single per-day file
# (COPY TO <file> truncates), never duplicating rows. Safe because ingest only ever
# inserts recent rows, so an already-archived day is never re-inserted. Each TABLE
# must have a TIMESTAMP column named `ts`.
duck_archive_prune() {
  local db="$1" archive_dir="$2" retention_days="$3"; shift 3
  [[ -n "$retention_days" ]] || return 0
  case "$retention_days" in ''|*[!0-9]*)
    echo "duck_archive_prune: retention_days must be an integer (got '$retention_days')" >&2; return 1 ;;
  esac
  local cutoff="CAST((now() AT TIME ZONE 'UTC') - INTERVAL '${retention_days} days' AS DATE)"
  local table d expired_days
  for table in "$@"; do
    if [[ -z "$archive_dir" ]]; then
      duckdb "$db" "DELETE FROM ${table} WHERE CAST(ts AS DATE) < ${cutoff};"
      continue
    fi
    mkdir -p "$archive_dir"
    expired_days="$(duckdb -readonly -noheader -list "$db" \
      "SELECT DISTINCT CAST(ts AS DATE) FROM ${table} WHERE CAST(ts AS DATE) < ${cutoff} ORDER BY 1;" \
      2>/dev/null)" || expired_days=""
    while IFS= read -r d; do
      [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
      if duckdb "$db" "
           COPY (SELECT * FROM ${table} WHERE CAST(ts AS DATE) = DATE '${d}')
             TO '${archive_dir}/${table}-${d}.parquet' (FORMAT PARQUET, COMPRESSION zstd);
           DELETE FROM ${table} WHERE CAST(ts AS DATE) = DATE '${d}';"; then
        echo "$(date -u +%H:%M) archived+pruned ${table} ${d} -> ${archive_dir}/${table}-${d}.parquet"
      else
        echo "duck_archive_prune: archive of ${table} ${d} failed; leaving rows for retry" >&2
      fi
    done <<< "$expired_days"
  done
}
