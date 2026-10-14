---
name: clash-node-probe
description: Use when you need to test every node in a local Clash / mihomo (Clash Verge) client for its real exit IP, the exit IP Claude/Anthropic sees, and an ipbook.net trust score, using only bash + curl (works in Git Bash on Windows).
---
# Clash node probe (bash + curl only)

Measures, for each node: general exit IP, country, trust score, and the exit IP seen by `claude.ai` (airports often split-route AI domains to a different, dirtier exit).

## Requirements
- Clash/mihomo external controller enabled (Clash Verge: Settings → External controller). Note the address and secret.
- Mixed/HTTP port (Clash Verge default 7897).
- bash + curl. On Windows use Git Bash.

## Run
```bash
SECRET='your-secret' API=127.0.0.1:9097 PORT=7897 ./clash-probe.sh        # all nodes
SECRET='your-secret' LIMIT=3 ./clash-probe.sh                              # quick test
SKIP_UNREACHABLE=1 PROBE_TIMEOUT=12 SWITCH_WAIT=0.3 ./clash-probe.sh        # skip dead nodes
```
Output: a TSV `clash_probe_<time>.tsv` with columns `node exit_ip country trust claude_ip claude_trust claude_loc`.

Optional env: `PROBE_TIMEOUT` (curl `-m`, default 15), `SWITCH_WAIT` (seconds after selecting a node, default 1), `SKIP_UNREACHABLE=1` (Clash delay-test first; unreachable rows become `-`).

## How it works
1. Saves current mode and the `GLOBAL` selection, then sets mode to `global` (restored on exit via `trap`, even on Ctrl-C).
2. For each node in `GLOBAL`: selects it, fetches `https://ipbook.net/api/whoami` (IPv4) and `https://claude.ai/cdn-cgi/trace` through the mixed port.
3. Scores each IP with `https://ipbook.net/api/risk-lookup?ip=` (`consensus.trustScore`, cached per IP).

## Gotchas
- Windows `curl.exe` mangles non-ASCII (emoji / Chinese node names) passed as argv. JSON bodies are piped via stdin (`--data-binary @-`). Keep it that way.
- Force IPv4 (`-4`) for whoami, otherwise a direct/IPv6 path shows your real ISP IPv6.
- Global mode briefly reroutes ALL traffic; remote sessions to the machine may drop while it runs.
- Pick nodes where `claude_trust` is high, not just `trust`.
