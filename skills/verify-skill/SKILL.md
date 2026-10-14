---
name: verify-skill
description: Use before committing or pushing changes to this repo (clash-skills) to run the local verification suite (there is no CI) — bash syntax, optional shellcheck, mock Clash API tests of clash-probe.sh, and validation of .claude-plugin JSON and SKILL.md frontmatter. Also use for optional live-verify against a real mihomo + subscription/config (never committed).
---
# Local verification (no CI)

This repo intentionally has no GitHub Actions. Run this locally before every push.

## Run
```bash
bash skills/verify-skill/verify.sh
# also test under other bash binaries, e.g. macOS /bin/bash 3.2:
BASHES="bash /bin/bash" bash skills/verify-skill/verify.sh
```
Needs `bash`, `curl`, `python3`. `shellcheck` is used if installed, otherwise skipped. Exit code 0 = all passed.

## What it checks
1. `bash -n` on `clash-probe.sh`, `verify.sh` and `live-verify.sh`, and a grep for bash4-only constructs in `clash-probe.sh` (`mapfile`, `declare -A`, …).
2. `shellcheck -S error` (skipped if not installed).
3. `.claude-plugin/marketplace.json` and `plugin.json` are valid JSON, required fields present, names match.
4. Every `skills/*/SKILL.md` has frontmatter with `name` (= directory) and `description`.
5. Runs `clash-probe.sh` against `mock_clash.py` (a tiny local Clash API, random port, offline):
   - unreachable API and wrong SECRET exit early with **no PUT/PATCH**;
   - non-numeric LIMIT rejected before any API call;
   - normal run lists the mock nodes and restores the original GLOBAL/mode, never sending empty values.

Not covered by `verify.sh`: a real Clash/mihomo, real proxying, ipbook.net / claude.ai lookups. That is `live-verify.sh` (below).

## Live verify (real mihomo)

`live-verify.sh` is an **optional, local-only** path. It downloads the latest MetaCubeX/mihomo `linux-amd64` binary, starts it with a subscription or a local YAML, measures the VM's **direct** ipbook trust score, then scores every node through the mixed port, prints a name/score table, tries DNS optimizations (fake-ip vs redir-host, remote DoH), and **always stops mihomo** on exit.

Never commit the subscription URL, controller secret, profile YAML, or probe TSVs. Keep them outside the repo or rely on `.gitignore`.

```bash
# Preferred: env holds the airport subscription (not printed, not committed)
CLASH_SUB_URL='…' bash skills/verify-skill/live-verify.sh

# Fallback if the subscription fetch fails: a local Clash Verge dump
CLASH_CONFIG=/path/to/profile.yaml bash skills/verify-skill/live-verify.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `CLASH_SUB_URL` | *(optional)* | Subscription URL. Tried first; on failure the script falls back to `CLASH_CONFIG` |
| `CLASH_CONFIG` | *(optional)* | Path to a local mihomo YAML. Required if the subscription fetch fails |
| `SECRET` | random | `external-controller` secret written into the runtime config |
| `PORT` | `7890` | mixed/HTTP port |
| `API` | `127.0.0.1:9090` | external-controller address |
| `TARGET_SCORE` | `100` | Reported target. The script does **not** fake a 100 |
| `SKIP_UNREACHABLE` | `1` | Passed through to `clash-probe.sh`: delay-test first, mark dead nodes `-` |
| `LIVE_VERIFY_SKIP_OPT` | `0` | Set to `1` to skip DNS restarts |
| `PRINT_IPS` | `0` | Set to `1` only on your machine if you really want exit IPs in the table |

The printed table omits exit IPs. A 100 on ipbook means a clean residential-looking exit; airport datacenter/VPN IPs typically score 0 and DNS tweaks will not change that. Report the best measured score honestly.
