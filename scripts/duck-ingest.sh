#!/usr/bin/env bash
# duck-ingest.sh — siphon beszel's 1m system_stats into a local DuckDB before
# PocketBase prunes them (1m retention is 1 hour), building a permanent,
# minute-resolution analytical store. Off-host: pulls via the PocketBase REST API.
#
# Run on a timer MORE OFTEN than the 1h 1m-retention (every ~15 min) so no minute
# is missed. Re-ingesting the same rows is safe: PRIMARY KEY (host, ts) +
# ON CONFLICT DO NOTHING makes it idempotent.
#
# Usage:
#   ./duck-ingest.sh [HOST_GLOB]
#
# Env (required):
#   BESZEL_URL          Hub base URL, e.g. https://hub.example.com
#   BESZEL_TOKEN        PocketBase auth token (preferred)
#     -- OR --  BESZEL_EMAIL / BESZEL_PASSWORD   (exchanged for a token)
# Env (optional):
#   DUCK_DB             DuckDB file (default: ./beszel.duckdb)
#   LOOKBACK_MIN        Minutes of 1m history to fetch each run (default: 70; keep > cron gap)
#   RETENTION_DAYS      If set, age out metrics rows older than N days after each ingest
#                       (keeps the hot DuckDB bounded). Unset (default) = keep forever.
#   ARCHIVE_DIR         If set together with RETENTION_DAYS, each fully-expired UTC day is
#                       first written to <ARCHIVE_DIR>/metrics-YYYY-MM-DD.parquet (zstd) and
#                       only THEN deleted from the live DB — a cold tier, still queryable via
#                       read_parquet('<ARCHIVE_DIR>/metrics-*.parquet'). Unset = hard delete.
#
# Cron (every 15 min):
#   */15 * * * * BESZEL_URL=https://hub BESZEL_TOKEN=xxx DUCK_DB=/var/lib/beszel/beszel.duckdb \
#                /path/duck-ingest.sh '*' >> /var/log/beszel-duck.log 2>&1
#
# Then query with duck-report-capacity.sh, or any DuckDB client:
#   duckdb /var/lib/beszel/beszel.duckdb "SELECT host, quantile_cont(cpu,0.95) FROM metrics GROUP BY host"

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/duck-lib.sh"

GLOB="${1:-*}"
DUCK_DB="${DUCK_DB:-./beszel.duckdb}"
LOOKBACK_MIN="${LOOKBACK_MIN:-70}"
RETENTION_DAYS="${RETENTION_DAYS:-}"

: "${BESZEL_URL:?set BESZEL_URL (e.g. https://hub.example.com)}"
if [[ -z "${BESZEL_TOKEN:-}" ]]; then
  : "${BESZEL_EMAIL:?set BESZEL_TOKEN, or BESZEL_EMAIL + BESZEL_PASSWORD}"
  : "${BESZEL_PASSWORD:?set BESZEL_PASSWORD}"
fi
for bin in curl jq duckdb; do
  command -v "$bin" >/dev/null || { echo "duck-ingest.sh: $bin not found in PATH" >&2; exit 1; }
done
case "$LOOKBACK_MIN" in ''|*[!0-9]*) echo "duck-ingest.sh: LOOKBACK_MIN must be an integer" >&2; exit 1 ;; esac
if [[ -n "$RETENTION_DAYS" ]]; then
  case "$RETENTION_DAYS" in ''|*[!0-9]*) echo "duck-ingest.sh: RETENTION_DAYS must be an integer (days)" >&2; exit 1 ;; esac
fi

BASE="${BESZEL_URL%/}"
AUTH_COLLECTION="${BESZEL_AUTH_COLLECTION:-users}"   # 'users' for a regular account, '_superusers' for an admin

# ---- auth ----
if [[ -z "${BESZEL_TOKEN:-}" ]]; then
  resp="$(curl -fsS --connect-timeout 10 --max-time 120 -X POST "$BASE/api/collections/${AUTH_COLLECTION}/auth-with-password" \
            -H 'Content-Type: application/json' \
            -d "$(jq -n --arg i "$BESZEL_EMAIL" --arg p "$BESZEL_PASSWORD" '{identity:$i,password:$p}')")"
  BESZEL_TOKEN="$(jq -r '.token' <<<"$resp")"
  [[ -n "$BESZEL_TOKEN" && "$BESZEL_TOKEN" != "null" ]] || { echo "duck-ingest.sh: auth failed" >&2; exit 1; }
fi
AUTH=(-H "Authorization: Bearer $BESZEL_TOKEN")

# ---- systems matching glob (vCPU = info.c else info.t) ----
SYS_JSON="$(curl -fsS --connect-timeout 10 --max-time 120 "${AUTH[@]}" \
  "$BASE/api/collections/systems/records?perPage=500&fields=id,name,info&sort=name")"
MATCH_JSON="$(jq -c --arg g "$GLOB" '
  [ .items[] | { id, name, vcpu: ((.info.c // 0) as $c | if $c > 0 then $c else (.info.t // 0) end) } ]
  | [ .[] | select(.name | test("^" + ($g|gsub("\\*";".*")|gsub("\\?";".")) + "$")) ]' <<<"$SYS_JSON")"
if (( $(jq 'length' <<<"$MATCH_JSON") == 0 )); then
  echo "(no systems match glob: $GLOB)"; exit 0
fi
SYS_MAP="$(jq -c 'map({(.id): {name, vcpu}}) | add' <<<"$MATCH_JSON")"
SYS_COUNT="$(jq 'length' <<<"$MATCH_JSON")"

# ---- since = now - LOOKBACK_MIN (UTC) ----
if date -u -v-1M +%s >/dev/null 2>&1; then
  SINCE_ISO="$(date -u -v-"${LOOKBACK_MIN}"M +"%Y-%m-%d %H:%M:%S")"
else
  SINCE_ISO="$(date -u -d "-${LOOKBACK_MIN} minutes" +"%Y-%m-%d %H:%M:%S")"
fi
# Only constrain by system id when the matched set is small; a long
# "system=... || ..." filter overflows the request URL -> HTTP 400. For large
# selections (e.g. glob '*') fetch all 1m in the window and filter client-side.
if (( SYS_COUNT <= 30 )); then
  SYS_FILTER="$(jq -r 'map("system=\"\(.id)\"") | join(" || ")' <<<"$MATCH_JSON")"
  FILTER="type='1m' && created >= '${SINCE_ISO}' && (${SYS_FILTER})"
else
  FILTER="type='1m' && created >= '${SINCE_ISO}'"
fi
FILTER_ENC="$(jq -rn --arg f "$FILTER" '$f|@uri')"

# ---- pull the 1m window ----
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
PAGE=1; > "$TMP_DIR/all.json"
while :; do
  CHUNK="$(curl -fsS --connect-timeout 10 --max-time 120 "${AUTH[@]}" \
    "$BASE/api/collections/system_stats/records?perPage=500&page=${PAGE}&fields=system,stats,created&filter=${FILTER_ENC}")"
  jq -c '.items[]' <<<"$CHUNK" >> "$TMP_DIR/all.json"
  TOTAL_PAGES="$(jq '.totalPages' <<<"$CHUNK")"
  (( PAGE >= TOTAL_PAGES )) && break
  PAGE=$((PAGE+1))
done
if [[ ! -s "$TMP_DIR/all.json" ]]; then
  echo "($(date -u +%H:%M) no 1m records in last ${LOOKBACK_MIN}m for glob=$GLOB)"; exit 0
fi

# ---- transform to CSV (schema column order; ts as UTC naive 'YYYY-MM-DD HH:MM:SS') ----
jq -rs --argjson m "$SYS_MAP" '
  def num($x): if $x==null then 0 else ($x|tonumber? // 0) end;
  .[]
  | select(.stats.cpu != null)
  | ($m[.system]) as $s
  | select($s != null)                      # drop systems outside the glob (client-side filter)
  | [ (.created | gsub("(\\.[0-9]+)?Z$";"")),
      $s.name, $s.vcpu,
      num(.stats.cpu), num(.stats.cpub[3]?),
      num(.stats.mu), num(.stats.m), num(.stats.mp), num(.stats.su),
      ([num(.stats.b[0]?), num(.stats.bm[0]?)] | max),
      ([num(.stats.b[1]?), num(.stats.bm[1]?)] | max),
      num(.stats.dp), num(.stats.du), num(.stats.d),
      num(.stats.dr), num(.stats.dw), num(.stats.dios[2]?),
      num(.stats.la[0]?), num(.stats.la[1]?), num(.stats.la[2]?)
    ] | @csv
' "$TMP_DIR/all.json" > "$TMP_DIR/rows.csv"

ROWCNT="$(wc -l < "$TMP_DIR/rows.csv" | tr -d ' ')"
if [[ "$ROWCNT" -eq 0 ]]; then echo "($(date -u +%H:%M) no usable samples)"; exit 0; fi

# ---- create table (idempotent) + dedup-insert ----
mkdir -p "$(dirname "$DUCK_DB")"
duckdb "$DUCK_DB" <<SQL
CREATE TABLE IF NOT EXISTS metrics (
  ts            TIMESTAMP,
  host          VARCHAR,
  vcpu          INTEGER,
  cpu           DOUBLE,
  steal         DOUBLE,
  mem_used_gb   DOUBLE,
  mem_total_gb  DOUBLE,
  mem_pct       DOUBLE,
  swap_gb       DOUBLE,
  net_out_bps   UBIGINT,
  net_in_bps    UBIGINT,
  disk_pct       DOUBLE,
  disk_used_gb   DOUBLE,
  disk_total_gb  DOUBLE,
  disk_read_bps  DOUBLE,   -- NOTE: agent dr/dw are MB/s (readMbPerSecond), not bytes/s, despite the name
  disk_write_bps DOUBLE,
  io_util        DOUBLE,   -- dios[2]: disk IO utilization %, 0-100
  load1          DOUBLE,
  load5          DOUBLE,
  load15         DOUBLE,
  PRIMARY KEY (host, ts)
);

-- Widen an already-deployed metrics table (no-op once the columns exist).
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS disk_pct       DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS disk_used_gb   DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS disk_total_gb  DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS disk_read_bps  DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS disk_write_bps DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS io_util        DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS load1          DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS load5          DOUBLE;
ALTER TABLE metrics ADD COLUMN IF NOT EXISTS load15         DOUBLE;

CREATE TEMP TABLE _stg AS
  SELECT * FROM read_csv('${TMP_DIR}/rows.csv', header=false,
    columns={
      'ts':'TIMESTAMP','host':'VARCHAR','vcpu':'INTEGER','cpu':'DOUBLE','steal':'DOUBLE',
      'mem_used_gb':'DOUBLE','mem_total_gb':'DOUBLE','mem_pct':'DOUBLE','swap_gb':'DOUBLE',
      'net_out_bps':'UBIGINT','net_in_bps':'UBIGINT',
      'disk_pct':'DOUBLE','disk_used_gb':'DOUBLE','disk_total_gb':'DOUBLE',
      'disk_read_bps':'DOUBLE','disk_write_bps':'DOUBLE','io_util':'DOUBLE',
      'load1':'DOUBLE','load5':'DOUBLE','load15':'DOUBLE'
    });

INSERT INTO metrics SELECT * FROM _stg ON CONFLICT DO NOTHING;

SELECT '$(date -u +%H:%M) fetched=${ROWCNT} rows; metrics now has ' || count(*) || ' rows across ' ||
       count(DISTINCT host) || ' hosts, span ' ||
       strftime(min(ts), '%Y-%m-%d %H:%M') || ' .. ' || strftime(max(ts), '%Y-%m-%d %H:%M') || ' UTC' AS status
FROM metrics;
SQL

# Cold-tier retention (shared helper): age `metrics` out of the hot DB after
# RETENTION_DAYS, archiving each expiring day to ARCHIVE_DIR/metrics-*.parquet first.
duck_archive_prune "$DUCK_DB" "${ARCHIVE_DIR:-}" "$RETENTION_DAYS" metrics
