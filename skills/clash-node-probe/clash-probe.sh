#!/usr/bin/env bash
# Probe every Clash/mihomo node: exit IP, Claude exit IP, ipbook trust score.
# Pure bash + curl. Usage: API=127.0.0.1:9097 SECRET=xxx PORT=7897 LIMIT=0 ./clash-probe.sh
API="${API:-127.0.0.1:9097}"; SECRET="${SECRET:?set SECRET to your Clash external-controller secret}"; PORT="${PORT:-7897}"
LIMIT="${LIMIT:-0}"; OUT="${OUT:-clash_probe_$(date +%Y%m%d_%H%M).tsv}"
H="Authorization: Bearer $SECRET"
api(){ curl -s -m 10 -H "$H" -H 'Content-Type: application/json' "$@"; }
# Non-ASCII in argv gets mangled by Windows curl.exe, so send JSON bodies via stdin.
put_name(){ printf '{"name":"%s"}' "$2" | api -X PUT "http://$API/proxies/$1" --data-binary @- >/dev/null; }
enc(){ curl -Gso /dev/null -w '%{url_effective}' --data-urlencode "=$1" "http://x/" | sed 's@^http://x/?@@'; }
jstr(){ grep -o "\"$1\":\"[^\"]*\"" | head -1 | sed "s/\"$1\":\"//;s/\"\$//"; }
jnum(){ grep -o "\"$1\":[0-9.]*" | head -1 | sed "s/\"$1\"://"; }
die(){ echo "clash-probe: $*" >&2; exit 1; }
# --- pre-flight: nothing is PUT/PATCHed until all of these pass ---
command -v curl >/dev/null 2>&1 || die "curl not found in PATH"
case "$LIMIT" in ''|*[!0-9]*) die "LIMIT must be a non-negative integer (got '$LIMIT')";; esac
# api_get URL -> body on stdout; fails unless HTTP 200
api_get(){ r=$(api -w '\n%{http_code}' "$1") || return 1; code=${r##*$'\n'}; [ "$code" = 200 ] || return 1; printf '%s' "${r%$'\n'*}"; }
g=$(api_get "http://$API/proxies/GLOBAL") || die "cannot fetch http://$API/proxies/GLOBAL (API unreachable or SECRET invalid)"
orig_now=$(echo "$g" | jstr now)
cfg=$(api_get "http://$API/configs") || die "cannot fetch http://$API/configs (API unreachable or SECRET invalid)"
orig_mode=$(echo "$cfg" | jstr mode)
[ -n "$orig_now" ] || die "GLOBAL has no current selection; refusing to continue"
[ -n "$orig_mode" ] || die "could not read current mode from /configs; refusing to continue"
restore(){ [ -n "$orig_now" ] && put_name GLOBAL "$orig_now"
  [ -n "$orig_mode" ] && api -X PATCH "http://$API/configs" -d "{\"mode\":\"$orig_mode\"}" >/dev/null; echo "restored mode=$orig_mode GLOBAL=$orig_now" >&2; }
trap restore EXIT
nodes=()
while IFS= read -r line; do [ -n "$line" ] && nodes[${#nodes[@]}]="$line"; done <<EOF_NODES
$(echo "$g" | grep -o '"all":\[[^]]*\]' | sed 's/^"all":\[//;s/\]$//' | grep -o '"[^"]*"' | tr -d '"' \
  | grep -vE '^(DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE)$' | grep -vE '剩余|到期|官网|流量|套餐')
EOF_NODES
api -X PATCH "http://$API/configs" -d '{"mode":"global"}' >/dev/null
printf 'node\texit_ip\tcountry\ttrust\tclaude_ip\tclaude_trust\tclaude_loc\n' > "$OUT"
# bash 3.2 has no associative arrays: cache is a newline list of "ip<TAB>score".
cache=""; n=0
score(){ [ -z "$1" ] && return; c=$(printf '%s\n' "$cache" | grep -F "$1	" | head -1)
  [ -n "$c" ] && { echo "${c#*	}"; return; }
  s=$(curl -s -m 20 "https://ipbook.net/api/risk-lookup?ip=$1" | jnum trustScore); cache="$cache
$1	$s"; echo "$s"; }
for node in ${nodes[@]+"${nodes[@]}"}; do
  n=$((n+1)); [ "$LIMIT" -gt 0 ] && [ "$n" -gt "$LIMIT" ] && break
  put_name GLOBAL "$node"; sleep 1
  w=$(curl -4 -s -m 15 -x "http://127.0.0.1:$PORT" https://ipbook.net/api/whoami)
  ip=$(echo "$w" | jstr ip)
  t=$(curl -s -m 15 -x "http://127.0.0.1:$PORT" https://claude.ai/cdn-cgi/trace)
  cip=$(echo "$t" | sed -n 's/^ip=//p'); cloc=$(echo "$t" | sed -n 's/^loc=//p')
  s1=$(score "$ip"); s2=$(score "$cip")
  cc=$(curl -s -m 15 "https://ipbook.net/api/risk-lookup?ip=$ip" | jstr country)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$node" "${ip:--}" "${cc:--}" "${s1:--}" "${cip:--}" "${s2:--}" "${cloc:--}" | tee -a "$OUT"
done
echo "saved: $OUT" >&2
