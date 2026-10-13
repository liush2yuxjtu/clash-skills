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
g=$(api "http://$API/proxies/GLOBAL")
orig_now=$(echo "$g" | jstr now)
orig_mode=$(api "http://$API/configs" | jstr mode)
restore(){ put_name GLOBAL "$orig_now"
  api -X PATCH "http://$API/configs" -d "{\"mode\":\"$orig_mode\"}" >/dev/null; echo "restored mode=$orig_mode GLOBAL=$orig_now" >&2; }
trap restore EXIT
mapfile -t nodes < <(echo "$g" | grep -o '"all":\[[^]]*\]' | sed 's/^"all":\[//;s/\]$//' | grep -o '"[^"]*"' | tr -d '"' \
  | grep -vE '^(DIRECT|REJECT|REJECT-DROP|PASS|COMPATIBLE)$' | grep -vE '剩余|到期|官网|流量|套餐')
api -X PATCH "http://$API/configs" -d '{"mode":"global"}' >/dev/null
printf 'node\texit_ip\tcountry\ttrust\tclaude_ip\tclaude_trust\tclaude_loc\n' > "$OUT"
declare -A cache; n=0
score(){ [ -z "$1" ] && return; [ -n "${cache[$1]}" ] && { echo "${cache[$1]}"; return; }
  s=$(curl -s -m 20 "https://ipbook.net/api/risk-lookup?ip=$1" | jnum trustScore); cache[$1]="$s"; echo "$s"; }
for node in "${nodes[@]}"; do
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
