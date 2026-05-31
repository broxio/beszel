#!/usr/bin/env bash
# stats-api.sh — snapshot per-system / per-group / total stats from beszel via PocketBase REST.
#
# Same args + same output shape as stats.sh, but goes through the hub HTTP API
# instead of touching SQLite directly. Run from any machine that can reach the hub.
#
# Usage:
#   ./stats-api.sh [HOURS] [HOST_GLOB]
#
# Env (required):
#   BESZEL_URL          Hub base URL, e.g. https://hub.example.com
#   BESZEL_TOKEN        PocketBase auth token (preferred)
#     -- OR --
#   BESZEL_EMAIL        Superuser email
#   BESZEL_PASSWORD     Superuser password    (script will exchange for a token)
#
# Examples:
#   BESZEL_URL=https://hub BESZEL_TOKEN=xxx ./stats-api.sh 6 'ha-web*'
#   BESZEL_URL=https://hub BESZEL_EMAIL=a@b.c BESZEL_PASSWORD=... ./stats-api.sh

set -euo pipefail

HOURS="${1:-6}"
GLOB="${2:-*}"

# shellcheck source=lib/beszel-auth.sh
source "$(dirname "$0")/lib/beszel-auth.sh"
beszel_load_env          # fill creds from ~/.config/beszel/env (or $BESZEL_ENV_FILE) if unset

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "stats-api.sh: $bin not found in PATH" >&2; exit 1; }
done
case "$HOURS" in ''|*[!0-9]*) echo "stats-api.sh: HOURS must be a positive integer" >&2; exit 1 ;; esac
if (( HOURS < 1 )); then echo "stats-api.sh: HOURS must be >= 1" >&2; exit 1; fi

if   (( HOURS <= 8   )); then BUCKET='10m'
elif (( HOURS <= 48  )); then BUCKET='20m'
elif (( HOURS <= 240 )); then BUCKET='120m'
else                          BUCKET='480m'
fi

# ---- auth: $BESZEL_TOKEN, on-disk token cache, or fresh login (see lib/beszel-auth.sh) ----
TOKEN="$(beszel_token)" || exit 1
BASE="${BESZEL_URL%/}"
AUTH=(-H "Authorization: Bearer $TOKEN")

# ---- list systems matching glob ----
SYS_JSON="$(curl -fsS "${AUTH[@]}" \
  "$BASE/api/collections/systems/records?perPage=500&fields=id,name,info&sort=name")"

# Filter client-side by glob using bash's own glob matching (avoids regex-escape
# headaches). Build {id, name, cores} list of matches.
# cores lives in info JSON (key c); fall back to thread count (t) when absent.
mapfile -t SYS_TRIPLES < <(jq -r '.items[] | "\(.id)\t\(.name)\t\((.info.c // 0) as $c | if $c > 0 then $c else (.info.t // 0) end)"' <<<"$SYS_JSON")
MATCH_TRIPLES=()
for triple in "${SYS_TRIPLES[@]}"; do
  IFS=$'\t' read -r _ name _ <<<"$triple"
  # shellcheck disable=SC2053
  if [[ "$name" == $GLOB ]]; then
    MATCH_TRIPLES+=("$triple")
  fi
done
MATCH_JSON="$(printf '%s\n' "${MATCH_TRIPLES[@]}" | jq -Rsc 'split("\n") | map(select(length>0)) | map(split("\t") | {id: .[0], name: .[1], cores: (.[2]|tonumber? // 0)})')"

SYS_COUNT="$(jq 'length' <<<"$MATCH_JSON")"
if (( SYS_COUNT == 0 )); then
  echo "(no systems match glob: $GLOB)"
  exit 0
fi

# PocketBase uses RFC3339-ish; use UTC ISO with seconds.
# Date math: "now - HOURS hours" in UTC.
if date -u -v-1H +%s >/dev/null 2>&1; then
  SINCE_ISO="$(date -u -v-"${HOURS}"H +"%Y-%m-%d %H:%M:%S")"
else
  SINCE_ISO="$(date -u -d "-${HOURS} hours" +"%Y-%m-%d %H:%M:%S")"
fi

# Build system='id1' || system='id2' || ... only when the matched set is small;
# a long filter overflows the request URL -> HTTP 400. For large selections
# (e.g. glob '*') fetch all in the window and filter client-side via SYS_MAP.
if (( SYS_COUNT <= 30 )); then
  SYS_FILTER="$(jq -r 'map("system=\"\(.id)\"") | join(" || ")' <<<"$MATCH_JSON")"
  FILTER="type='${BUCKET}' && created >= '${SINCE_ISO}' && (${SYS_FILTER})"
else
  FILTER="type='${BUCKET}' && created >= '${SINCE_ISO}'"
fi
FILTER_ENC="$(jq -rn --arg f "$FILTER" '$f|@uri')"

# ---- paginate system_stats ----
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
PAGE=1
> "$TMP_DIR/all.json"
while :; do
  CHUNK="$(curl -fsS "${AUTH[@]}" \
    "$BASE/api/collections/system_stats/records?perPage=500&page=${PAGE}&fields=system,stats&filter=${FILTER_ENC}")"
  jq -c '.items[]' <<<"$CHUNK" >> "$TMP_DIR/all.json"
  TOTAL_PAGES="$(jq '.totalPages' <<<"$CHUNK")"
  if (( PAGE >= TOTAL_PAGES )); then break; fi
  PAGE=$((PAGE+1))
done

if [[ ! -s "$TMP_DIR/all.json" ]]; then
  echo "(no system_stats rows for type=${BUCKET}, window=${HOURS}h, glob=${GLOB})"
  exit 0
fi

# ---- aggregate in jq ----
# Build per-host aggregates first, then emit TSV (same shape as stats.sh consumes).
SYS_MAP="$(jq -c 'map({(.id): {name, cores}}) | add' <<<"$MATCH_JSON")"

ROWS="$(jq -rs --argjson m "$SYS_MAP" '
  def num($x): if $x == null then 0 else ($x | tonumber? // 0) end;
  # drop systems outside the glob (client-side filter), then group + summarize
  map(select($m[.system] != null))
  | group_by(.system)
  | map(
      {
        host:    ($m[.[0].system].name  // "?"),
        cores:   ($m[.[0].system].cores // 0),
        samples: length,
        avg_cpu: (map(num(.stats.cpu))  | add / length),
        max_cpu: (map([num(.stats.cpum), num(.stats.cpu)] | max) | max),
        avg_mp:  (map(num(.stats.mp))   | add / length),
        max_mp:  (map(num(.stats.mp))   | max),
        max_ns:  (map([num(.stats.nsm), num(.stats.ns)] | max) | max),
        max_nr:  (map([num(.stats.nrm), num(.stats.nr)] | max) | max),
        max_bws: (map([num(.stats.bm[0]?), num(.stats.b[0]?)] | max) | max),
        max_bwr: (map([num(.stats.bm[1]?), num(.stats.b[1]?)] | max) | max),
        has_hap: (any(.stats.hap != null)),
        has_ipvs:(any(.stats.ipvs != null))
      }
    )
  | sort_by(.host)
  | .[]
  | [
      .host,
      .cores,
      .samples,
      (.avg_cpu|tostring|.[0:6]),
      (.max_cpu|tostring|.[0:6]),
      (.avg_mp |tostring|.[0:6]),
      (.max_mp |tostring|.[0:6]),
      (.max_ns |tostring|.[0:6]),
      (.max_nr |tostring|.[0:6]),
      (.max_bws|tostring),
      (.max_bwr|tostring),
      (if .has_hap then 1 else 0 end),
      (if .has_ipvs then 1 else 0 end)
    ]
  | @tsv
' "$TMP_DIR/all.json")"

# HAProxy per-host: max of FRONTEND rates
HAP_ROWS="$(jq -rs --argjson m "$SYS_MAP" '
  def num($x): if $x == null then 0 else ($x | tonumber? // 0) end;
  map(select(.stats.hap != null and $m[.system] != null))
  | group_by(.system)
  | map(
      {
        host: ($m[.[0].system].name // "?"),
        max_rr:  (map(.stats.hap | map(select(.t=="FRONTEND") | num(.rr )) | max // 0) | max),
        max_bir: (map(.stats.hap | map(select(.t=="FRONTEND") | num(.bir)) | max // 0) | max),
        max_bor: (map(.stats.hap | map(select(.t=="FRONTEND") | num(.bor)) | max // 0) | max),
        max_sc:  (map(.stats.hap | map(select(.t=="FRONTEND") | num(.sc )) | max // 0) | max)
      }
    )
  | sort_by(.host)
  | .[]
  | [.host, (.max_rr|tostring), (.max_bir|tostring), (.max_bor|tostring), (.max_sc|tostring)]
  | @tsv
' "$TMP_DIR/all.json")"

# IPVS per-host: max of service-level rates from the top-level ipvs object
IPVS_ROWS="$(jq -rs --argjson m "$SYS_MAP" '
  def num($x): if $x == null then 0 else ($x | tonumber? // 0) end;
  map(select(.stats.ipvs != null and $m[.system] != null))
  | group_by(.system)
  | map(
      {
        host: ($m[.[0].system].name // "?"),
        max_cps: (map(num(.stats.ipvs.cps)) | max),
        max_bir: (map(num(.stats.ipvs.bir)) | max),
        max_bor: (map(num(.stats.ipvs.bor)) | max),
        max_ac:  (map(num(.stats.ipvs.ac))  | max)
      }
    )
  | sort_by(.host)
  | .[]
  | [.host, (.max_cps|tostring), (.max_bir|tostring), (.max_bor|tostring), (.max_ac|tostring)]
  | @tsv
' "$TMP_DIR/all.json")"

# ---- render (same awk block as stats.sh) ----
echo
echo "beszel stats — window=${HOURS}h  bucket=${BUCKET}  glob=${GLOB}  hub=${BASE}"
echo

HAP_ROWS_E="$HAP_ROWS" IPVS_ROWS_E="$IPVS_ROWS" awk -F'\t' '
function group_key(h,   k) { k = h; sub(/-[0-9]+$/, "", k); return k }
function human_bps(bps,   units, i, v) {
  split("bps Kbps Mbps Gbps Tbps", units, " ")
  v = bps * 8.0; i = 1
  while (v >= 1000 && i < 5) { v /= 1000; i++ }
  return sprintf("%.2f %s", v, units[i])
}
BEGIN {
  n = split(ENVIRON["HAP_ROWS_E"], hlines, "\n")
  for (i = 1; i <= n; i++) { if (hlines[i] == "") continue; split(hlines[i], a, "\t"); HAP[a[1]] = a[2] "|" a[3] "|" a[4] "|" a[5] }
  n = split(ENVIRON["IPVS_ROWS_E"], ilines, "\n")
  for (i = 1; i <= n; i++) { if (ilines[i] == "") continue; split(ilines[i], a, "\t"); IPVS[a[1]] = a[2] "|" a[3] "|" a[4] "|" a[5] }

  fmt_h = "%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n"
  printf fmt_h, "HOST", "CORES", "SAMPLES", "AVG_CPU", "MAX_CPU", "AVG_MEM%", "MAX_MEM%", "MAX_NET_OUT", "MAX_NET_IN"
  printf "%s\n", "----------------------------------------------------------------------------------------------------"
}
{
  host=$1; cores=$2; samples=$3; acpu=$4; mcpu=$5; amem=$6; mmem=$7
  max_ns=$8; max_nr=$9; max_bw_s=$10; max_bw_r=$11
  if (max_bw_s+0 > 0) net_out = human_bps(max_bw_s); else net_out = sprintf("%s MB/s", max_ns)
  if (max_bw_r+0 > 0) net_in  = human_bps(max_bw_r); else net_in  = sprintf("%s MB/s", max_nr)
  printf "%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n", host, (cores+0 > 0 ? cores : "?"), samples, acpu, mcpu, amem, mmem, net_out, net_in

  g = group_key(host)
  G_count[g]++; G_cores[g] += cores; G_samples[g] += samples
  G_acpu[g] += acpu
  G_mcpu[g] = (mcpu+0 > G_mcpu[g]+0) ? mcpu : G_mcpu[g]
  G_amem[g] += amem
  G_mmem[g] = (mmem+0 > G_mmem[g]+0) ? mmem : G_mmem[g]
  G_max_bws[g] = (max_bw_s+0 > G_max_bws[g]+0) ? max_bw_s : G_max_bws[g]
  G_max_bwr[g] = (max_bw_r+0 > G_max_bwr[g]+0) ? max_bw_r : G_max_bwr[g]

  T_count++; T_cores += cores
  T_acpu += acpu
  T_mcpu = (mcpu+0 > T_mcpu+0) ? mcpu : T_mcpu
  T_amem += amem
  T_mmem = (mmem+0 > T_mmem+0) ? mmem : T_mmem
  T_max_bws = (max_bw_s+0 > T_max_bws+0) ? max_bw_s : T_max_bws
  T_max_bwr = (max_bw_r+0 > T_max_bwr+0) ? max_bw_r : T_max_bwr

  HOSTS[NR] = host
}
END {
  printf "\n%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n", "GROUP", "CORES", "HOSTS", "AVG_CPU", "MAX_CPU", "AVG_MEM%", "MAX_MEM%", "MAX_NET_OUT", "MAX_NET_IN"
  printf "%s\n", "----------------------------------------------------------------------------------------------------"
  for (g in G_count) {
    n = G_count[g]
    nout = (G_max_bws[g]+0 > 0) ? human_bps(G_max_bws[g]) : "-"
    nin  = (G_max_bwr[g]+0 > 0) ? human_bps(G_max_bwr[g]) : "-"
    printf "%-22s %5d %7d %7.2f %7.2f %7.2f %7.2f %12s %12s\n", g, G_cores[g], n, G_acpu[g]/n, G_mcpu[g], G_amem[g]/n, G_mmem[g], nout, nin
  }

  printf "\n%-22s %5s %7s %7s %7s %7s %7s %12s %12s\n", "TOTAL", "CORES", "HOSTS", "AVG_CPU", "MAX_CPU", "AVG_MEM%", "MAX_MEM%", "MAX_NET_OUT", "MAX_NET_IN"
  printf "%s\n", "----------------------------------------------------------------------------------------------------"
  if (T_count > 0) {
    nout = (T_max_bws+0 > 0) ? human_bps(T_max_bws) : "-"
    nin  = (T_max_bwr+0 > 0) ? human_bps(T_max_bwr) : "-"
    printf "%-22s %5d %7d %7.2f %7.2f %7.2f %7.2f %12s %12s\n", "(all hosts)", T_cores, T_count, T_acpu/T_count, T_mcpu, T_amem/T_count, T_mmem, nout, nin
  }

  any = 0; for (h in HAP) { any = 1; break }
  if (any) {
    printf "\nHAProxy (FRONTEND-only peak rates):\n"
    printf "%-22s %12s %14s %14s %12s\n", "HOST", "MAX_REQ/s", "MAX_BYTES_IN/s", "MAX_BYTES_OUT/s", "MAX_CUR_SESS"
    printf "%s\n", "----------------------------------------------------------------------------------------------"
    for (i = 1; i <= NR; i++) { h = HOSTS[i]; if (!(h in HAP)) continue; split(HAP[h], p, "|"); printf "%-22s %12s %14s %14s %12s\n", h, p[1], p[2], p[3], p[4] }
  }

  any = 0; for (h in IPVS) { any = 1; break }
  if (any) {
    printf "\nIPVS / LVS (service-level peak rates):\n"
    printf "%-22s %12s %14s %14s %14s\n", "HOST", "MAX_CONN/s", "MAX_BPS_IN", "MAX_BPS_OUT", "MAX_ACT_CONNS"
    printf "%s\n", "----------------------------------------------------------------------------------------------"
    for (i = 1; i <= NR; i++) { h = HOSTS[i]; if (!(h in IPVS)) continue; split(IPVS[h], p, "|"); printf "%-22s %12s %14s %14s %14s\n", h, p[1], p[2], p[3], p[4] }
  }
  printf "\n"
}
' <<<"$ROWS"
