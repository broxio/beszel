#!/usr/bin/env bash
# beszel-auth.sh — shared auth helper sourced by the *-api.sh scripts.
#
# Goals (for ad-hoc/realtime troubleshooting with a dedicated query account):
#   1. Load credentials from a config file so you don't re-export env each call.
#   2. Cache the auth token on disk and reuse it until ~5 min before it expires,
#      so repeated queries don't each pay an auth round-trip.
#
# Config resolution (existing env always wins; file only fills the gaps):
#   $BESZEL_ENV_FILE  (default: ~/.config/beszel/env)  — a sourced shell file with
#   BESZEL_URL=..., BESZEL_EMAIL=..., BESZEL_PASSWORD=..., [BESZEL_AUTH_COLLECTION=users]
#
# Token cache: $BESZEL_CACHE_DIR (default ~/.cache/beszel), file per url+collection+email,
#   mode 0600. Set BESZEL_NO_CACHE=1 to disable. An explicit BESZEL_TOKEN bypasses all of this.

# Source the config file into the environment if present and BESZEL_URL isn't already set.
beszel_load_env() {
  local f="${BESZEL_ENV_FILE:-$HOME/.config/beszel/env}"
  if [[ -z "${BESZEL_URL:-}" && -f "$f" ]]; then
    set -a; # shellcheck disable=SC1090
    . "$f"; set +a
  fi
}

# Decode the `exp` (unix seconds) from a JWT, or print nothing on failure.
# Uses the standalone `base64` tool (Linux/Alpine/newer-macOS use -d, older macOS -D).
_beszel_jwt_exp() {
  command -v base64 >/dev/null 2>&1 || return 0
  local p="${1#*.}"; p="${p%%.*}"          # middle (payload) segment
  p="${p//-/+}"; p="${p//_//}"             # base64url -> base64
  case $(( ${#p} % 4 )) in 2) p+='==';; 3) p+='=';; esac
  local dec
  dec="$(printf '%s' "$p" | base64 -d 2>/dev/null)" || dec=""
  [[ -z "$dec" ]] && dec="$(printf '%s' "$p" | base64 -D 2>/dev/null)"
  printf '%s' "$dec" | jq -r '.exp // empty' 2>/dev/null
}

# Echo a valid bearer token (from $BESZEL_TOKEN, the cache, or a fresh login).
beszel_token() {
  if [[ -n "${BESZEL_TOKEN:-}" ]]; then printf '%s' "$BESZEL_TOKEN"; return 0; fi
  : "${BESZEL_URL:?set BESZEL_URL (env or config file)}"
  : "${BESZEL_EMAIL:?set BESZEL_EMAIL (env or config file)}"
  : "${BESZEL_PASSWORD:?set BESZEL_PASSWORD (env or config file)}"
  local base="${BESZEL_URL%/}" col="${BESZEL_AUTH_COLLECTION:-users}"
  local cdir="${BESZEL_CACHE_DIR:-$HOME/.cache/beszel}"
  local key cf tok exp now
  key="$(printf '%s' "$base|$col|$BESZEL_EMAIL" | cksum | cut -d' ' -f1)"
  cf="$cdir/token-$key"

  # reuse a cached token that still has >5 min of life
  if [[ "${BESZEL_NO_CACHE:-0}" != 1 && -r "$cf" ]]; then
    tok="$(cat "$cf")"
    exp="$(_beszel_jwt_exp "$tok")"
    now="$(date +%s)"
    if [[ -n "$exp" ]] && (( exp - now > 300 )); then printf '%s' "$tok"; return 0; fi
  fi

  # fresh login
  local resp
  resp="$(curl -fsS --connect-timeout 10 --max-time 60 -X POST \
            "$base/api/collections/$col/auth-with-password" \
            -H 'Content-Type: application/json' \
            -d "$(jq -n --arg i "$BESZEL_EMAIL" --arg p "$BESZEL_PASSWORD" '{identity:$i,password:$p}')")" \
    || { echo "beszel-auth: login failed (url=$base collection=$col) — check credentials and BESZEL_AUTH_COLLECTION (users vs _superusers)" >&2; return 1; }
  tok="$(jq -r '.token // empty' <<<"$resp")"
  [[ -n "$tok" ]] || { echo "beszel-auth: authentication failed (collection=$col) — check creds / BESZEL_AUTH_COLLECTION" >&2; return 1; }
  if [[ "${BESZEL_NO_CACHE:-0}" != 1 ]]; then
    mkdir -p "$cdir" 2>/dev/null && ( umask 077; printf '%s' "$tok" > "$cf" ) 2>/dev/null || true
  fi
  printf '%s' "$tok"
}
