#!/usr/bin/env bash
# stats.sh — snapshot per-system / per-group / total stats from beszel PocketBase.
#
# Direct-SQLite flavor. Run on the hub host (where pb_data/data.db lives).
#
# Usage:
#   ./stats.sh [HOURS] [HOST_GLOB]
#
# Examples:
#   ./stats.sh                  # last 6h, all systems
#   ./stats.sh 6                # last 6h, all systems
#   ./stats.sh 24 'ha-web*'     # last 24h, hosts matching ha-web*
#   ./stats.sh 6 'lvs-*'        # last 6h, hosts matching lvs-*
#
# Env:
#   BESZEL_DB    Path to PocketBase SQLite db (default: ./pb_data/data.db)

set -euo pipefail

HOURS="${1:-6}"
GLOB="${2:-*}"
DB="${BESZEL_DB:-./pb_data/data.db}"

if ! command -v sqlite3 >/dev/null; then
  echo "stats.sh: sqlite3 not found in PATH" >&2
  exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "stats.sh: db not found at $DB (set BESZEL_DB)" >&2
  exit 1
fi
case "$HOURS" in ''|*[!0-9]*) echo "stats.sh: HOURS must be a positive integer" >&2; exit 1 ;; esac
if (( HOURS < 1 )); then echo "stats.sh: HOURS must be >= 1" >&2; exit 1; fi

# Pick the rollup bucket that gives a usable row count without scanning raw 1m records.
if   (( HOURS <= 8   )); then BUCKET='10m'
elif (( HOURS <= 48  )); then BUCKET='20m'
elif (( HOURS <= 240 )); then BUCKET='120m'
else                          BUCKET='480m'
fi

# Convert shell glob -> SQL LIKE pattern. * -> %, ? -> _, escape existing %/_.
glob_to_like() {
  local g="$1" out=""
  local i ch
  for (( i=0; i<${#g}; i++ )); do
    ch="${g:i:1}"
    case "$ch" in
      '*') out+='%' ;;
      '?') out+='_' ;;
      '%'|'_') out+='\'"$ch" ;;
      *) out+="$ch" ;;
    esac
  done
  printf '%s' "$out"
}
LIKE="$(glob_to_like "$GLOB")"

SINCE="-${HOURS} hours"

# Single query: pull per-system aggregates as TSV. Group/totals computed in awk so
# we can apply the hostname grouping rule (strip trailing -N).
SQL=$(cat <<SQL
SELECT
  s.name                                                                AS host,
  COALESCE(CAST(json_extract(s.info, '\$.c') AS INTEGER),
           CAST(json_extract(s.info, '\$.t') AS INTEGER), 0)            AS cores,
  COUNT(*)                                                              AS samples,
  printf('%.2f', AVG(CAST(json_extract(ss.stats, '\$.cpu') AS REAL)))   AS avg_cpu,
  printf('%.2f', MAX(COALESCE(CAST(json_extract(ss.stats, '\$.cpum') AS REAL),
                              CAST(json_extract(ss.stats, '\$.cpu')  AS REAL)))) AS max_cpu,
  printf('%.2f', AVG(CAST(json_extract(ss.stats, '\$.mp')  AS REAL)))   AS avg_memp,
  printf('%.2f', MAX(CAST(json_extract(ss.stats, '\$.mp')  AS REAL)))   AS max_memp,
  printf('%.2f', MAX(COALESCE(CAST(json_extract(ss.stats, '\$.nsm') AS REAL),
                              CAST(json_extract(ss.stats, '\$.ns')  AS REAL), 0))) AS max_ns_mbps,
  printf('%.2f', MAX(COALESCE(CAST(json_extract(ss.stats, '\$.nrm') AS REAL),
                              CAST(json_extract(ss.stats, '\$.nr')  AS REAL), 0))) AS max_nr_mbps,
  MAX(COALESCE(CAST(json_extract(ss.stats, '\$.bm[0]') AS INTEGER),
               CAST(json_extract(ss.stats, '\$.b[0]')  AS INTEGER), 0))  AS max_bw_sent_bps,
  MAX(COALESCE(CAST(json_extract(ss.stats, '\$.bm[1]') AS INTEGER),
               CAST(json_extract(ss.stats, '\$.b[1]')  AS INTEGER), 0))  AS max_bw_recv_bps,
  MAX(CASE WHEN json_extract(ss.stats, '\$.hap')  IS NOT NULL THEN 1 ELSE 0 END) AS has_hap,
  MAX(CASE WHEN json_extract(ss.stats, '\$.ipvs') IS NOT NULL THEN 1 ELSE 0 END) AS has_ipvs
FROM system_stats ss
JOIN systems s ON s.id = ss.system
WHERE ss.type = '${BUCKET}'
  AND ss.created >= datetime('now', '${SINCE}')
  AND s.name LIKE '${LIKE}' ESCAPE '\\'
GROUP BY s.id
ORDER BY s.name;
SQL
)

ROWS="$(sqlite3 -separator $'\t' "$DB" "$SQL")"

# ---- HAProxy per-host aggregates (FRONTEND-only sums, max rates) ----
HAP_SQL=$(cat <<SQL
WITH samples AS (
  SELECT s.id AS sysid, s.name AS host, ss.stats AS st
  FROM system_stats ss
  JOIN systems s ON s.id = ss.system
  WHERE ss.type = '${BUCKET}'
    AND ss.created >= datetime('now', '${SINCE}')
    AND s.name LIKE '${LIKE}' ESCAPE '\\'
    AND json_extract(ss.stats, '\$.hap') IS NOT NULL
),
expanded AS (
  SELECT host,
         json_extract(je.value, '\$.t')   AS ptype,
         CAST(json_extract(je.value, '\$.rr')  AS REAL) AS rr,
         CAST(json_extract(je.value, '\$.bir') AS REAL) AS bir,
         CAST(json_extract(je.value, '\$.bor') AS REAL) AS bor,
         CAST(json_extract(je.value, '\$.sc')  AS REAL) AS sc
  FROM samples, json_each(samples.st, '\$.hap') je
)
SELECT host,
       printf('%.0f', MAX(CASE WHEN ptype = 'FRONTEND' THEN rr  ELSE 0 END))  AS max_req_rate,
       printf('%.0f', MAX(CASE WHEN ptype = 'FRONTEND' THEN bir ELSE 0 END))  AS max_bytes_in_rate,
       printf('%.0f', MAX(CASE WHEN ptype = 'FRONTEND' THEN bor ELSE 0 END))  AS max_bytes_out_rate,
       printf('%.0f', MAX(CASE WHEN ptype = 'FRONTEND' THEN sc  ELSE 0 END))  AS max_cur_sess
FROM expanded
GROUP BY host
ORDER BY host;
SQL
)
HAP_ROWS="$(sqlite3 -separator $'\t' "$DB" "$HAP_SQL")"

# ---- IPVS per-host aggregates (service-level rates already in the top-level ipvs object) ----
IPVS_SQL=$(cat <<SQL
SELECT s.name AS host,
       printf('%.0f', MAX(COALESCE(CAST(json_extract(ss.stats, '\$.ipvs.cps') AS REAL), 0))) AS max_conn_rate,
       printf('%.0f', MAX(COALESCE(CAST(json_extract(ss.stats, '\$.ipvs.bir') AS REAL), 0))) AS max_bps_in,
       printf('%.0f', MAX(COALESCE(CAST(json_extract(ss.stats, '\$.ipvs.bor') AS REAL), 0))) AS max_bps_out,
       printf('%.0f', MAX(COALESCE(CAST(json_extract(ss.stats, '\$.ipvs.ac')  AS REAL), 0))) AS max_active_conns
FROM system_stats ss
JOIN systems s ON s.id = ss.system
WHERE ss.type = '${BUCKET}'
  AND ss.created >= datetime('now', '${SINCE}')
  AND s.name LIKE '${LIKE}' ESCAPE '\\'
  AND json_extract(ss.stats, '\$.ipvs') IS NOT NULL
GROUP BY s.id
ORDER BY s.name;
SQL
)
IPVS_ROWS="$(sqlite3 -separator $'\t' "$DB" "$IPVS_SQL")"

if [[ -z "$ROWS" ]]; then
  echo "(no matching system_stats rows for type=${BUCKET}, window=${HOURS}h, glob=${GLOB})"
  exit 0
fi

# ---- Render with awk: per-system, per-group, totals ----
echo
echo "beszel stats — window=${HOURS}h  bucket=${BUCKET}  glob=${GLOB}  db=${DB}"
echo

HAP_ROWS_E="$HAP_ROWS" IPVS_ROWS_E="$IPVS_ROWS" awk -F'\t' '
function group_key(h,   k) {
  # strip a trailing -<digits> suffix to derive group name (ha-web-1 -> ha-web)
  k = h; sub(/-[0-9]+$/, "", k); return k
}
function human_bps(bps,   units, i, v) {
  split("bps Kbps Mbps Gbps Tbps", units, " ")
  v = bps * 8.0; i = 1
  while (v >= 1000 && i < 5) { v /= 1000; i++ }
  return sprintf("%.2f %s", v, units[i])
}
BEGIN {
  # parse HAProxy rows (passed via env to allow embedded newlines)
  n = split(ENVIRON["HAP_ROWS_E"], hlines, "\n")
  for (i = 1; i <= n; i++) {
    if (hlines[i] == "") continue
    split(hlines[i], a, "\t")
    HAP[a[1]] = a[2] "|" a[3] "|" a[4] "|" a[5]
  }
  n = split(ENVIRON["IPVS_ROWS_E"], ilines, "\n")
  for (i = 1; i <= n; i++) {
    if (ilines[i] == "") continue
    split(ilines[i], a, "\t")
    IPVS[a[1]] = a[2] "|" a[3] "|" a[4] "|" a[5]
  }

  fmt_h = "%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n"
  fmt_r = "%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n"
  printf fmt_h, "HOST", "CORES", "SAMPLES", "AVG_CPU", "MAX_CPU", "AVG_MEM%", "MAX_MEM%", "MAX_NET_OUT", "MAX_NET_IN"
  printf "%s\n", "----------------------------------------------------------------------------------------------------"
}
{
  host=$1; cores=$2; samples=$3; acpu=$4; mcpu=$5; amem=$6; mmem=$7
  max_ns=$8; max_nr=$9; max_bw_s=$10; max_bw_r=$11
  has_hap=$12; has_ipvs=$13

  # Prefer raw bandwidth bytes/sec (b/bm) over MB/s nsm/nrm, since b has more precision.
  if (max_bw_s+0 > 0) net_out = human_bps(max_bw_s); else net_out = sprintf("%s MB/s", max_ns)
  if (max_bw_r+0 > 0) net_in  = human_bps(max_bw_r); else net_in  = sprintf("%s MB/s", max_nr)

  printf fmt_r, host, (cores+0 > 0 ? cores : "?"), samples, acpu, mcpu, amem, mmem, net_out, net_in

  # group accumulation
  g = group_key(host)
  G_count[g]++
  G_cores[g]   += cores
  G_samples[g] += samples
  G_acpu[g]    += acpu
  G_mcpu[g]    = (mcpu+0 > G_mcpu[g]+0) ? mcpu : G_mcpu[g]
  G_amem[g]    += amem
  G_mmem[g]    = (mmem+0 > G_mmem[g]+0) ? mmem : G_mmem[g]
  G_max_bws[g] = (max_bw_s+0 > G_max_bws[g]+0) ? max_bw_s : G_max_bws[g]
  G_max_bwr[g] = (max_bw_r+0 > G_max_bwr[g]+0) ? max_bw_r : G_max_bwr[g]
  G_hosts[g]   = G_hosts[g] " " host

  # totals
  T_count++
  T_cores   += cores
  T_samples += samples
  T_acpu    += acpu
  T_mcpu    = (mcpu+0 > T_mcpu+0) ? mcpu : T_mcpu
  T_amem    += amem
  T_mmem    = (mmem+0 > T_mmem+0) ? mmem : T_mmem
  T_max_bws = (max_bw_s+0 > T_max_bws+0) ? max_bw_s : T_max_bws
  T_max_bwr = (max_bw_r+0 > T_max_bwr+0) ? max_bw_r : T_max_bwr

  HOSTS[NR] = host
  HAS_HAP[host]  = has_hap
  HAS_IPVS[host] = has_ipvs
}
END {
  # ---- Per-group ----
  printf "\n%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n", "GROUP", "CORES", "HOSTS", "AVG_CPU", "MAX_CPU", "AVG_MEM%", "MAX_MEM%", "MAX_NET_OUT", "MAX_NET_IN"
  printf "%s\n", "----------------------------------------------------------------------------------------------------"
  for (g in G_count) {
    n = G_count[g]
    nout = (G_max_bws[g]+0 > 0) ? human_bps(G_max_bws[g]) : "-"
    nin  = (G_max_bwr[g]+0 > 0) ? human_bps(G_max_bwr[g]) : "-"
    printf "%-22s %5d %7d %7.2f %7.2f %7.2f %7.2f %12s %12s\n", \
      g, G_cores[g], n, G_acpu[g]/n, G_mcpu[g], G_amem[g]/n, G_mmem[g], nout, nin
  }

  # ---- Totals ----
  printf "\n%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n", "TOTAL", "CORES", "HOSTS", "AVG_CPU", "MAX_CPU", "AVG_MEM%", "MAX_MEM%", "MAX_NET_OUT", "MAX_NET_IN"
  printf "%s\n", "----------------------------------------------------------------------------------------------------"
  if (T_count > 0) {
    nout = (T_max_bws+0 > 0) ? human_bps(T_max_bws) : "-"
    nin  = (T_max_bwr+0 > 0) ? human_bps(T_max_bwr) : "-"
    printf "%-22s %5d %7d %7.2f %7.2f %7.2f %7.2f %12s %12s\n", \
      "(all hosts)", T_cores, T_count, T_acpu/T_count, T_mcpu, T_amem/T_count, T_mmem, nout, nin
  }

  # ---- HAProxy section ----
  any_hap = 0
  for (h in HAP) { any_hap = 1; break }
  if (any_hap) {
    printf "\nHAProxy (FRONTEND-only peak rates):\n"
    printf "%-22s %12s %14s %14s %12s\n", "HOST", "MAX_REQ/s", "MAX_BYTES_IN/s", "MAX_BYTES_OUT/s", "MAX_CUR_SESS"
    printf "%s\n", "----------------------------------------------------------------------------------------------"
    for (i = 1; i <= NR; i++) {
      h = HOSTS[i]
      if (!(h in HAP)) continue
      split(HAP[h], p, "|")
      printf "%-22s %12s %14s %14s %12s\n", h, p[1], p[2], p[3], p[4]
    }
  }

  # ---- IPVS section ----
  any_ipvs = 0
  for (h in IPVS) { any_ipvs = 1; break }
  if (any_ipvs) {
    printf "\nIPVS / LVS (service-level peak rates):\n"
    printf "%-22s %12s %14s %14s %14s\n", "HOST", "MAX_CONN/s", "MAX_BPS_IN", "MAX_BPS_OUT", "MAX_ACT_CONNS"
    printf "%s\n", "----------------------------------------------------------------------------------------------"
    for (i = 1; i <= NR; i++) {
      h = HOSTS[i]
      if (!(h in IPVS)) continue
      split(IPVS[h], p, "|")
      printf "%-22s %12s %14s %14s %14s\n", h, p[1], p[2], p[3], p[4]
    }
  }
  printf "\n"
}
' <<<"$ROWS"
