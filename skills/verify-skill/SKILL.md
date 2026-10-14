---
name: verify-skill
description: Use before committing or pushing changes to this repo (clash-skills) to run the local verification suite (there is no CI) — bash syntax, optional shellcheck, mock Clash API tests of clash-probe.sh, and validation of .claude-plugin JSON and SKILL.md frontmatter.
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
1. `bash -n` on `clash-probe.sh` and `verify.sh`, and a grep for bash4-only constructs (`mapfile`, `declare -A`, …).
2. `shellcheck -S error` (skipped if not installed).
3. `.claude-plugin/marketplace.json` and `plugin.json` are valid JSON, required fields present, names match.
4. Every `skills/*/SKILL.md` has frontmatter with `name` (= directory) and `description`.
5. Runs `clash-probe.sh` against `mock_clash.py` (a tiny local Clash API, random port, offline):
   - unreachable API and wrong SECRET exit early with **no PUT/PATCH**;
   - non-numeric LIMIT rejected before any API call;
   - normal run lists the mock nodes and restores the original GLOBAL/mode, never sending empty values.

Not covered: a real Clash/mihomo, real proxying, ipbook.net / claude.ai lookups.
