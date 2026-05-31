#!/usr/bin/env bash
# peak-recorder.sh — harvest minute-precise CPU/memory peaks from beszel before
# they age out, and append record-breaking events to a CSV that outlives PB.
#
# WHY: beszel rolls up 1m records into 10m/20m/... keeping only the peak *value*,
# never the time it occurred, and deletes 1m records after 1 hour. To keep a
# precise (minute-resolution) record of when each host peaked, you must capture
# the 1m data yourself before it's pruned. Run this on a timer MORE OFTEN than
# the 1h retention (every 10-15 min recommended) so no minute is missed.
#
# Each run reads the recent 1m window, finds each host's max CPU% and max mem-used
# (with the minute each happened), and APPENDS a row only when that beats the
# host's previous all-time peak already in the file. The file is its own state.
#
# Usage:
#   ./peak-recorder.sh [HOST_GLOB]
#
# Env (required):
#   BESZEL_URL          Hub base URL, e.g. https://hub.example.com
#   BESZEL_TOKEN        PocketBase auth token (preferred)
#     -- OR --
#   BESZEL_EMAIL / BESZEL_PASSWORD   Superuser creds (exchanged for a token)
# Env (optional):
#   PEAKS_FILE          Output CSV (default: ./peaks.csv)
#   LOOKBACK_MIN        Minutes of 1m history to scan (default: 70; keep > cron gap)
#   TZ_OFFSET           peak_at display offset in hours (default: 8 = UTC+8; 0 = UTC).
#                       detected_at stays UTC (...Z); peak_at is local, tz column records the offset.
#
# Cron example (every 15 min):
#   */15 * * * * BESZEL_URL=https://hub BESZEL_TOKEN=xxx PEAKS_FILE=/var/lib/beszel/peaks.csv \
#                /path/peak-recorder.sh '*' >> /var/log/beszel-peaks.log 2>&1
#
# Query current all-time peaks from the file:
#   awk -F, 'NR>1 && $3=="cpu_pct"   && $4>c[$2]{c[$2]=$4; t[$2]=$6} END{for(h in c) print h, c[h]"%", t[h]}' peaks.csv
#   awk -F, 'NR>1 && $3=="mem_used_gb"&& $4>m[$2]{m[$2]=$4; t[$2]=$6} END{for(h in m) print h, m[h]"G", t[h]}' peaks.csv

set -euo pipefail

GLOB="${1:-*}"
PEAKS_FILE="${PEAKS_FILE:-./peaks.csv}"
LOOKBACK_MIN="${LOOKBACK_MIN:-70}"

# shellcheck source=lib/beszel-auth.sh
source "$(dirname "$0")/lib/beszel-auth.sh"
beszel_load_env          # fill creds from ~/.config/beszel/env (or $BESZEL_ENV_FILE) if unset
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "peak-recorder.sh: $bin not found in PATH" >&2; exit 1; }
done
case "$LOOKBACK_MIN" in ''|*[!0-9]*) echo "peak-recorder.sh: LOOKBACK_MIN must be an integer" >&2; exit 1 ;; esac

# ---- auth: $BESZEL_TOKEN, on-disk token cache, or fresh login (see lib/beszel-auth.sh) ----
TOKEN="$(beszel_token)" || exit 1
BASE="${BESZEL_URL%/}"
AUTH=(-H "Authorization: Bearer $TOKEN")

# ---- systems matching glob (need info for vCPU) ----
SYS_JSON="$(curl -fsS "${AUTH[@]}" \
  "$BASE/api/collections/systems/records?perPage=500&fields=id,name,info&sort=name")"
MATCH_JSON="$(jq -c --arg g "$GLOB" '
  [ .items[] | { id, name, vcpu: ((.info.c // 0) as $c | if $c > 0 then $c else (.info.t // 0) end) } ]
  | [ .[] | select(.name | test("^" + ($g|gsub("\\*";".*")|gsub("\\?";".")) + "$")) ]' <<<"$SYS_JSON")"
if (( $(jq 'length' <<<"$MATCH_JSON") == 0 )); then
  echo "(no systems match glob: $GLOB)"; exit 0
fi
SYS_MAP="$(jq -c 'map({(.id): {name, vcpu}}) | add' <<<"$MATCH_JSON")"
SYS_COUNT="$(jq 'length' <<<"$MATCH_JSON")"

# ---- since = now - LOOKBACK_MIN minutes (UTC) ----
if date -u -v-1M +%s >/dev/null 2>&1; then
  SINCE_ISO="$(date -u -v-"${LOOKBACK_MIN}"M +"%Y-%m-%d %H:%M:%S")"
else
  SINCE_ISO="$(date -u -d "-${LOOKBACK_MIN} minutes" +"%Y-%m-%d %H:%M:%S")"
fi
# Only constrain by system id when the matched set is small; a long
# "system=... || ..." filter overflows the request URL -> HTTP 400. For large
# selections (e.g. glob '*') fetch all and filter client-side via SYS_MAP.
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
  CHUNK="$(curl -fsS "${AUTH[@]}" \
    "$BASE/api/collections/system_stats/records?perPage=500&page=${PAGE}&fields=system,stats,created&filter=${FILTER_ENC}")"
  jq -c '.items[]' <<<"$CHUNK" >> "$TMP_DIR/all.json"
  TOTAL_PAGES="$(jq '.totalPages' <<<"$CHUNK")"
  (( PAGE >= TOTAL_PAGES )) && break
  PAGE=$((PAGE+1))
done
if [[ ! -s "$TMP_DIR/all.json" ]]; then
  echo "($(date -u +%H:%M) no 1m records in last ${LOOKBACK_MIN}m for glob=$GLOB — is 1m retention shorter than your cron gap?)"
  exit 0
fi

# ---- per-host observed peak (value + the minute it occurred) ----
# OBS columns: host  cpu  cpu_at  vcpu  cores_at_peak  mem  mem_at  mtot  mpct
OBS="$(jq -rs --argjson m "$SYS_MAP" '
  def num($x): if $x==null then 0 else ($x|tonumber? // 0) end;
  map(select($m[.system] != null))          # drop systems outside the glob (client-side filter)
  | group_by(.system)
  | map(
      ($m[.[0].system] // {name:"?",vcpu:0}) as $s
      | (max_by(num(.stats.cpu))) as $c
      | (max_by(num(.stats.mu)))  as $u
      | [ $s.name,
          num($c.stats.cpu),
          ($c.created // ""),
          $s.vcpu,
          ($s.vcpu * num($c.stats.cpu) / 100),
          num($u.stats.mu),
          ($u.created // ""),
          num($u.stats.m),
          num($u.stats.mp)
        ]
    )
  | .[] | @tsv
' "$TMP_DIR/all.json")"

[[ -z "$OBS" ]] && { echo "($(date -u +%H:%M) no usable samples)"; exit 0; }

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TZ_OFFSET="${TZ_OFFSET:-8}"   # peak_at local offset in hours (default UTC+8); TZ_OFFSET=0 for UTC
OFF_MIN="$(awk "BEGIN{print int(${TZ_OFFSET}*60)}")"
TZLABEL="$(awk "BEGIN{o=${TZ_OFFSET}+0; printf (o>=0?\"+%g\":\"%g\"), o}")"
HEADER="detected_at,host,metric,value,unit,peak_at,tz,detail"
[[ -f "$PEAKS_FILE" ]] || { mkdir -p "$(dirname "$PEAKS_FILE")"; echo "$HEADER" > "$PEAKS_FILE"; }

# ---- compare observed vs all-time peaks already in the file; append new records ----
NEW="$(NOW="$NOW_ISO" OFF_MIN="$OFF_MIN" TZLABEL="$TZLABEL" awk -F'\t' -v pf="$PEAKS_FILE" '
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
  function minute(t,   Y,Mo,D,H,Mi,S,days,secs,r,hh,mm) {   # UTC -> local "YYYY-MM-DD HH:MM"
    if (t=="") return ""
    Y=substr(t,1,4)+0; Mo=substr(t,6,2)+0; D=substr(t,9,2)+0
    H=substr(t,12,2)+0; Mi=substr(t,15,2)+0; S=substr(t,18,2)+0
    days=days_from_civil(Y,Mo,D)
    secs=days*86400+H*3600+Mi*60+S+(ENVIRON["OFF_MIN"]+0)*60
    days=_fdiv(secs,86400); r=secs-days*86400
    hh=int(r/3600); mm=int((r%3600)/60)
    civil_from_days(days)
    return sprintf("%04d-%02d-%02d %02d:%02d",_cy,_cm,_cd,hh,mm)
  }
  BEGIN {
    # load prior all-time peaks per host from the CSV (self-state)
    FS=","
    while ((getline line < pf) > 0) {
      n=split(line, f, ",")
      if (f[2]=="host" || n<6) continue
      if (f[3]=="cpu_pct"     && f[4]+0 > pcpu[f[2]]+0) pcpu[f[2]]=f[4]+0
      if (f[3]=="mem_used_gb" && f[4]+0 > pmem[f[2]]+0) pmem[f[2]]=f[4]+0
    }
    close(pf)
    FS="\t"
    now=ENVIRON["NOW"]
  }
  {
    host=$1; cpu=$2+0; cpu_at=$3; vcpu=$4+0; cores=$5+0
    mem=$6+0; mem_at=$7; mtot=$8+0; mpct=$9+0
    if (cpu > pcpu[host]+0) {
      printf "%s,%s,cpu_pct,%.2f,%%,%s,%s,cores=%.2f;vcpu=%g\n",
        now, host, cpu, minute(cpu_at), ENVIRON["TZLABEL"], cores, vcpu
    }
    if (mem > pmem[host]+0) {
      printf "%s,%s,mem_used_gb,%.2f,GB,%s,%s,total=%.1fG;pct=%.1f\n",
        now, host, mem, minute(mem_at), ENVIRON["TZLABEL"], mtot, mpct
    }
  }
' <<<"$OBS")"

if [[ -n "$NEW" ]]; then
  printf '%s\n' "$NEW" >> "$PEAKS_FILE"
  echo "$(date -u +%H:%M) recorded $(printf '%s\n' "$NEW" | grep -c . ) new peak(s) -> $PEAKS_FILE"
  printf '%s\n' "$NEW"
else
  echo "$(date -u +%H:%M) no new peaks (current records hold)"
fi
