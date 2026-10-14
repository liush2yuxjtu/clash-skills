#!/usr/bin/env bash
# Local verification (replaces CI). Run from anywhere: bash skills/verify-skill/verify.sh
# Optional: BASHES="bash /usr/local/bin/bash3.2" to run the probe tests under several bash binaries.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROBE="$ROOT/skills/clash-node-probe/clash-probe.sh"
HERE="$ROOT/skills/verify-skill"
BASHES="${BASHES:-bash}"
pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
ko(){ fail=$((fail+1)); echo "FAIL  $*"; }
sk(){ skip=$((skip+1)); echo "SKIP  $*"; }
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t verify)
MOCK_PID=""
cleanup(){ [ -n "$MOCK_PID" ] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$TMP"; }
trap cleanup EXIT

echo "== syntax (bash -n)"
for b in $BASHES; do
  for f in "$PROBE" "$HERE/verify.sh"; do
    if "$b" -n "$f"; then ok "$b -n $(basename "$f")"; else ko "$b -n $(basename "$f")"; fi
  done
done
echo "== bash4-only constructs"
if grep -nE '(^|[^[:alnum:]_])(mapfile|readarray|declare -A|local -A|typeset -A)([^[:alnum:]_]|$)|\$\{[A-Za-z_]+(,,|\^\^)' "$PROBE"; then ko "bash4-only construct in clash-probe.sh"; else ok "no mapfile/readarray/declare -A/case-modifiers"; fi

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$PROBE" "$HERE/verify.sh"; then ok "shellcheck -S error"; else ko "shellcheck -S error"; fi
else sk "shellcheck not installed"; fi

echo "== JSON (.claude-plugin)"
for j in "$ROOT/.claude-plugin/marketplace.json" "$ROOT/.claude-plugin/plugin.json"; do
  if [ ! -f "$j" ]; then ko "missing $j"; continue; fi
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$j" 2>/dev/null; then ok "valid JSON $(basename "$j")"; else ko "invalid JSON $(basename "$j")"; fi
done
python3 - "$ROOT" <<'PY' && ok "marketplace/plugin fields consistent" || ko "marketplace/plugin fields"
import json,sys,os
r=sys.argv[1]; m=json.load(open(r+"/.claude-plugin/marketplace.json")); p=json.load(open(r+"/.claude-plugin/plugin.json"))
assert m["name"] and m["owner"]["name"] and m["plugins"]
for e in m["plugins"]:
    assert e["name"] and e["source"]; assert ".." not in e["source"]
    assert os.path.isdir(os.path.join(r, e["source"]))
assert p["name"]==m["plugins"][0]["name"], "entry name != plugin.json name"
PY

echo "== SKILL.md frontmatter"
for s in "$ROOT"/skills/*/SKILL.md; do
  if python3 - "$s" <<'PY'
import sys,re
t=open(sys.argv[1],encoding="utf-8").read()
m=re.match(r"---\n(.*?)\n---\n",t,re.S); assert m,"no frontmatter"
kv=dict(l.split(":",1) for l in m.group(1).splitlines() if ":" in l)
name=kv.get("name","").strip(); assert re.fullmatch(r"[a-z0-9-]+",name),"bad name"
assert kv.get("description","").strip(),"no description"
import os; assert name==os.path.basename(os.path.dirname(sys.argv[1])),"name != dir"
PY
  then ok "frontmatter $(basename "$(dirname "$s")")"; else ko "frontmatter $s"; fi
done

echo "== mock Clash API"
command -v curl >/dev/null || { ko "curl needed for mock tests"; }
LOG="$TMP/mock.log"; : > "$LOG"
MOCK_LOG="$LOG" MOCK_SECRET=s3cret python3 "$HERE/mock_clash.py" > "$TMP/port" 2>"$TMP/mock.err" &
MOCK_PID=$!
i=0; while [ ! -s "$TMP/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
MPORT=$(head -1 "$TMP/port")
[ -n "$MPORT" ] || ko "mock did not start: $(cat "$TMP/mock.err")"
# A closed port: proxy requests fail fast, so the run stays offline.
DEAD=1
mutations(){ grep -cE '^(PUT|PATCH) ' "$LOG"; }
for b in $BASHES; do
  echo "-- using $b ($("$b" -c 'echo $BASH_VERSION'))"
  cd "$TMP" || exit 1
  : > "$LOG"
  API=127.0.0.1:$DEAD SECRET=x "$b" "$PROBE" >out 2>err; rc=$?
  if [ $rc -ne 0 ] && grep -q 'unreachable' err && [ "$(mutations)" = 0 ]; then ok "[$b] unreachable API exits early, no PUT/PATCH"; else ko "[$b] unreachable (rc=$rc) $(cat err)"; fi
  : > "$LOG"
  API=127.0.0.1:$MPORT SECRET=wrong "$b" "$PROBE" >out 2>err; rc=$?
  if [ $rc -ne 0 ] && grep -q 'SECRET' err && [ "$(mutations)" = 0 ]; then ok "[$b] bad SECRET exits early, no PUT/PATCH"; else ko "[$b] bad SECRET (rc=$rc) $(cat err)"; fi
  for bad in abc -1 3x ""; do
    : > "$LOG"
    API=127.0.0.1:$MPORT SECRET=s3cret LIMIT="$bad" "$b" "$PROBE" >out 2>err; rc=$?
    # empty LIMIT falls back to default 0 (unchanged behaviour), so it must succeed
    if [ -z "$bad" ]; then [ $rc -eq 0 ] && ok "[$b] empty LIMIT defaults to 0" || ko "[$b] empty LIMIT rc=$rc"; continue; fi
    if [ $rc -ne 0 ] && grep -q 'LIMIT' err && [ "$(mutations)" = 0 ] && [ ! -s "$LOG" ]; then ok "[$b] LIMIT='$bad' rejected before any API call"; else ko "[$b] LIMIT='$bad' (rc=$rc)"; fi
  done
  : > "$LOG"
  API=127.0.0.1:$MPORT SECRET=s3cret PORT=$DEAD OUT="$TMP/o.tsv" "$b" "$PROBE" >out 2>err; rc=$?
  if [ $rc -eq 0 ] && [ "$(cut -f1 "$TMP/o.tsv" | tr '\n' ,)" = "node,NodeA,NodeB," ]; then ok "[$b] normal run lists NodeA,NodeB (DIRECT/REJECT/剩余流量 filtered)"; else ko "[$b] normal run rc=$rc tsv=$(cat "$TMP/o.tsv" 2>/dev/null)"; fi
  if tail -2 "$LOG" | grep -q '^PUT /proxies/GLOBAL {"name":"NodeA"}' && tail -1 "$LOG" | grep -q '^PATCH /configs {"mode":"rule"}'; then ok "[$b] restore re-selects NodeA and mode=rule"; else ko "[$b] restore: $(tail -2 "$LOG")"; fi
  if grep -qE '"(name|mode)":""' "$LOG"; then ko "[$b] empty value sent"; else ok "[$b] no empty values sent"; fi
  : > "$LOG"
  API=127.0.0.1:$MPORT SECRET=s3cret PORT=$DEAD LIMIT=1 OUT="$TMP/o1.tsv" "$b" "$PROBE" >out 2>err
  [ "$(grep -c . "$TMP/o1.tsv")" = 2 ] && ok "[$b] LIMIT=1 probes one node" || ko "[$b] LIMIT=1"
  cd "$ROOT" || exit 1
done
echo "== result: $pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ]
