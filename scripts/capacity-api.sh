#!/usr/bin/env bash
# capacity-api.sh — CPU & memory capacity-planning snapshot via PocketBase REST.
#
# Same args + same output as capacity.sh, but goes through the hub HTTP API
# instead of touching SQLite directly. Run from any machine that can reach the hub.
#
# Usage:
#   ./capacity-api.sh [HOURS] [HOST_GLOB] [--csv]
#
# Env (required):
#   BESZEL_URL          Hub base URL, e.g. https://hub.example.com
#   BESZEL_TOKEN        PocketBase auth token (preferred)
#     -- OR --
#   BESZEL_EMAIL        Superuser email
#   BESZEL_PASSWORD     Superuser password    (script exchanges for a token)
# Env (optional):
#   BUCKET              Force rollup bucket (1m|10m|20m|120m|480m); default auto.
#                       1m = minute-precise peaks but beszel keeps only ~1-2h of it.
#
# Examples:
#   BESZEL_URL=https://hub BESZEL_TOKEN=xxx ./capacity-api.sh 6 'app*'
#   BESZEL_URL=https://hub BESZEL_EMAIL=a@b.c BESZEL_PASSWORD=... ./capacity-api.sh 720 '*' --csv
#
# Measures the same things as capacity.sh: vCPU allocation, CPU% avg/P95/P99/max,
# real cores used (vCPU x util), steal%, real memory GB (used avg/p95/max), swap.
# Avg=baseline, P95=sizing, P99=burst, Max=incident.

set -euo pipefail

HOURS="${1:-6}"
GLOB="${2:-*}"
FORMAT="table"
HEADER=1
PEAKT=0
for a in "$@"; do
  [[ "$a" == "--csv" ]] && FORMAT="csv"
  [[ "$a" == "--no-header" ]] && HEADER=0   # for appending CSV to a history file
  [[ "$a" == "--peak-time" ]] && PEAKT=1    # experimental: show when CPU/mem peaked
done

# shellcheck source=lib/beszel-auth.sh
source "$(dirname "$0")/lib/beszel-auth.sh"
beszel_load_env          # fill creds from ~/.config/beszel/env (or $BESZEL_ENV_FILE) if unset
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "capacity-api.sh: $bin not found in PATH" >&2; exit 1; }
done
case "$HOURS" in ''|*[!0-9]*) echo "capacity-api.sh: HOURS must be a positive integer" >&2; exit 1 ;; esac
if (( HOURS < 1 )); then echo "capacity-api.sh: HOURS must be >= 1" >&2; exit 1; fi

if [[ -n "${BUCKET:-}" ]]; then
  :
elif (( HOURS <= 24  )); then BUCKET='10m'
elif (( HOURS <= 96  )); then BUCKET='20m'
elif (( HOURS <= 480 )); then BUCKET='120m'
else                          BUCKET='480m'
fi

# ---- auth: $BESZEL_TOKEN, on-disk token cache, or fresh login (see lib/beszel-auth.sh) ----
TOKEN="$(beszel_token)" || exit 1
BASE="${BESZEL_URL%/}"
AUTH=(-H "Authorization: Bearer $TOKEN")

# ---- list systems matching glob (need info for cores/threads -> vCPU) ----
SYS_JSON="$(curl -fsS "${AUTH[@]}" \
  "$BASE/api/collections/systems/records?perPage=500&fields=id,name,info&sort=name")"

# Filter client-side by glob using bash's own matching. Build {id,name,vcpu}.
# vCPU = info.c (cores) if > 0 else info.t (threads).
MATCH_JSON="$(jq -c --arg g "$GLOB" '
  [ .items[]
    | { id, name,
        vcpu: ((.info.c // 0) as $c | if $c > 0 then $c else (.info.t // 0) end) }
  ]' <<<"$SYS_JSON" \
  | jq -c --arg g "$GLOB" '[ .[] | select(.name | test("^" + ($g|gsub("\\*";".*")|gsub("\\?";".")) + "$")) ]')"

SYS_COUNT="$(jq 'length' <<<"$MATCH_JSON")"
if (( SYS_COUNT == 0 )); then
  echo "(no systems match glob: $GLOB)"; exit 0
fi

# "now - HOURS hours" in UTC (BSD date -v ... else GNU date -d ...).
if date -u -v-1H +%s >/dev/null 2>&1; then
  SINCE_ISO="$(date -u -v-"${HOURS}"H +"%Y-%m-%d %H:%M:%S")"
else
  SINCE_ISO="$(date -u -d "-${HOURS} hours" +"%Y-%m-%d %H:%M:%S")"
fi

# Only constrain by system id when the matched set is small; a long
# "system=... || ..." filter overflows the request URL -> HTTP 400. For large
# selections (e.g. glob '*') fetch all in the window and filter client-side.
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
    "$BASE/api/collections/system_stats/records?perPage=500&page=${PAGE}&fields=system,stats,created&filter=${FILTER_ENC}")"
  jq -c '.items[]' <<<"$CHUNK" >> "$TMP_DIR/all.json"
  TOTAL_PAGES="$(jq '.totalPages' <<<"$CHUNK")"
  if (( PAGE >= TOTAL_PAGES )); then break; fi
  PAGE=$((PAGE+1))
done

if [[ ! -s "$TMP_DIR/all.json" ]]; then
  echo "(no system_stats rows for type=${BUCKET}, window=${HOURS}h, glob=${GLOB})"; exit 0
fi

# ---- emit per-sample TSV (same column order capacity.sh's SQL produces) ----
# host, vcpu, cpu, cpumax, steal, mem_total, mem_used, mem_pct, swap_used
SYS_MAP="$(jq -c 'map({(.id): {name, vcpu}}) | add' <<<"$MATCH_JSON")"
ROWS="$(jq -rs --argjson m "$SYS_MAP" '
  def num($x): if $x == null then 0 else ($x | tonumber? // 0) end;
  .[]
  | select(.stats.cpu != null)
  | ($m[.system]) as $s
  | select($s != null)                      # drop systems outside the glob (client-side filter)
  | [ $s.name,
      $s.vcpu,
      num(.stats.cpu),
      ([num(.stats.cpum), num(.stats.cpu)] | max),
      num(.stats.cpub[3]?),
      num(.stats.m),
      num(.stats.mu),
      num(.stats.mp),
      num(.stats.su),
      (.created // "")
    ] | @tsv
' "$TMP_DIR/all.json")"

if [[ -z "$ROWS" ]]; then
  echo "(no system_stats rows for type=${BUCKET}, window=${HOURS}h, glob=${GLOB})"; exit 0
fi

# ---- identical awk block to capacity.sh ----
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TZ_OFFSET="${TZ_OFFSET:-8}"   # local display offset in hours (default UTC+8); TZ_OFFSET=0 for UTC
OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

FORMAT="$FORMAT" WINDOW="$HOURS" BUCKET="$BUCKET" GLOB="$GLOB" DBPATH="$BASE" NOW="$NOW_ISO" HEADER="$HEADER" PEAKT="$PEAKT" OFF_MIN="$OFF_MIN" TZLABEL="$TZLABEL" awk -F'\t' '
function isort(a, n,   i, j, key) {
  for (i = 2; i <= n; i++) { key = a[i]; j = i - 1
    while (j >= 1 && a[j] > key) { a[j+1] = a[j]; j-- }
    a[j+1] = key }
}
function natkey(s,   out, c, i, run) {
  out=""; run=""
  for (i=1; i<=length(s); i++) {
    c=substr(s,i,1)
    if (c ~ /[0-9]/) { run=run c }
    else { if (run!="") { out=out substr("000000000000",1,12-length(run)) run; run="" } out=out c }
  }
  if (run!="") out=out substr("000000000000",1,12-length(run)) run
  return out
}
function pct(a, n, p,   r) {
  if (n == 0) return 0
  r = int(p/100.0 * n + 0.9999999)
  if (r < 1) r = 1; if (r > n) r = n
  return a[r]
}
function _fdiv(a,b) { return (a>=0 ? int(a/b) : -int((-a+b-1)/b)) }
function days_from_civil(y,m,d,   era,yoe,doy,doe) {
  if (m<=2) y--
  era=_fdiv((y>=0?y:y-399),400); yoe=y-era*400
  doy=int((153*(m+(m>2?-3:9))+2)/5)+d-1
  doe=yoe*365+int(yoe/4)-int(yoe/100)+doy
  return era*146097+doe-719468
}
function civil_from_days(z,   era,doe,yoe,y,doy,mp,d,m) {
  z+=719468
  era=_fdiv((z>=0?z:z-146096),146097); doe=z-era*146097
  yoe=int((doe-int(doe/1460)+int(doe/36524)-int(doe/146096))/365)
  y=yoe+era*400; doy=doe-(365*yoe+int(yoe/4)-int(yoe/100))
  mp=int((5*doy+2)/153); d=doy-int((153*mp+2)/5)+1; m=mp+(mp<10?3:-9)
  if (m<=2) y++
  _cy=y; _cm=m; _cd=d
}
function tzshift(t,   Y,Mo,D,H,Mi,S,days,secs,r,hh,mm) {
  if (t=="") return "-"
  Y=substr(t,1,4)+0; Mo=substr(t,6,2)+0; D=substr(t,9,2)+0
  H=substr(t,12,2)+0; Mi=substr(t,15,2)+0; S=substr(t,18,2)+0
  days=days_from_civil(Y,Mo,D)
  secs=days*86400+H*3600+Mi*60+S+(ENVIRON["OFF_MIN"]+0)*60
  days=_fdiv(secs,86400); r=secs-days*86400
  hh=int(r/3600); mm=int((r%3600)/60)
  civil_from_days(days)
  return sprintf("%04d-%02d-%02d %02d:%02d",_cy,_cm,_cd,hh,mm)
}
function pktime(t,   s) { s=tzshift(t); return (s=="-" ? "-" : substr(s,6)) }
{
  host=$1; vcpu=$2+0; cpu=$3+0; cpumax=$4+0; steal=$5+0
  mtot=$6+0; mused=$7+0; mpct=$8+0; swap=$9+0; created=$10
  if (!(host in seen)) { seen[host]=1; order[++H]=host; VCPU[host]=vcpu }
  n=++N[host]
  CPU[host SUBSEP n]=cpu
  MU[host SUBSEP n]=mused
  SUMcpu[host]+=cpu
  SUMmu[host]+=mused; SUMmp[host]+=mpct
  if (cpumax>MAXcpu[host]) { MAXcpu[host]=cpumax; CPUPK_T[host]=created }
  if (steal>MAXsteal[host]) MAXsteal[host]=steal
  if (mused>MAXmu[host])   { MAXmu[host]=mused; MEMPK_T[host]=created }
  if (mpct>MAXmp[host])    MAXmp[host]=mpct
  if (swap>MAXswap[host])  MAXswap[host]=swap
  if (mtot>MTOT[host])     MTOT[host]=mtot
}
END {
  fmt=ENVIRON["FORMAT"]
  peakt=ENVIRON["PEAKT"]+0
  for (i=2; i<=H; i++) { k=order[i]; kk=natkey(k); j=i-1
    while (j>=1 && natkey(order[j])>kk) { order[j+1]=order[j]; j-- }
    order[j+1]=k }
  for (hi=1; hi<=H; hi++) {
    h=order[hi]; n=N[h]
    for (i=1;i<=n;i++){ ca[i]=CPU[h SUBSEP i]; ma[i]=MU[h SUBSEP i] }
    isort(ca,n); isort(ma,n)
    AVGc[h]=SUMcpu[h]/n
    P95c[h]=pct(ca,n,95); P99c[h]=pct(ca,n,99)
    AVGmu[h]=SUMmu[h]/n;  P95mu[h]=pct(ma,n,95)
    AVGmp[h]=SUMmp[h]/n
  }

  if (fmt=="csv") {
    ts=ENVIRON["NOW"]; win=ENVIRON["WINDOW"]; bkt=ENVIRON["BUCKET"]
    if (ENVIRON["HEADER"]+0==1)
      print "ts,window_h,bucket,host,vcpu,samples,cpu_avg_pct,cpu_p95_pct,cpu_p99_pct,cpu_max_pct,steal_max_pct,cores_avg,cores_p95,cores_peak,mem_total_gb,mem_used_avg_gb,mem_used_p95_gb,mem_used_max_gb,mem_pct_avg,mem_pct_max,swap_used_max_gb"
    tv=0; tca=0; tcp=0; tpk=0; tmt=0; tmu=0
    for (hi=1; hi<=H; hi++) {
      h=order[hi]; v=VCPU[h]
      coresA=v*AVGc[h]/100; coresP=v*P95c[h]/100; coresK=v*MAXcpu[h]/100
      printf "%s,%s,%s,%s,%g,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
        ts, win, bkt, h, v, N[h], AVGc[h], P95c[h], P99c[h], MAXcpu[h], MAXsteal[h],
        coresA, coresP, coresK, MTOT[h], AVGmu[h], P95mu[h], MAXmu[h], AVGmp[h], MAXmp[h], MAXswap[h]
      tv+=v; tca+=coresA; tcp+=coresP; tpk+=coresK; tmt+=MTOT[h]; tmu+=AVGmu[h]
    }
    printf "%s,%s,%s,TOTAL,%g,,,,,,,%.3f,%.3f,%.3f,%.2f,%.2f,,,,,\n", ts, win, bkt, tv, tca, tcp, tpk, tmt, tmu
    exit
  }

  printf "\nbeszel capacity — window=%sh  bucket=%s  glob=%s  hub=%s\n",
    ENVIRON["WINDOW"], ENVIRON["BUCKET"], ENVIRON["GLOB"], ENVIRON["DBPATH"]

  printf "\nCPU  (util%% percentiles + real cores used = vCPU x util)\n"
  hrow=sprintf("%-20s %5s %4s %6s %6s %6s %6s %6s | %7s %7s %7s",
    "HOST","vCPU","SMPL","AVG%","P95%","P99%","MAX%","STEAL%","C_avg","C_p95","C_peak")
  if (peakt) hrow=hrow sprintf("  %-12s", "MAX@" ENVIRON["TZLABEL"])
  print hrow
  printf "%s\n", "-------------------------------------------------------------------------------------------------"
  tv=0; tca=0; tcp=0; tpk=0
  for (hi=1; hi<=H; hi++) {
    h=order[hi]; v=VCPU[h]
    coresA=v*AVGc[h]/100; coresP=v*P95c[h]/100; coresK=v*MAXcpu[h]/100
    row=sprintf("%-20s %5g %4d %6.1f %6.1f %6.1f %6.1f %6.1f | %7.2f %7.2f %7.2f",
      h, (v>0?v:0), N[h], AVGc[h], P95c[h], P99c[h], MAXcpu[h], MAXsteal[h], coresA, coresP, coresK)
    if (peakt) row=row sprintf("  %-12s", pktime(CPUPK_T[h]))
    print row
    tv+=v; tca+=coresA; tcp+=coresP; tpk+=coresK
  }
  printf "%s\n", "-------------------------------------------------------------------------------------------------"
  printf "%-20s %5g %4s %6s %6s %6s %6s %6s | %7.2f %7.2f %7.2f\n",
    "TOTAL (provisioned)", tv, "", "", "", "", "", "", tca, tcp, tpk
  if (tv>0) printf "  fleet utilization: avg %.1f%%  p95 %.1f%%  peak %.1f%%  of %g vCPU provisioned\n",
    100*tca/tv, 100*tcp/tv, 100*tpk/tv, tv

  printf "\nMEMORY  (GB — used is REAL, excludes buff/cache; RAM is incompressible)\n"
  mhrow=sprintf("%-20s %8s %9s %9s %9s | %6s %6s %9s",
    "HOST","TOTAL","USED_avg","USED_p95","USED_max","AVG%","MAX%","SWAP_max")
  if (peakt) mhrow=mhrow sprintf("  %-12s", "USED_MAX@" ENVIRON["TZLABEL"])
  print mhrow
  printf "%s\n", "-------------------------------------------------------------------------------------------------"
  tmt=0; tmu=0; tmx=0
  for (hi=1; hi<=H; hi++) {
    h=order[hi]
    mrow=sprintf("%-20s %7.1fG %8.1fG %8.1fG %8.1fG | %6.1f %6.1f %8.1fG",
      h, MTOT[h], AVGmu[h], P95mu[h], MAXmu[h], AVGmp[h], MAXmp[h], MAXswap[h])
    if (peakt) mrow=mrow sprintf("  %-12s", pktime(MEMPK_T[h]))
    print mrow
    tmt+=MTOT[h]; tmu+=AVGmu[h]; tmx+=MAXmu[h]
  }
  printf "%s\n", "-------------------------------------------------------------------------------------------------"
  printf "%-20s %7.1fG %8.1fG %8s %8.1fG |\n", "TOTAL", tmt, tmu, "", tmx
  printf "\n"
}
' <<<"$ROWS"
