#!/usr/bin/env bash
# capacity.sh — CPU & memory capacity-planning snapshot from beszel PocketBase.
#
# Direct-SQLite flavor. Run on the hub host (where pb_data/data.db lives).
# Unlike stats.sh (avg/max only), this reports PERCENTILES for sizing and
# converts CPU% into REAL vCPU/RAM consumption for consolidation planning.
#
# Usage:
#   ./capacity.sh [HOURS] [HOST_GLOB] [--csv]
#
# Examples:
#   ./capacity.sh                  # last 6h, all systems, table output
#   ./capacity.sh 24 'app*'        # last 24h, hosts matching app*
#   ./capacity.sh 720 '*' --csv    # last 30d, all hosts, CSV to stdout
#
# Env:
#   BESZEL_DB    Path to PocketBase SQLite db (default: ./pb_data/data.db)
#   BUCKET       Force rollup bucket (1m|10m|20m|120m|480m); default auto by window.
#                1m gives minute-precise peaks but beszel only keeps ~1-2h of it.
#
# What it measures (per host, over the window):
#   CPU:  vCPU allocation, Avg%, P95% (sizing), P99% (burst), Max% (incident),
#         and real cores used = vCPU x util/100 at avg / p95 / peak. Steal%.
#   MEM:  total GB, used GB (avg / p95 / max, REAL used excl. buff-cache),
#         used% avg/max, swap used GB max.
#
# Sizing guidance: Avg=baseline, P95=right-size target, P99=burst headroom,
# Max=incident investigation only (one spike should not drive provisioning).

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
DB="${BESZEL_DB:-./pb_data/data.db}"

if ! command -v sqlite3 >/dev/null; then
  echo "capacity.sh: sqlite3 not found in PATH" >&2; exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "capacity.sh: db not found at $DB (set BESZEL_DB)" >&2; exit 1
fi
case "$HOURS" in ''|*[!0-9]*) echo "capacity.sh: HOURS must be a positive integer" >&2; exit 1 ;; esac
if (( HOURS < 1 )); then echo "capacity.sh: HOURS must be >= 1" >&2; exit 1; fi

# Pick rollup bucket that yields a usable sample count without scanning raw 1m.
if [[ -n "${BUCKET:-}" ]]; then
  :
elif (( HOURS <= 24  )); then BUCKET='10m'
elif (( HOURS <= 96  )); then BUCKET='20m'
elif (( HOURS <= 480 )); then BUCKET='120m'
else                          BUCKET='480m'
fi

# Convert shell glob -> SQL LIKE pattern. * -> %, ? -> _, escape existing %/_.
glob_to_like() {
  local g="$1" out="" i ch
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

# Per-sample rows (NOT pre-aggregated) so awk can compute percentiles.
# vCPU = info.c (cores) else info.t (threads). steal = cpub[3].
SQL=$(cat <<SQL
SELECT
  s.name                                                              AS host,
  COALESCE(CAST(json_extract(s.info, '\$.c') AS REAL),
           CAST(json_extract(s.info, '\$.t') AS REAL), 0)            AS vcpu,
  CAST(json_extract(ss.stats, '\$.cpu')  AS REAL)                     AS cpu,
  COALESCE(CAST(json_extract(ss.stats, '\$.cpum') AS REAL),
           CAST(json_extract(ss.stats, '\$.cpu')  AS REAL))          AS cpumax,
  COALESCE(CAST(json_extract(ss.stats, '\$.cpub[3]') AS REAL), 0)     AS steal,
  COALESCE(CAST(json_extract(ss.stats, '\$.m')  AS REAL), 0)          AS mem_total,
  COALESCE(CAST(json_extract(ss.stats, '\$.mu') AS REAL), 0)          AS mem_used,
  COALESCE(CAST(json_extract(ss.stats, '\$.mp') AS REAL), 0)          AS mem_pct,
  COALESCE(CAST(json_extract(ss.stats, '\$.su') AS REAL), 0)          AS swap_used,
  ss.created                                                          AS created
FROM system_stats ss
JOIN systems s ON s.id = ss.system
WHERE ss.type = '${BUCKET}'
  AND ss.created >= datetime('now', '${SINCE}')
  AND s.name LIKE '${LIKE}' ESCAPE '\\'
  AND json_extract(ss.stats, '\$.cpu') IS NOT NULL
ORDER BY s.name;
SQL
)

ROWS="$(sqlite3 -separator $'\t' "$DB" "$SQL")"
if [[ -z "$ROWS" ]]; then
  echo "(no matching system_stats rows for type=${BUCKET}, window=${HOURS}h, glob=${GLOB})"
  exit 0
fi

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TZ_OFFSET="${TZ_OFFSET:-8}"   # local display offset in hours (default UTC+8); TZ_OFFSET=0 for UTC
OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"

FORMAT="$FORMAT" WINDOW="$HOURS" BUCKET="$BUCKET" GLOB="$GLOB" DBPATH="$DB" NOW="$NOW_ISO" HEADER="$HEADER" PEAKT="$PEAKT" OFF_MIN="$OFF_MIN" TZLABEL="$TZLABEL" awk -F'\t' '
# ---- nearest-rank percentile over 1-based local array a[1..n] (sorted in place) ----
function isort(a, n,   i, j, key) {
  for (i = 2; i <= n; i++) { key = a[i]; j = i - 1
    while (j >= 1 && a[j] > key) { a[j+1] = a[j]; j-- }
    a[j+1] = key }
}
# ---- natural sort key: zero-pad each digit run so ha-bop-2 < ha-bop-10 ----
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
# ---- compact a PB timestamp "2026-04-07 17:00:01.947Z" -> "04-07 17:00" ----
# ---- timezone shift of a UTC PB timestamp; OFF_MIN env = local offset minutes ----
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
function tzshift(t,   Y,Mo,D,H,Mi,S,days,secs,r,hh,mm) {     # -> "YYYY-MM-DD HH:MM" local
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
function pktime(t,   s) { s=tzshift(t); return (s=="-" ? "-" : substr(s,6)) }   # "MM-DD HH:MM"
function pct(a, n, p,   r) {          # a must be pre-sorted ascending
  if (n == 0) return 0
  r = int(p/100.0 * n + 0.9999999)    # ceil
  if (r < 1) r = 1; if (r > n) r = n
  return a[r]
}
{
  host=$1; vcpu=$2+0; cpu=$3+0; cpumax=$4+0; steal=$5+0
  mtot=$6+0; mused=$7+0; mpct=$8+0; swap=$9+0; created=$10

  if (!(host in seen)) { seen[host]=1; order[++H]=host; VCPU[host]=vcpu }
  n=++N[host]
  CPU[host SUBSEP n]=cpu          # per-sample cpu series (for percentiles)
  MU[host SUBSEP n]=mused         # per-sample mem-used series
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
  # ---- natural-sort host order by name ----
  for (i=2; i<=H; i++) { k=order[i]; kk=natkey(k); j=i-1
    while (j>=1 && natkey(order[j])>kk) { order[j+1]=order[j]; j-- }
    order[j+1]=k }
  # ---- compute per-host percentiles ----
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

  # ---- table output ----
  printf "\nbeszel capacity — window=%sh  bucket=%s  glob=%s  db=%s\n",
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
