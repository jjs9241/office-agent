#!/usr/bin/env bash
# nworks.sh — macOS/Linux counterpart of nworks.ps1 (same commands and options).
# Needs bash 3.2+, curl 7.55+, openssl, awk. No jq/python/node.
#
# Commands:
#   setup      -ClientId <id> [-ServiceAccount <sa>] [-PrivateKeyPath <pem>] [-BotId <id>] [-DomainId <id>]
#              Client Secret comes from $NWORKS_CLIENT_SECRET or an interactive prompt.
#   login      [-Preset readonly|all]       User OAuth via browser (callback http://localhost:9876/callback)
#   login-finish <callback URL>             Finish login by hand when no `nc` is available
#   whoami | logout
#   api        <METHOD> <PATH> [-Body <json> | -BodyFile <file>]   user OAuth token
#   bot        <METHOD> <PATH> [-Body <json> | -BodyFile <file>]   service-account (bot) token
#   message    (-To <userId> | -Channel <channelId>) -Text <text>
#   upload     -File <path> [-FolderId <id>] [-Overwrite]
#   download   <PATH ending in /download> -OutDir <dir>
#   attachment <PATH /users/me/mail/{mailId}/attachments/{attId}> -OutDir <dir>
#
# Options accept PowerShell style (-BodyFile) or GNU style (--body-file).
# Success: response body on stdout. Failure: "HTTP <status>: <body>" on stderr, exit 1.

set -u
set -o pipefail
umask 077

BASE_URL='https://www.worksapis.com/v1.0'
AUTH_BASE='https://auth.worksmobile.com/oauth2/v2.0'
REDIRECT_PORT=9876
REDIRECT_URI="http://localhost:$REDIRECT_PORT/callback"
CONFIG_DIR="$HOME/.config/nworks"
CRED_PATH="$CONFIG_DIR/credentials.json"
BOT_TOKEN_PATH="$CONFIG_DIR/token.json"
USER_TOKEN_PATH="$CONFIG_DIR/user-token.json"
LOGIN_STATE_PATH="$CONFIG_DIR/login-state"

# 다운로드 302 Location·업로드 URL은 이 호스트로만 따라간다(토큰 유출 방지).
ALLOWED_HOSTS='storage.worksmobile.com apis-storage.worksmobile.com www.worksapis.com worksapis.com'

# LINE WORKS scope는 도메인 단위다. 쓰기 scope 하나가 생성·수정·삭제를 모두 준다.
READ_SCOPES='calendar.read file.read mail.read task.read user.read board.read contact.read'
WRITE_SCOPES='calendar file mail task board contact'

# Git Bash(Windows)의 curl은 네이티브 exe라 "@/tmp/..." 같은 MSYS 경로를 못 연다. C:/... 형태로 바꿔 넘긴다.
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/nworks.XXXXXX") || exit 1
TMP=$(native_path "$TMP")
trap 'rm -rf "$TMP"' EXIT

die() { printf '%s\n' "$*" >&2; exit 1; }

# ---------- JSON / encoding helpers (awk, byte-wise under LC_ALL=C) ----------

JSON_AWK='
function repl(s, a, b,   out, i) { out = ""; while ((i = index(s, a)) > 0) { out = out substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return out s }
function hex(h,   i, v) { v = 0; h = tolower(h); for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return v }
function utf8(cp) {
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
function jstr(s) {
  s = repl(s, "\\", "\\\\"); s = repl(s, "\"", "\\\""); s = repl(s, "\n", "\\n"); s = repl(s, "\r", "\\r"); s = repl(s, "\t", "\\t")
  return "\"" s "\""
}
function unesc(s,   out, i, c, cp, lo) {
  out = ""
  while ((i = index(s, "\\")) > 0) {
    out = out substr(s, 1, i - 1); c = substr(s, i + 1, 1); s = substr(s, i + 2)
    if (c == "n") out = out "\n"
    else if (c == "t") out = out "\t"
    else if (c == "r") out = out "\r"
    else if (c == "b") out = out "\b"
    else if (c == "f") out = out "\f"
    else if (c == "u") {
      cp = hex(substr(s, 1, 4)); s = substr(s, 5)
      if (cp >= 55296 && cp < 56320 && substr(s, 1, 2) == "\\u") { lo = hex(substr(s, 3, 4)); s = substr(s, 7); cp = 65536 + (cp - 55296) * 1024 + (lo - 56320) }
      out = out utf8(cp)
    }
    else out = out c
  }
  return out s
}
function urlenc(s,   out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c ~ /[A-Za-z0-9._~-]/) out = out c; else out = out sprintf("%%%02X", ORD[c]) }
  return out
}
function urldec(s,   out, i, h) {
  out = ""
  while ((i = index(s, "%")) > 0) {
    out = out substr(s, 1, i - 1); h = substr(s, i + 1, 2)
    if (h ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) { out = out sprintf("%c", hex(h)); s = substr(s, i + 3) } else { out = out "%"; s = substr(s, i + 1) }
  }
  return out s
}
function readfile(f,   line, s, n) { s = ""; n = 0; while ((getline line < f) > 0) { s = (n++ ? s "\n" : "") line } close(f); return s }
function skip(   c) { while (P <= N) { c = substr(S, P, 1); if (c != " " && c != "\t" && c != "\n" && c != "\r") break; P++ } }
# 문자열은 이스케이프를 남긴 원문 그대로 돌려준다(재기록 시 그대로 쓰기 위해).
function pstr(   out, i, w, c) {
  out = ""; i = P + 1
  for (;;) {
    w = substr(S, i, 65536)
    if (w == "") { P = N + 1; return out }
    match(w, /^[^"\\]*/)
    out = out substr(w, 1, RLENGTH); i += RLENGTH
    if (RLENGTH == length(w)) continue
    c = substr(S, i, 1)
    if (c == "\"") { P = i + 1; return out }
    out = out substr(S, i, 2); i += 2
  }
}
function emit(path, t, v) { NE++; EP[NE] = path; ET[NE] = t; EV[NE] = v }
function pval(path,   c, raw) {
  skip(); c = substr(S, P, 1)
  if (c == "{") pobj(path)
  else if (c == "[") parr(path)
  else if (c == "\"") emit(path, "s", pstr())
  else { match(substr(S, P, 64), /^[^],} \t\r\n]*/); raw = substr(S, P, RLENGTH); P += RLENGTH; emit(path, "r", raw) }
}
function pobj(path,   k, c) {
  P++; skip()
  if (substr(S, P, 1) == "}") { P++; return }
  for (;;) {
    skip(); k = unesc(pstr()); skip(); P++
    if (path == "") pval(k); else pval(path "." k)
    skip(); c = substr(S, P, 1); P++
    if (c != ",") return
  }
}
function parr(path,   i, c) {
  P++; skip()
  if (substr(S, P, 1) == "]") { P++; return }
  for (i = 0; ; i++) {
    pval(path "[" i "]")
    skip(); c = substr(S, P, 1); P++
    if (c != ",") return
  }
}
BEGIN {
  mode = ENVIRON["NW_MODE"]
  for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
  if (mode == "str") { printf "%s", jstr(ENVIRON["NW_VALUE"]); exit 0 }
  if (mode == "urlencode") { printf "%s", urlenc(ENVIRON["NW_VALUE"]); exit 0 }
  if (mode == "urldecode") { printf "%s", urldec(ENVIRON["NW_VALUE"]); exit 0 }

  S = readfile(ENVIRON["NW_FILE"]); N = length(S); P = 1; NE = 0
  if (N > 0) pval("")

  if (mode == "get") {
    want = ENVIRON["NW_PATH"]
    for (i = 1; i <= NE; i++) if (EP[i] == want) {
      if (ET[i] == "s") printf "%s", unesc(EV[i]); else if (EV[i] != "null") printf "%s", EV[i]
      exit 0
    }
    exit 1
  }

  if (mode == "store") {
    # 프로필별 { key: scalar } 저장소. 대상 프로필 항목을 통째로 교체하거나 지운다.
    prof = ENVIRON["NW_PROFILE"]; np = 0
    for (i = 1; i <= NE; i++) {
      d = index(EP[i], "."); if (d == 0) continue
      p = substr(EP[i], 1, d - 1); k = substr(EP[i], d + 1)
      if (p == prof) continue
      if (!(p in SEEN)) { SEEN[p] = 1; PL[++np] = p; KC[p] = 0 }
      KC[p]++; KK[p, KC[p]] = k
      if (ET[i] == "s") KV[p, KC[p]] = "\"" EV[i] "\""; else KV[p, KC[p]] = EV[i]
    }
    if (ENVIRON["NW_DELETE"] != "1") {
      PL[++np] = prof; KC[prof] = 0; f = ENVIRON["NW_SETS"]
      while ((getline line < f) > 0) {
        t = substr(line, 1, 1); rest = substr(line, 3); j = index(rest, "\t")
        k = substr(rest, 1, j - 1); v = substr(rest, j + 1)
        KC[prof]++; KK[prof, KC[prof]] = k
        if (t == "s") KV[prof, KC[prof]] = jstr(v); else KV[prof, KC[prof]] = v
      }
    }
    printf "{"
    for (a = 1; a <= np; a++) {
      p = PL[a]; printf "%s\n  %s: {", (a > 1 ? "," : ""), jstr(p)
      for (b = 1; b <= KC[p]; b++) printf "%s\n    %s: %s", (b > 1 ? "," : ""), jstr(KK[p, b]), KV[p, b]
      printf "\n  }"
    }
    printf "%s}\n", (np ? "\n" : "")
    exit 0
  }
}
'

json_get() { NW_MODE=get NW_FILE="$1" NW_PATH="$2" LC_ALL=C awk "$JSON_AWK"; }
jstr() { NW_MODE=str NW_VALUE="$1" LC_ALL=C awk "$JSON_AWK"; }
urlenc() { NW_MODE=urlencode NW_VALUE="$1" LC_ALL=C awk "$JSON_AWK"; }
urldec() { NW_MODE=urldecode NW_VALUE="$1" LC_ALL=C awk "$JSON_AWK"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now() { date +%s; }
int_or_zero() { case $1 in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

# ---------- local store (nworks-compatible, keyed by profile) ----------

store_get() { [ -f "$1" ] && json_get "$1" "$PROFILE.$2"; }

# $1 = store file, $2 = sets file (lines "s|r<TAB>key<TAB>value"), or NW_DELETE=1 to remove the profile
store_put() {
  mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR" 2>/dev/null
  NW_MODE=store NW_FILE="$1" NW_SETS="${2:-/dev/null}" NW_PROFILE="$PROFILE" NW_DELETE="${NW_DELETE:-0}" \
    LC_ALL=C awk "$JSON_AWK" > "$1.$$.tmp" || die "Failed to write $1"
  chmod 600 "$1.$$.tmp" 2>/dev/null
  mv -f "$1.$$.tmp" "$1"
}

sets_new() { SETS="$TMP/sets"; : > "$SETS"; }
sets_add() { [ -n "$3" ] && printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SETS"; return 0; }

load_creds() {
  if [ -n "${NWORKS_CLIENT_ID:-}" ] && [ -n "${NWORKS_CLIENT_SECRET:-}" ]; then
    C_ID=$NWORKS_CLIENT_ID; C_SECRET=$NWORKS_CLIENT_SECRET
    C_SA=${NWORKS_SERVICE_ACCOUNT:-}; C_KEY=${NWORKS_PRIVATE_KEY_PATH:-}; C_BOT=${NWORKS_BOT_ID:-}
    return
  fi
  C_ID=$(store_get "$CRED_PATH" clientId); C_SECRET=$(store_get "$CRED_PATH" clientSecret)
  [ -n "$C_ID" ] && [ -n "$C_SECRET" ] || die 'Not configured. Run: nworks.sh setup -ClientId <id>  (secret via $NWORKS_CLIENT_SECRET)'
  C_SA=$(store_get "$CRED_PATH" serviceAccount); C_KEY=$(store_get "$CRED_PATH" privateKeyPath); C_BOT=$(store_get "$CRED_PATH" botId)
}

# ---------- HTTP ----------

# 비밀값은 명령줄(ps로 보임)에 싣지 않고 파일로 넘긴다.
secret_file() { SECRET_N=$(( ${SECRET_N:-0} + 1 )); printf '%s' "$1" > "$TMP/secret.$SECRET_N"; SECRET_FILE="$TMP/secret.$SECRET_N"; }

# $1 = endpoint (token|revoke), rest = key=value form fields. Result JSON in $TMP/oauth.json.
oauth_post() {
  endpoint=$1; shift
  form=()
  for kv in "$@"; do secret_file "${kv#*=}"; form+=(--data-urlencode "${kv%%=*}@$SECRET_FILE"); done
  code=$(curl -sS -o "$TMP/oauth.json" -w '%{http_code}' "${form[@]}" "$AUTH_BASE/$endpoint") || die "Network error contacting $AUTH_BASE"
  [ "$endpoint" = revoke ] && return 0
  case $code in
    2??) ;;
    *)
      # 응답 전체 대신 표준 OAuth 오류 필드만 노출한다.
      summary=$(json_get "$TMP/oauth.json" error) && summary="$summary: $(json_get "$TMP/oauth.json" error_description)" \
        || summary=$(head -c 200 "$TMP/oauth.json")
      die "Token request failed (HTTP $code): $summary" ;;
  esac
}

save_user_token() {
  sets_new; sets_add s accessToken "$1"; sets_add s refreshToken "$2"; sets_add r expiresAt "$3"; sets_add s scope "$4"
  store_put "$USER_TOKEN_PATH" "$SETS"
}

# $1 = 1 to force refresh. Sets TOKEN.
get_user_token() {
  ut_access=$(store_get "$USER_TOKEN_PATH" accessToken)
  ut_refresh=$(store_get "$USER_TOKEN_PATH" refreshToken)
  [ -n "$ut_access$ut_refresh" ] || die 'User OAuth token not found. Run: nworks.sh login'
  ut_exp=$(int_or_zero "$(store_get "$USER_TOKEN_PATH" expiresAt)")
  if [ "${1:-0}" != 1 ] && [ "$ut_exp" -gt $(( $(now) + 300 )) ]; then TOKEN=$ut_access; return; fi

  load_creds
  oauth_post token grant_type=refresh_token "refresh_token=$ut_refresh" "client_id=$C_ID" "client_secret=$C_SECRET"
  acc=$(json_get "$TMP/oauth.json" access_token)
  ref=$(json_get "$TMP/oauth.json" refresh_token) || ref=$ut_refresh
  [ -n "$ref" ] || ref=$ut_refresh
  sc=$(json_get "$TMP/oauth.json" scope) || sc=
  [ -n "$sc" ] || sc=$(store_get "$USER_TOKEN_PATH" scope)
  exp=$(int_or_zero "$(json_get "$TMP/oauth.json" expires_in)")
  save_user_token "$acc" "$ref" $(( $(now) + exp )) "$sc"
  TOKEN=$acc
}

make_jwt() {
  [ -n "$C_SA" ] && [ -n "$C_KEY" ] || die 'Service account not configured. Run setup with -ServiceAccount and -PrivateKeyPath.'
  [ -f "$C_KEY" ] || die "Private key not found: $C_KEY"
  t=$(now)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iss":%s,"sub":%s,"iat":%s,"exp":%s}' "$(jstr "$C_ID")" "$(jstr "$C_SA")" "$t" $((t + 3600)) | b64url)
  sig=$(printf '%s' "$header.$payload" | openssl dgst -sha256 -sign "$C_KEY" | b64url) || die 'JWT signing failed (check the private key).'
  [ -n "$sig" ] || die 'JWT signing failed (check the private key).'
  JWT="$header.$payload.$sig"
}

# $1 = 1 to force refresh. Sets TOKEN.
get_bot_token() {
  bt_exp=$(int_or_zero "$(store_get "$BOT_TOKEN_PATH" expiresAt)")
  if [ "${1:-0}" != 1 ] && [ "$bt_exp" -gt $(( $(now) + 300 )) ]; then TOKEN=$(store_get "$BOT_TOKEN_PATH" accessToken); return; fi

  load_creds
  make_jwt
  oauth_post token grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer "assertion=$JWT" \
    "client_id=$C_ID" "client_secret=$C_SECRET" "scope=${NWORKS_SCOPE:-bot bot.read user.read}"
  acc=$(json_get "$TMP/oauth.json" access_token)
  exp=$(int_or_zero "$(json_get "$TMP/oauth.json" expires_in)")
  sets_new; sets_add s accessToken "$acc"; sets_add r expiresAt $(( $(now) + exp ))
  store_put "$BOT_TOKEN_PATH" "$SETS"
  TOKEN=$acc
}

# 헤더 이름은 대소문자 무시(BSD sed에는 I 플래그가 없어 awk로 처리).
header_value() {
  tr -d '\r' < "$TMP/resp.hdr" | awk -v want="$1" '
    { i = index($0, ":"); if (i && tolower(substr($0, 1, i - 1)) == tolower(want)) { v = substr($0, i + 1); sub(/^ +/, "", v); last = v } }
    END { if (last != "") print last }'
}

# 401이면 토큰을 한 번 갱신해 재시도, 429면 Retry-After만큼 쉬고 최대 3회 재시도한다.
# $1 = user|bot, $2 = METHOD, $3 = path or https URL, $4 = JSON body file (optional), rest = extra curl args.
# Sets R_CODE; body in $TMP/resp.body, headers in $TMP/resp.hdr.
call_api() {
  kind=$1; method=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]'); target=$3; body_file=${4:-}
  shift 3; [ $# -gt 0 ] && shift
  case $target in https://*) url=$target ;; *) url="$BASE_URL$target" ;; esac
  refreshed=0; attempt=0
  while :; do
    if [ "$kind" = bot ]; then get_bot_token $refreshed; else get_user_token $refreshed; fi
    printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TMP/auth.h"
    args=(-sS -X "$method" -o "$TMP/resp.body" -D "$TMP/resp.hdr" -w '%{http_code}' -H "@$TMP/auth.h")
    [ -n "$body_file" ] && args+=(-H 'Content-Type: application/json; charset=utf-8' --data-binary "@$body_file")
    R_CODE=$(curl "${args[@]}" ${1+"$@"} "$url") || die "Network error: $method $url"
    if [ "$R_CODE" = 401 ] && [ $refreshed = 0 ]; then refreshed=1; continue; fi
    if [ "$R_CODE" = 429 ] && [ $attempt -lt 3 ]; then
      wait_s=$(int_or_zero "$(header_value retry-after)"); [ "$wait_s" -gt 0 ] || wait_s=5; [ "$wait_s" -le 60 ] || wait_s=60
      attempt=$((attempt + 1)); sleep "$wait_s"; continue
    fi
    return 0
  done
}

assert_ok() {
  case $R_CODE in 2??) return 0 ;; esac
  hint=
  [ "$R_CODE" = 401 ] && hint=' (token expired or revoked: run login again)'
  [ "$R_CODE" = 403 ] && hint=' (missing scope? run login -Preset all, or check app permissions)'
  { printf 'HTTP %s%s: ' "$R_CODE" "$hint"; cat "$TMP/resp.body" 2>/dev/null; echo; } >&2
  exit 1
}

print_result() {
  assert_ok
  if [ -s "$TMP/resp.body" ]; then cat "$TMP/resp.body"; echo; else printf '{"status":%s}\n' "$R_CODE"; fi
}

body_file() {
  BODY_PATH=
  if [ -n "$BODY_FILE" ]; then [ -f "$BODY_FILE" ] || die "Body file not found: $BODY_FILE"; BODY_PATH=$(native_path "$BODY_FILE")
  elif [ -n "$BODY" ]; then printf '%s' "$BODY" > "$TMP/body.json"; BODY_PATH="$TMP/body.json"; fi
}

assert_allowed_host() {
  case $1 in https://*) ;; *) die "Refusing non-HTTPS URL: $1" ;; esac
  h=${1#https://}; h=${h%%/*}; h=${h%%\?*}; h=${h##*@}; h=${h%%:*}
  h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  for allowed in $ALLOWED_HOSTS; do
    [ "$h" = "$allowed" ] && return 0
    case $h in *."$allowed") return 0 ;; esac
  done
  die "Refusing untrusted host: $h"
}

safe_file_name() {
  n=${1##*/}; n=${n##*\\}
  n=$(printf '%s' "$n" | tr '<>:"|?*' '_______' | tr -d '\000-\037')
  case $n in ''|.|..) n=download.bin ;; esac
  printf '%s' "$n"
}

save_download() { # $1 = source file, $2 = file name
  [ -n "$OUT_DIR" ] || die '-OutDir is required.'
  mkdir -p "$OUT_DIR" || die "Cannot create $OUT_DIR"
  dir=$(cd "$OUT_DIR" && pwd -P) || die "Cannot open $OUT_DIR"
  dest="$dir/$(safe_file_name "$2")"
  mv -f "$1" "$dest" || die "Cannot write $dest"
  printf '{"saved":%s,"size":%s}\n' "$(jstr "$dest")" "$(wc -c < "$dest" | tr -d ' ')"
}

# ---------- commands ----------

cmd_setup() {
  id=${CLIENT_ID:-${NWORKS_CLIENT_ID:-}}
  [ -n "$id" ] || die '-ClientId is required.'
  secret=${NWORKS_CLIENT_SECRET:-}
  if [ -z "$secret" ] && [ -t 0 ]; then
    printf 'Client Secret: ' >&2; stty -echo 2>/dev/null; IFS= read -r secret; stty echo 2>/dev/null; echo >&2
  fi
  [ -n "$secret" ] || die 'Client Secret is required ($NWORKS_CLIENT_SECRET or prompt).'
  key=${PRIVATE_KEY_PATH:-${NWORKS_PRIVATE_KEY_PATH:-}}
  if [ -n "$key" ]; then
    [ -f "$key" ] || die "Private key not found: $key"
    key="$(cd "$(dirname "$key")" && pwd -P)/$(basename "$key")"
  fi
  sets_new
  sets_add s clientId "$id"; sets_add s clientSecret "$secret"; sets_add s serviceAccount "$SERVICE_ACCOUNT"
  sets_add s privateKeyPath "$key"; sets_add s botId "$BOT_ID"; sets_add s domainId "$DOMAIN_ID"
  store_put "$CRED_PATH" "$SETS"
  echo "Saved credentials to $CRED_PATH (profile: $PROFILE). Next: nworks.sh login"
}

open_browser() {
  [ "${NWORKS_NO_BROWSER:-}" = 1 ] && return 1
  case $(uname -s) in
    Darwin) open "$1" ;;
    MINGW*|MSYS*|CYGWIN*) rundll32 url.dll,FileProtocolHandler "$1" ;;
    *) command -v xdg-open >/dev/null 2>&1 && xdg-open "$1" >/dev/null 2>&1 ;;
  esac
}

# nc로 콜백 요청 한 건을 받는다. 성공하면 CALLBACK_URL을 채운다. nc 문법은 구현마다 달라 두 가지를 시도한다.
wait_callback_nc() {
  command -v nc >/dev/null 2>&1 || return 1
  html='<!doctype html><meta charset=utf-8><h2>로그인 요청을 받았습니다</h2><p>이 창을 닫고 터미널로 돌아가세요.</p>'
  len=$(printf '%s' "$html" | wc -c | tr -d ' ')
  req="$TMP/callback.req"; nc_pid=
  for variant in "-l 127.0.0.1 $REDIRECT_PORT" "-l -s 127.0.0.1 -p $REDIRECT_PORT"; do
    : > "$req"
    # shellcheck disable=SC2086
    { printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$len" "$html"; } \
      | nc $variant > "$req" 2>/dev/null &
    nc_pid=$!
    sleep 1
    kill -0 "$nc_pid" 2>/dev/null && break
    nc_pid=
  done
  [ -n "$nc_pid" ] || return 1

  deadline=$(( $(now) + 120 ))
  while ! grep -q '^GET ' "$req" 2>/dev/null; do
    if [ "$(now)" -gt "$deadline" ]; then kill "$nc_pid" 2>/dev/null; die 'OAuth login timed out (120s).'; fi
    sleep 1
  done
  sleep 1; kill "$nc_pid" 2>/dev/null
  line=$(head -n 1 "$req" | tr -d '\r'); line=${line#GET }; line=${line%% HTTP/*}
  CALLBACK_URL="http://localhost:$REDIRECT_PORT$line"
}

cmd_login() {
  load_creds
  case $PRESET in readonly) requested=$READ_SCOPES ;; all) requested="$READ_SCOPES $WRITE_SCOPES" ;; *) die '-Preset must be readonly or all.' ;; esac
  # 기존 토큰 scope와 합쳐 재로그인으로 권한이 줄지 않게 한다.
  existing=$(store_get "$USER_TOKEN_PATH" scope) || existing=
  # shellcheck disable=SC2086
  scope=$(printf '%s\n' $existing $requested | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
  state=$(openssl rand -hex 32) || die 'openssl rand failed'
  mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR" 2>/dev/null
  printf '%s\n' "$state" > "$LOGIN_STATE_PATH"
  url="$AUTH_BASE/authorize?client_id=$(urlenc "$C_ID")&redirect_uri=$(urlenc "$REDIRECT_URI")&scope=$(urlenc "$scope")&response_type=code&state=$state"

  CALLBACK_URL=
  if command -v nc >/dev/null 2>&1; then
    open_browser "$url" || true
    printf 'Browser opened for NAVER WORKS login (120s). If not, open:\n%s\n' "$url" >&2
    if wait_callback_nc; then finish_login "$CALLBACK_URL"; return; fi
  fi
  # nc가 없으면 수동 완료: 로그인 후 브라우저 주소창의 콜백 URL을 login-finish에 넘긴다.
  open_browser "$url" || true
  cat >&2 <<EOF
Open this URL and log in:
$url

The browser will then fail to load http://localhost:$REDIRECT_PORT/callback?code=...
Copy that full address and run:  nworks.sh login-finish '<that URL>'
EOF
}

finish_login() {
  load_creds
  [ -f "$LOGIN_STATE_PATH" ] || die 'No pending login. Run: nworks.sh login'
  expected=$(head -n 1 "$LOGIN_STATE_PATH")
  query=${1#*\?}; query=${query%%#*}
  code=; got_state=; oauth_error=
  old_ifs=$IFS; IFS='&'; set -f
  for pair in $query; do
    k=${pair%%=*}; v=$(urldec "${pair#*=}")
    case $k in code) code=$v ;; state) got_state=$v ;; error) oauth_error=$v ;; esac
  done
  IFS=$old_ifs; set +f
  [ "$got_state" = "$expected" ] || die 'OAuth state mismatch. Run login again.'
  [ -z "$oauth_error" ] || die "OAuth error: $oauth_error"
  [ -n "$code" ] || die 'Missing authorization code in callback URL.'
  rm -f "$LOGIN_STATE_PATH"

  oauth_post token grant_type=authorization_code "code=$code" "client_id=$C_ID" "client_secret=$C_SECRET" "redirect_uri=$REDIRECT_URI"
  acc=$(json_get "$TMP/oauth.json" access_token)
  ref=$(json_get "$TMP/oauth.json" refresh_token)
  sc=$(json_get "$TMP/oauth.json" scope) || sc=
  exp=$(int_or_zero "$(json_get "$TMP/oauth.json" expires_in)")
  save_user_token "$acc" "$ref" $(( $(now) + exp )) "$sc"
  echo "Login OK. scope: $sc"
}

mask() { [ -z "$1" ] && { echo null; return; }; [ ${#1} -le 4 ] && { jstr '****'; return; }; jstr "****${1: -4}"; }
json_or_null() { if [ -n "$1" ]; then jstr "$1"; else echo null; fi; }

cmd_whoami() {
  load_creds
  t=$(now)
  bot_exp=$(int_or_zero "$(store_get "$BOT_TOKEN_PATH" expiresAt)")
  bot_valid=false; [ "$bot_exp" -gt "$t" ] && bot_valid=true
  user_oauth=null; me=null
  if [ -n "$(store_get "$USER_TOKEN_PATH" refreshToken)" ]; then
    u_exp=$(int_or_zero "$(store_get "$USER_TOKEN_PATH" expiresAt)")
    u_valid=false; [ "$u_exp" -gt "$t" ] && u_valid=true
    user_oauth="{\"valid\":$u_valid,\"scope\":$(json_or_null "$(store_get "$USER_TOKEN_PATH" scope)")}"
    call_api user GET /users/me
    if [ "$R_CODE" = 200 ]; then
      name="$(json_get "$TMP/resp.body" userName.lastName)$(json_get "$TMP/resp.body" userName.firstName)"
      me="{\"userId\":$(json_or_null "$(json_get "$TMP/resp.body" userId)"),\"email\":$(json_or_null "$(json_get "$TMP/resp.body" email)"),\"name\":$(json_or_null "$name")}"
    else
      me=$(jstr "HTTP $R_CODE")
    fi
  fi
  cat <<EOF
{
  "profile": $(jstr "$PROFILE"),
  "clientId": $(mask "$C_ID"),
  "serviceAccount": $(json_or_null "$C_SA"),
  "botId": $(json_or_null "$C_BOT"),
  "botTokenValid": $bot_valid,
  "userOAuth": $user_oauth,
  "me": $me
}
EOF
}

cmd_logout() {
  c_id=$(store_get "$CRED_PATH" clientId); c_secret=$(store_get "$CRED_PATH" clientSecret)
  if [ -n "$c_id" ] && [ -n "$c_secret" ]; then
    for tok in "$(store_get "$USER_TOKEN_PATH" refreshToken)" "$(store_get "$BOT_TOKEN_PATH" accessToken)"; do
      # best-effort: 폐기 실패해도 로컬 삭제는 진행
      [ -n "$tok" ] && { ( oauth_post revoke "token=$tok" "client_id=$c_id" "client_secret=$c_secret" ) 2>/dev/null || true; }
    done
  fi
  for f in "$CRED_PATH" "$BOT_TOKEN_PATH" "$USER_TOKEN_PATH"; do
    [ -f "$f" ] && NW_DELETE=1 store_put "$f"
  done
  rm -f "$LOGIN_STATE_PATH"
  echo "Logged out (profile: $PROFILE)."
}

cmd_message() {
  load_creds
  [ -n "$C_BOT" ] || die 'botId not configured (setup -BotId).'
  [ -n "$TEXT" ] || die '-Text is required.'
  if [ -n "$TO" ]; then target="/bots/$(urlenc "$C_BOT")/users/$(urlenc "$TO")/messages"
  elif [ -n "$CHANNEL" ]; then target="/bots/$(urlenc "$C_BOT")/channels/$(urlenc "$CHANNEL")/messages"
  else die '-To or -Channel is required.'; fi
  printf '{"content":{"type":"text","text":%s}}' "$(jstr "$TEXT")" > "$TMP/body.json"
  call_api bot POST "$target" "$TMP/body.json"
  print_result
}

cmd_upload() {
  [ -n "$FILE" ] || die '-File is required.'
  [ -f "$FILE" ] || die "File not found: $FILE"
  full="$(cd "$(dirname "$FILE")" && pwd -P)/$(basename "$FILE")" || die "Cannot resolve $FILE"
  # 인증 정보·SSH 키 등 민감 위치는 업로드 대상에서 차단한다.
  for blocked in "$CONFIG_DIR" "$HOME/.ssh" "$HOME/.aws" "$HOME/.claude"; do
    real=$(cd "$blocked" 2>/dev/null && pwd -P) || real=$blocked
    case $full in "$real"/*) die "Refusing to upload from sensitive location: $blocked" ;; esac
  done
  size=$(wc -c < "$full" | tr -d ' ')
  [ "$size" -le 104857600 ] || die 'File exceeds 100MB.'
  name=$(basename "$full")
  case $name in *'"'*) die 'File names containing " are not supported.' ;; esac

  create_path=/users/me/drive/files
  [ -n "$FOLDER_ID" ] && create_path="$create_path/$(urlenc "$FOLDER_ID")"
  overwrite=false; [ "$OVERWRITE" = 1 ] && overwrite=true
  printf '{"fileName":%s,"fileSize":%s,"overwrite":%s}' "$(jstr "$name")" "$size" "$overwrite" > "$TMP/meta.json"
  call_api user POST "$create_path" "$TMP/meta.json"
  assert_ok
  upload_url=$(json_get "$TMP/resp.body" uploadUrl) || die 'No uploadUrl in response.'
  assert_allowed_host "$upload_url"
  safe=$(printf '%s' "$name" | tr '\r\n;' '___')
  call_api user POST "$upload_url" '' -F "Filedata=@\"$(native_path "$full")\";filename=\"$safe\";type=application/octet-stream"
  print_result
}

cmd_download() {
  [ -n "$ARG_PATH" ] || die 'Usage: download <PATH ending in /download> -OutDir <dir>'
  # download 엔드포인트는 302로 스토리지 URL을 준다. 호스트 검증 후에만 토큰을 실어 따라간다.
  call_api user GET "$ARG_PATH"
  location=$(header_value location)
  if [ -z "$location" ]; then assert_ok; die "No download URL returned (HTTP $R_CODE)."; fi
  assert_allowed_host "$location"
  call_api user GET "$location"
  assert_ok
  disposition=$(header_value content-disposition)
  name=download.bin
  case $disposition in
    *"filename*="*) name=$(urldec "$(printf '%s' "$disposition" | sed -n "s/.*filename\*=[^']*'[^']*'\([^;]*\).*/\1/p")") ;;
    *filename=*) name=$(urldec "$(printf '%s' "$disposition" | sed -n 's/.*filename="\{0,1\}\([^";]*\).*/\1/p')") ;;
  esac
  save_download "$TMP/resp.body" "$name"
}

cmd_attachment() {
  [ -n "$ARG_PATH" ] || die 'Usage: attachment /users/me/mail/{mailId}/attachments/{attachmentId} -OutDir <dir>'
  # 메일 첨부 API는 바이너리가 아니라 base64 문자열을 JSON으로 돌려준다. 큰 data는 sed로 스트림 처리한다.
  call_api user GET "$ARG_PATH"
  assert_ok
  sed 's/"data"[[:space:]]*:[[:space:]]*"[^"]*"/"data":""/' "$TMP/resp.body" > "$TMP/meta.json"
  name=$(json_get "$TMP/meta.json" filename) || name=attachment.bin
  sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/resp.body" | sed 's#\\/#/#g' \
    | openssl base64 -d -A > "$TMP/attachment.bin" || die 'Failed to decode attachment.'
  save_download "$TMP/attachment.bin" "$name"
}

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

# ---------- argument parsing ----------

[ $# -gt 0 ] || usage
COMMAND=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); shift
BODY=; BODY_FILE=; PRESET=readonly; CLIENT_ID=; SERVICE_ACCOUNT=; PRIVATE_KEY_PATH=; BOT_ID=; DOMAIN_ID=
FILE=; FOLDER_ID=; OVERWRITE=0; OUT_DIR=; TO=; CHANNEL=; TEXT=; PROFILE=default
POSITIONAL=()
while [ $# -gt 0 ]; do
  case $1 in
    -*)
      opt=$(printf '%s' "$1" | tr -d '-' | tr '[:upper:]' '[:lower:]')
      if [ "$opt" = overwrite ]; then OVERWRITE=1; shift; continue; fi
      raw_opt=$1
      [ $# -ge 2 ] || die "Missing value for $1"
      value=$2; shift 2
      case $opt in
        body) BODY=$value ;;
        bodyfile) BODY_FILE=$value ;;
        preset) PRESET=$value ;;
        clientid) CLIENT_ID=$value ;;
        serviceaccount) SERVICE_ACCOUNT=$value ;;
        privatekeypath) PRIVATE_KEY_PATH=$value ;;
        botid) BOT_ID=$value ;;
        domainid) DOMAIN_ID=$value ;;
        file) FILE=$value ;;
        folderid) FOLDER_ID=$value ;;
        outdir) OUT_DIR=$value ;;
        to) TO=$value ;;
        channel) CHANNEL=$value ;;
        text) TEXT=$value ;;
        profilename|profile) PROFILE=$value ;;
        *) die "Unknown option: $raw_opt" ;;
      esac ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
case $PROFILE in ''|.|..|*[!A-Za-z0-9_.-]*) die "Invalid profile name: $PROFILE" ;; esac
ARG1=${POSITIONAL[0]:-}; ARG2=${POSITIONAL[1]:-}

for tool in curl openssl awk; do command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"; done

case $COMMAND in
  setup) cmd_setup ;;
  login) cmd_login ;;
  login-finish) [ -n "$ARG1" ] || die 'Usage: login-finish <callback URL>'; finish_login "$ARG1" ;;
  whoami) cmd_whoami ;;
  logout) cmd_logout ;;
  api|bot)
    [ -n "$ARG1" ] && [ -n "$ARG2" ] || die "Usage: $COMMAND <METHOD> <PATH> [-Body <json> | -BodyFile <file>]"
    body_file
    call_api "$COMMAND" "$ARG1" "$ARG2" "$BODY_PATH"
    print_result ;;
  message) cmd_message ;;
  upload) cmd_upload ;;
  download) ARG_PATH=$ARG1; cmd_download ;;
  attachment) ARG_PATH=$ARG1; cmd_attachment ;;
  *) die "Unknown command: $COMMAND (setup|login|login-finish|whoami|logout|api|bot|message|upload|download|attachment)" ;;
esac
