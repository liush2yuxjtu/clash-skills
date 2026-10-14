#!/usr/bin/env bash
# Live-verify: download mihomo, start it from CLASH_SUB_URL or a local config,
# measure the VM's direct ipbook trust score vs every node's proxied score,
# print a name/score table, try DNS optimizations toward 100, then always stop
# mihomo. Never prints subscription URLs, tokens, node server addresses,
# passwords, or real exit IPs.
#
# Usage:
#   CLASH_SUB_URL='...' bash skills/verify-skill/live-verify.sh
#   CLASH_CONFIG=/path/to/profile.yaml bash skills/verify-skill/live-verify.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROBE="$ROOT/skills/clash-node-probe/clash-probe.sh"
HERE="$ROOT/skills/verify-skill"
CACHE="${LIVE_VERIFY_CACHE:-$HOME/.cache/clash-skills-live-verify}"
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t live-verify)
MIHOMO_PID=""
SECRET="${SECRET:-}"
PORT="${PORT:-7890}"
API_HOSTPORT="${API:-127.0.0.1:9090}"
TARGET="${TARGET_SCORE:-100}"
PRINT_IPS="${PRINT_IPS:-0}"
SKIP_OPT="${LIVE_VERIFY_SKIP_OPT:-0}"

die(){ echo "live-verify: $*" >&2; exit 1; }
log(){ echo "live-verify: $*" >&2; }

cleanup(){
  if [ -n "$MIHOMO_PID" ]; then
    kill "$MIHOMO_PID" 2>/dev/null || true
    wait "$MIHOMO_PID" 2>/dev/null || true
    MIHOMO_PID=""
    log "stopped mihomo"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

redact_tsv(){
  # Keep node / country / trust / claude_trust / claude_loc. Drop IP columns.
  awk -F '\t' 'BEGIN{OFS="\t"}
    NR==1 { print "node","country","trust","claude_trust","claude_loc"; next }
    { print $1,$3,$4,$6,$7 }' "$1"
}

num_or_blank(){
  case "${1:-}" in
    ''|'-') echo 0 ;;
    *[0-9]*) echo "$1" ;;
    *) echo 0 ;;
  esac
}

download_mihomo(){
  mkdir -p "$CACHE"
  if [ -x "$CACHE/mihomo" ]; then
    log "using cached mihomo ($("$CACHE/mihomo" -v 2>/dev/null | head -1 || echo cached))"
    return 0
  fi
  command -v python3 >/dev/null || die "python3 required to pick the latest mihomo asset"
  arch=$(uname -m)
  [ "$arch" = x86_64 ] || [ "$arch" = amd64 ] || die "this helper downloads linux-amd64 only (got $arch)"
  log "downloading latest MetaCubeX/mihomo linux-amd64"
  python3 - "$CACHE" <<'PY'
import json, os, ssl, sys, urllib.request, gzip, shutil
cache = sys.argv[1]
ctx = ssl.create_default_context()
req = urllib.request.Request(
    "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest",
    headers={"User-Agent": "clash-skills-live-verify", "Accept": "application/vnd.github+json"},
)
with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
    rel = json.loads(r.read().decode())
want = None
for a in rel.get("assets") or []:
    n = a.get("name") or ""
    if n.startswith("mihomo-linux-amd64-v") and n.endswith(".gz") \
            and "compatible" not in n and "go12" not in n \
            and "-v1-" not in n and "-v2-" not in n and "-v3-" not in n:
        want = a
        break
if not want:
    sys.exit("no mihomo-linux-amd64-*.gz asset on latest release")
print("tag", rel.get("tag_name"), "asset", want["name"], file=sys.stderr)
req = urllib.request.Request(want["browser_download_url"], headers={"User-Agent": "clash-skills-live-verify"})
gz = os.path.join(cache, want["name"])
with urllib.request.urlopen(req, context=ctx, timeout=120) as r, open(gz, "wb") as f:
    shutil.copyfileobj(r, f)
binpath = os.path.join(cache, "mihomo")
with gzip.open(gz, "rb") as src, open(binpath, "wb") as dst:
    shutil.copyfileobj(src, dst)
os.chmod(binpath, 0o755)
os.remove(gz)
PY
}

resolve_config(){
  src="$WORK/incoming.yaml"
  fetched=0
  if [ -n "${CLASH_SUB_URL:-}" ]; then
    log "fetching subscription (URL not printed)"
    if curl -fsSL -A "clash.meta" -m 30 -o "$src" "$CLASH_SUB_URL"; then
      if grep -qE '^(proxies:|mixed-port:|port:)' "$src" 2>/dev/null; then
        fetched=1
        log "subscription fetch ok"
      else
        log "subscription response was not a Clash YAML; will try CLASH_CONFIG"
        rm -f "$src"
      fi
    else
      log "subscription fetch failed; will try CLASH_CONFIG"
    fi
  fi
  if [ "$fetched" != 1 ]; then
    [ -n "${CLASH_CONFIG:-}" ] || die "set CLASH_SUB_URL (working) or CLASH_CONFIG to a local YAML (never commit it)"
    [ -f "$CLASH_CONFIG" ] || die "CLASH_CONFIG is not a file"
    cp "$CLASH_CONFIG" "$src"
    log "using local config file"
  fi
  [ -s "$src" ] || die "config is empty"
}

patch_runtime(){
  [ -n "$SECRET" ] || SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  python3 - "$WORK/incoming.yaml" "$WORK/runtime.yaml" "$SECRET" "$PORT" "$API_HOSTPORT" <<'PY'
import re, sys
src, dst, secret, port, api = sys.argv[1:6]
text = open(src, encoding="utf-8").read()
def repl(text, key, value):
    pat = re.compile(r"^(" + re.escape(key) + r":\s*).+$", re.M)
    if pat.search(text):
        return pat.sub(r"\g<1>" + value, text, count=1)
    return "%s: %s\n%s" % (key, value, text)
text = repl(text, "mixed-port", str(port))
text = repl(text, "external-controller", "'%s'" % api)
if re.search(r"^secret:", text, re.M):
    text = repl(text, "secret", "'%s'" % secret)
else:
    text = re.sub(r"^(external-controller:.*)$",
                  r"\1\nsecret: '%s'" % secret, text, count=1, flags=re.M)
open(dst, "w", encoding="utf-8").write(text)
PY
}

apply_dns_profile(){
  # $1 = stock | redir-host | doh-fake-ip
  python3 - "$WORK/runtime.yaml" "$1" <<'PY'
import re, sys
path, kind = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
if kind == "stock":
    pass
elif kind == "redir-host":
    text = re.sub(r"(enhanced-mode:\s*)\S+", r"\1redir-host", text, count=1)
elif kind == "doh-fake-ip":
    text = re.sub(r"(enhanced-mode:\s*)\S+", r"\1fake-ip", text, count=1)
    # Prefer remote DoH for nameserver / fallback; keep default-nameserver IP-only.
    text = re.sub(
        r"(nameserver:\s*)\[.*?\]",
        r"\1[https://cloudflare-dns.com/dns-query, https://dns.google/dns-query]",
        text, count=1)
    text = re.sub(
        r"(fallback:\s*)\[.*?\]",
        r"\1[https://1.1.1.1/dns-query, https://8.8.8.8/dns-query]",
        text, count=1)
    text = re.sub(
        r"(default-nameserver:\s*)\[.*?\]",
        r"\1[1.1.1.1, 8.8.8.8]",
        text, count=1)
    text = re.sub(
        r"(proxy-server-nameserver:\s*)\[.*?\]",
        r"\1[1.1.1.1, 8.8.8.8]",
        text, count=1)
else:
    sys.exit("unknown dns profile %s" % kind)
open(path, "w", encoding="utf-8").write(text)
print("dns_profile", kind, file=sys.stderr)
PY
}

start_mihomo(){
  mkdir -p "$WORK/mihomo-home"
  if [ -n "$MIHOMO_PID" ]; then
    kill "$MIHOMO_PID" 2>/dev/null || true
    wait "$MIHOMO_PID" 2>/dev/null || true
    MIHOMO_PID=""
    sleep 0.3
  fi
  "$CACHE/mihomo" -d "$WORK/mihomo-home" -f "$WORK/runtime.yaml" >"$WORK/mihomo.log" 2>&1 &
  MIHOMO_PID=$!
  i=0
  while [ "$i" -lt 40 ]; do
    if curl -sf -m 2 -H "Authorization: Bearer $SECRET" "http://$API_HOSTPORT/configs" >/dev/null 2>&1; then
      log "mihomo ready pid=$MIHOMO_PID"
      return 0
    fi
    if ! kill -0 "$MIHOMO_PID" 2>/dev/null; then
      log "mihomo exited; last log lines (redacted):"
      python3 - "$WORK/mihomo.log" <<'PY' >&2
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()[-2000:]
text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", text)
text = re.sub(r"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}", "<uuid>", text)
print(text)
PY
      die "mihomo failed to start"
    fi
    i=$((i+1)); sleep 0.25
  done
  die "mihomo did not open $API_HOSTPORT"
}

measure_direct(){
  log "direct baseline (no proxy)"
  who=$(curl -4 -s -m 20 https://ipbook.net/api/whoami || true)
  ip=$(printf '%s' "$who" | grep -o '"ip":"[^"]*"' | head -1 | sed 's/"ip":"//;s/"$//')
  trace=$(curl -s -m 15 https://claude.ai/cdn-cgi/trace || true)
  cip=$(printf '%s' "$trace" | sed -n 's/^ip=//p')
  colo=$(printf '%s' "$trace" | sed -n 's/^colo=//p')
  loc=$(printf '%s' "$trace" | sed -n 's/^loc=//p')
  s1=""; s2=""
  if [ -n "$ip" ]; then
    s1=$(curl -s -m 20 "https://ipbook.net/api/risk-lookup?ip=$ip" | grep -o '"trustScore":[0-9.]*' | head -1 | sed 's/"trustScore"://')
  fi
  if [ -n "$cip" ]; then
    s2=$(curl -s -m 20 "https://ipbook.net/api/risk-lookup?ip=$cip" | grep -o '"trustScore":[0-9.]*' | head -1 | sed 's/"trustScore"://')
  fi
  echo "${s1:--}" > "$WORK/direct_trust.txt"
  echo "${s2:--}" > "$WORK/direct_claude_trust.txt"
  echo "${colo:--}" > "$WORK/direct_colo.txt"
  echo "${loc:--}" > "$WORK/direct_loc.txt"
  echo "DIRECT_BASELINE  whoami_trust=${s1:--}  claude_trust=${s2:--}  colo=${colo:--}  loc=${loc:--}  same_ip=$([ "$ip" = "$cip" ] && echo yes || echo no)"
}

measure_one(){
  # $1 = node name. Prints trust claude_trust claude_loc
  node=$1
  printf '{"name":"%s"}' "$node" | curl -s -m 10 -H "Authorization: Bearer $SECRET" \
    -H "Content-Type: application/json" -X PUT "http://$API_HOSTPORT/proxies/GLOBAL" --data-binary @- >/dev/null
  curl -s -m 10 -H "Authorization: Bearer $SECRET" -H "Content-Type: application/json" \
    -X PATCH "http://$API_HOSTPORT/configs" -d '{"mode":"global"}' >/dev/null
  sleep 0.4
  who=$(curl -4 -s -m "${PROBE_TIMEOUT:-12}" -x "http://127.0.0.1:$PORT" https://ipbook.net/api/whoami || true)
  ip=$(printf '%s' "$who" | grep -o '"ip":"[^"]*"' | head -1 | sed 's/"ip":"//;s/"$//')
  trace=$(curl -s -m "${PROBE_TIMEOUT:-12}" -x "http://127.0.0.1:$PORT" https://claude.ai/cdn-cgi/trace || true)
  cip=$(printf '%s' "$trace" | sed -n 's/^ip=//p')
  loc=$(printf '%s' "$trace" | sed -n 's/^loc=//p')
  s1="-"; s2="-"
  if [ -n "$ip" ]; then
    s1=$(curl -s -m 15 "https://ipbook.net/api/risk-lookup?ip=$ip" | grep -o '"trustScore":[0-9.]*' | head -1 | sed 's/"trustScore"://')
    s1=${s1:--}
  fi
  if [ -n "$cip" ]; then
    s2=$(curl -s -m 15 "https://ipbook.net/api/risk-lookup?ip=$cip" | grep -o '"trustScore":[0-9.]*' | head -1 | sed 's/"trustScore"://')
    s2=${s2:--}
  fi
  printf '%s\t%s\t%s\n' "${s1:--}" "${s2:--}" "${loc:--}"
}

best_node_from_tsv(){
  python3 - "$1" <<'PY'
import sys
best = None  # (claude, trust, node)
header = None
for i, line in enumerate(open(sys.argv[1], encoding="utf-8")):
    cols = line.rstrip("\n").split("\t")
    if i == 0:
        header = cols
        continue
    if len(cols) < 7:
        continue
    node, trust, ctrust = cols[0], cols[3], cols[5]
    if trust in ("", "-") and ctrust in ("", "-"):
        continue
    def n(x):
        try:
            return float(x)
        except Exception:
            return -1
    key = (n(ctrust), n(trust), node)
    if best is None or key[:2] > best[:2]:
        best = key
if best is None:
    sys.exit(0)
print(best[2])
PY
}

# --- main ---
command -v curl >/dev/null || die "curl required"
command -v python3 >/dev/null || die "python3 required"
[ -f "$PROBE" ] || die "missing $PROBE"

download_mihomo
resolve_config
patch_runtime
start_mihomo
measure_direct

OUT="$WORK/probe.tsv"
log "probing every GLOBAL node via clash-probe.sh (IPs not printed)"
set +e
API="$API_HOSTPORT" SECRET="$SECRET" PORT="$PORT" \
  PROBE_TIMEOUT="${PROBE_TIMEOUT:-12}" SWITCH_WAIT="${SWITCH_WAIT:-0.3}" \
  SKIP_UNREACHABLE="${SKIP_UNREACHABLE:-1}" OUT="$OUT" \
  bash "$PROBE" >"$WORK/probe.stdout" 2>"$WORK/probe.stderr"
prc=$?
set -e
if [ ! -s "$OUT" ]; then
  log "clash-probe failed rc=$prc"
  sed 's/\b\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\b/<ip>/g' "$WORK/probe.stderr" >&2 || true
  die "clash-probe produced no TSV"
fi

echo
echo "=== per-node scores (names only; exit IPs omitted) ==="
if [ "$PRINT_IPS" = 1 ]; then
  cat "$OUT"
else
  redact_tsv "$OUT"
fi
echo
reachable=$(awk -F '\t' 'NR>1 && $2!="-"{c++} END{print c+0}' "$OUT")
total=$(awk -F '\t' 'NR>1{c++} END{print c+0}' "$OUT")
log "reachable $reachable / $total (unreachable rows are '-' from delay skip or probe timeout)"

best=$(best_node_from_tsv "$OUT" || true)
best_trust=0
best_claude=0
best_profile="stock (subscription/local DNS as-is)"
if [ -n "$best" ]; then
  row=$(awk -F '\t' -v n="$best" '$1==n{print; exit}' "$OUT")
  best_trust=$(num_or_blank "$(printf '%s' "$row" | awk -F '\t' '{print $4}')")
  best_claude=$(num_or_blank "$(printf '%s' "$row" | awk -F '\t' '{print $6}')")
  echo "BEST_STOCK  node=$best  trust=$best_trust  claude_trust=$best_claude"
else
  echo "BEST_STOCK  (no reachable node produced a score)"
fi

if [ "$SKIP_OPT" != 1 ] && [ -n "$best" ]; then
  for kind in redir-host doh-fake-ip; do
    log "optimization: DNS profile $kind on $best"
    apply_dns_profile "$kind"
    start_mihomo
    read -r t c loc <<EOF
$(measure_one "$best")
EOF
    echo "OPT  profile=$kind  node=$best  trust=${t:--}  claude_trust=${c:--}  claude_loc=${loc:--}"
    tn=$(num_or_blank "$t"); cn=$(num_or_blank "$c")
    # Prefer claude_trust, then general trust.
    python3 - "$cn" "$tn" "$best_claude" "$best_trust" "$kind" <<'PY' >"$WORK/better"
import sys
cn, tn, bc, bt = map(float, sys.argv[1:5])
kind = sys.argv[5]
print("yes" if (cn, tn) > (bc, bt) else "no")
PY
    if [ "$(cat "$WORK/better")" = yes ]; then
      best_claude=$cn; best_trust=$tn; best_profile="$kind"
    fi
  done
fi

echo
echo "=== summary ==="
echo "direct_whoami_trust=$(cat "$WORK/direct_trust.txt")  direct_claude_trust=$(cat "$WORK/direct_claude_trust.txt")  colo=$(cat "$WORK/direct_colo.txt")  loc=$(cat "$WORK/direct_loc.txt")"
echo "nodes_total=$total  nodes_reachable=$reachable"
echo "best_node=${best:-none}  best_trust=$best_trust  best_claude_trust=$best_claude  best_config=$best_profile"
if python3 - "$best_claude" "$best_trust" "$TARGET" <<'PY'
import sys
c, t, target = map(float, sys.argv[1:4])
sys.exit(0 if max(c, t) >= target else 1)
PY
then
  echo "target_$TARGET=reached"
else
  echo "target_$TARGET=NOT reached (honest; score is the exit IP's ipbook reputation, DNS tweaks cannot turn a datacenter/VPN IP into $TARGET)"
fi
log "done"
