# clash-skills — Claude Code skills for Clash / mihomo

> See the exit IP each Clash node gives you, and the one Claude actually sees, with its IP trust score. One bash + curl script.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: bash 4+](https://img.shields.io/badge/shell-bash%204%2B-4EAA25?logo=gnubash&logoColor=white)](skills/clash-node-probe/clash-probe.sh)
[![Agent Skill](https://img.shields.io/badge/Claude%20Code-Agent%20Skill-orange)](https://code.claude.com/docs/en/skills)

[English](README.md) · [中文](README_zh.md)

`clash-skills` is a small collection of **Claude Code / Agent Skill** helpers for **Clash**, **mihomo** and **Clash Verge** users. The first skill, **`clash-node-probe`**, walks every node in your `GLOBAL` group and records each node's **exit IP**, country, a third-party **IP trust score**, and the exit IP and location reported by `claude.ai`. Results go into a TSV file.

## Why

Many Clash configs use **split routing**: different domains can leave through different exits. So the IP a general "what is my IP" site shows you is **not always** the IP a particular service sees. `clash-node-probe` checks both for every node, so you know which exit each route really uses and how its IP reputation scores. It's a network diagnostic: it only reads and reports.

## Features

- **Per-node exit IP + country**, IPv4-forced (`curl -4`), so an IPv6/direct path doesn't show up by mistake
- **Claude-facing exit IP + location** from `https://claude.ai/cdn-cgi/trace`, shown next to the general exit IP so split routing is easy to spot
- **IP trust score** from ipbook.net (`trustScore`), cached per IP
- **Safe mode switching**: saves your current mode and `GLOBAL` selection, then restores both on exit (`trap … EXIT`, Ctrl-C included)
- **Only needs bash + curl.** No Python, no jq. Works in Git Bash on Windows and handles non-ASCII (emoji/Chinese) node names
- Skips built-ins (`DIRECT`, `REJECT`, …) and common provider info entries (remaining traffic / expiry / website)
- `LIMIT=N` runs a quick test on the first N nodes

## Quick start

```bash
git clone https://github.com/liush2yuxjtu/clash-skills && cd clash-skills/skills/clash-node-probe
SECRET='your-controller-secret' LIMIT=3 ./clash-probe.sh   # quick test on 3 nodes
SECRET='your-controller-secret' ./clash-probe.sh           # all nodes
```

## Install as a Claude Code skill

### Option A: plugin marketplace (recommended)

Inside Claude Code:

```
/plugin marketplace add liush2yuxjtu/clash-skills
/plugin install clash-skills@clash-skills
```

The skill is then available as `/clash-skills:clash-node-probe`. Update later with `/plugin marketplace update clash-skills`.

### Option B: copy the skill manually

Claude Code loads personal skills from `~/.claude/skills/<skill-name>/SKILL.md` and project skills from `.claude/skills/<skill-name>/SKILL.md` ([official docs](https://code.claude.com/docs/en/skills)).

```bash
# Personal (all your projects on this machine)
mkdir -p ~/.claude/skills
cp -r skills/clash-node-probe ~/.claude/skills/

# Or project-only
mkdir -p .claude/skills
cp -r skills/clash-node-probe .claude/skills/
```

Then ask Claude Code something like *"probe my Clash nodes and tell me which ones give claude.ai a different exit IP"*, or call it directly with `/clash-node-probe`. Claude Code picks up new skills without a restart. The skill also follows the open [Agent Skills](https://agentskills.io) format.

## Usage

```bash
SECRET='your-secret' API=127.0.0.1:9097 PORT=7897 ./clash-probe.sh
```

Each row is printed as it's measured and appended to `clash_probe_YYYYMMDD_HHMM.tsv`. When the run ends you get `restored mode=… GLOBAL=…` and `saved: <file>` on stderr.

**Example output.** These are illustrative values: IPs come from the RFC 5737 documentation ranges, and node names and scores are made up.

| node | exit_ip | country | trust | claude_ip | claude_trust | claude_loc |
|---|---|---|---|---|---|---|
| HK-01 | 192.0.2.10 | HK | 82 | 192.0.2.10 | 82 | HK |
| JP-02 | 198.51.100.24 | JP | 90 | 203.0.113.7 | 41 | US |
| US-03 | 203.0.113.55 | US | 67 | 203.0.113.55 | 67 | US |

In this made-up example, `JP-02` is split-routed: general traffic leaves from Japan, but `claude.ai` traffic leaves from a different US IP that scores lower. A `-` means that lookup failed or timed out.

## Configuration

All settings are environment variables:

| Variable | Default | Description |
|---|---|---|
| `SECRET` | *(required)* | Clash/mihomo `external-controller` secret. The script exits if this isn't set |
| `API` | `127.0.0.1:9097` | External controller address (`host:port`, no scheme) |
| `PORT` | `7897` | Local mixed/HTTP proxy port (Clash Verge default 7897) |
| `LIMIT` | `0` | Probe only the first N nodes. `0` means all of them |
| `OUT` | `clash_probe_<YYYYMMDD_HHMM>.tsv` | Output file path |

TSV columns: `node  exit_ip  country  trust  claude_ip  claude_trust  claude_loc`.

## How it works

1. Reads `GET /proxies/GLOBAL` (current selection and node list) and `GET /configs` (current mode).
2. Registers a `trap` that restores the original `GLOBAL` selection and mode on any exit.
3. Switches the mode to `global` (`PATCH /configs`).
4. For each node: selects it (`PUT /proxies/GLOBAL`), waits 1 s, and then through `127.0.0.1:$PORT`:
   - `https://ipbook.net/api/whoami` (IPv4) → general exit IP
   - `https://claude.ai/cdn-cgi/trace` → `ip=` and `loc=`
5. Looks up each IP with `https://ipbook.net/api/risk-lookup?ip=…` to get `trustScore` and `country`.
6. Restores your original mode and node.

> ⚠️ While it runs, **all traffic** briefly goes through global mode and changes nodes every second or so. Remote sessions (SSH/RDP) through the proxy may drop.

## Requirements & platform support

| Platform | Status | Notes |
|---|---|---|
| Linux | ✅ | bash 4+ and curl are usually already installed |
| Windows (Git Bash) | ✅ | The case the script was written for. JSON bodies go through stdin so non-ASCII names survive `curl.exe` |
| macOS | ⚠️ needs bash 4+ | The system bash is 3.2, which lacks `mapfile` / `declare -A`. Install bash 4+ with Homebrew (`brew install bash`) and run `$(brew --prefix)/bin/bash ./clash-probe.sh` |
| WSL | likely ✅ | Not tested. `127.0.0.1` has to reach the Windows-side Clash |

You also need:
- Clash / mihomo with `external-controller` enabled (Clash Verge: Settings → External controller). Note the address and secret.
- The mixed/HTTP proxy port.
- `curl`, plus standard `grep`/`sed`/`tr`.

## Privacy

The script contacts these external services through each node:
- **ipbook.net**: `api/whoami` (sees your exit IP) and `api/risk-lookup?ip=…` (gets each exit IP you probe as a query parameter).
- **claude.ai**: `cdn-cgi/trace` (a standard Cloudflare trace endpoint that shows your request IP).

Nothing else is called, and no data goes to the author. The output TSV stays on your machine. Clean it before sharing, because it contains your exit IPs and node names.

## Disclaimer

This is a **network diagnostics** tool. It reports which exit IP different services see from your own network setup. It does not change how any service decides access, and it isn't meant to get around any service's terms or regional availability. Follow the terms of service of your network provider and of every service you use.

Trust scores come from a third party (ipbook.net). They aren't authoritative and may change.

**Not affiliated with Anthropic, ipbook.net, or the Clash / mihomo projects.** Claude is a trademark of Anthropic.

## Roadmap

- [x] `LICENSE` file (MIT)
- [ ] Optional IPv6 probe column
- [ ] Configurable target list (check more services than `claude.ai`)
- [ ] Probe a chosen proxy group, not just `GLOBAL`
- [ ] More Clash/mihomo skills (rule-hit checker, latency sweep)

Ideas welcome in [Issues](https://github.com/liush2yuxjtu/clash-skills/issues).

## Contributing

PRs are welcome. Please:
- Keep each skill **bash + curl only** and test it in Git Bash on Windows (send non-ASCII through stdin, not argv).
- Put every skill in `skills/<name>/` with a `SKILL.md` that has `name` and `description` frontmatter.
- Never commit real IPs, controller secrets or subscription URLs.
- There is no CI. Before pushing, run the local verification skill and make sure it passes (it also works under macOS bash 3.2):
  ```bash
  bash skills/verify-skill/verify.sh
  BASHES="bash /bin/bash" bash skills/verify-skill/verify.sh   # also test macOS /bin/bash 3.2
  ```
  It checks syntax, shellcheck (if installed), runs the probe against a mock Clash API, and validates `.claude-plugin/*.json` and SKILL.md frontmatter. In Claude Code you can just ask it to run `verify-skill`.
  Optional **live** check (downloads mihomo, never commits secrets):
  ```bash
  CLASH_SUB_URL='…' bash skills/verify-skill/live-verify.sh
  # or: CLASH_CONFIG=/path/to/local-profile.yaml bash skills/verify-skill/live-verify.sh
  ```
  See `skills/verify-skill/SKILL.md`. Keep subscription URLs, controller secrets and profile dumps gitignored.

## License

MIT. See [LICENSE](LICENSE).
