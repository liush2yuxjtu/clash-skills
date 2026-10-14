# clash-skills — Claude Code skills for Clash / mihomo

> 一个 bash + curl 脚本，查看每个 Clash 节点的出口 IP、Claude 实际看到的出口 IP，以及这些 IP 的信任分。

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: bash 4+](https://img.shields.io/badge/shell-bash%204%2B-4EAA25?logo=gnubash&logoColor=white)](skills/clash-node-probe/clash-probe.sh)
[![Agent Skill](https://img.shields.io/badge/Claude%20Code-Agent%20Skill-orange)](https://code.claude.com/docs/en/skills)

[English](README.md) · [中文](README_zh.md)

`clash-skills` 是一组给 **Clash**、**mihomo**、**Clash Verge** 用户的 **Claude Code / Agent Skill** 小工具。第一个 skill 是 **`clash-node-probe`**：逐个切换 `GLOBAL` 组里的节点，记录每个节点的**出口 IP**、国家/地区、第三方 **IP 信任分（trust score）**，以及 `claude.ai` 看到的出口 IP 和位置，结果写入 TSV 文件。

## 为什么需要它

很多 Clash 配置用了**分流（split routing）**：不同域名可能从不同出口出去，所以通用"查 IP"网站显示的 IP **不一定**是某个服务看到的 IP。`clash-node-probe` 对每个节点两边都测一遍，让你知道每条路由实际用的是哪个出口、IP 信誉分多少。它是网络诊断工具，只读取和报告。

## 功能

- **每个节点的出口 IP 和国家**，强制 IPv4（`curl -4`），避免 IPv6/直连路径混进结果
- **Claude 侧出口 IP 和位置**，来自 `https://claude.ai/cdn-cgi/trace`，和通用出口 IP 放在一起，分流情况一眼可见
- **IP 信任分**来自 ipbook.net（`trustScore`），同一 IP 只查一次
- **安全切换模式**：先保存当前模式和 `GLOBAL` 选择，退出时（包括 Ctrl-C）通过 `trap … EXIT` 自动恢复
- **只需要 bash + curl**，不用 Python 或 jq。支持 Windows Git Bash，emoji/中文节点名也能正常处理
- 自动跳过内置项（`DIRECT`、`REJECT` 等）和"剩余流量/到期/官网"之类的信息条目
- `LIMIT=N` 只测前 N 个节点，适合快速试跑

## 快速开始

```bash
git clone https://github.com/liush2yuxjtu/clash-skills && cd clash-skills/skills/clash-node-probe
SECRET='你的控制器密钥' LIMIT=3 ./clash-probe.sh   # 先测 3 个节点
SECRET='你的控制器密钥' ./clash-probe.sh           # 测全部节点
```

## 安装为 Claude Code skill

### 方式 A：插件市场（推荐）

在 Claude Code 中执行：

```
/plugin marketplace add liush2yuxjtu/clash-skills
/plugin install clash-skills@clash-skills
```

装好后以 `/clash-skills:clash-node-probe` 调用。之后用 `/plugin marketplace update clash-skills` 更新。

### 方式 B：手动复制 skill

Claude Code 从 `~/.claude/skills/<skill-name>/SKILL.md` 加载个人 skill，从 `.claude/skills/<skill-name>/SKILL.md` 加载项目 skill（[官方文档](https://code.claude.com/docs/en/skills)）。

```bash
# 个人级（本机所有项目可用）
mkdir -p ~/.claude/skills
cp -r skills/clash-node-probe ~/.claude/skills/

# 或仅当前项目
mkdir -p .claude/skills
cp -r skills/clash-node-probe .claude/skills/
```

装好后可以对 Claude Code 说"测一下我的 Clash 节点，看看哪些节点访问 claude.ai 时出口 IP 不一样"，也可以直接输入 `/clash-node-probe`。新 skill 不用重启就能生效。这个 skill 同样符合开放的 [Agent Skills](https://agentskills.io) 格式。

## 使用

```bash
SECRET='your-secret' API=127.0.0.1:9097 PORT=7897 ./clash-probe.sh
```

每测完一行就打印出来，并追加到 `clash_probe_YYYYMMDD_HHMM.tsv`。结束时 stderr 会输出 `restored mode=… GLOBAL=…` 和 `saved: <文件名>`。

**示例输出**（仅作示意：IP 取自 RFC 5737 文档保留段，节点名和分数都是编的）：

| node | exit_ip | country | trust | claude_ip | claude_trust | claude_loc |
|---|---|---|---|---|---|---|
| HK-01 | 192.0.2.10 | HK | 82 | 192.0.2.10 | 82 | HK |
| JP-02 | 198.51.100.24 | JP | 90 | 203.0.113.7 | 41 | US |
| US-03 | 203.0.113.55 | US | 67 | 203.0.113.55 | 67 | US |

在这个虚构的例子里，`JP-02` 被分流了：普通流量从日本出去，而 `claude.ai` 的流量走了另一个美国 IP，分数也更低。`-` 表示那次查询失败或超时。

## 配置

所有设置都通过环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SECRET` | *(必填)* | Clash/mihomo `external-controller` 的密钥，不设置脚本会直接退出 |
| `API` | `127.0.0.1:9097` | 外部控制器地址（`host:port`，不带协议） |
| `PORT` | `7897` | 本地 mixed/HTTP 代理端口（Clash Verge 默认 7897） |
| `LIMIT` | `0` | 只测前 N 个节点，`0` 表示全部 |
| `OUT` | `clash_probe_<YYYYMMDD_HHMM>.tsv` | 输出文件路径 |

TSV 列：`node  exit_ip  country  trust  claude_ip  claude_trust  claude_loc`。

## 工作原理

1. 读取 `GET /proxies/GLOBAL`（当前选择和节点列表）和 `GET /configs`（当前模式）。
2. 注册 `trap`，无论脚本怎么退出都恢复原来的 `GLOBAL` 选择和模式。
3. 把模式切到 `global`（`PATCH /configs`）。
4. 对每个节点：先选中它（`PUT /proxies/GLOBAL`），等 1 秒，然后经 `127.0.0.1:$PORT` 请求：
   - `https://ipbook.net/api/whoami`（IPv4）→ 通用出口 IP
   - `https://claude.ai/cdn-cgi/trace` → `ip=` 和 `loc=`
5. 用 `https://ipbook.net/api/risk-lookup?ip=…` 查每个 IP，得到 `trustScore` 和 `country`。
6. 恢复原来的模式和节点。

> ⚠️ 运行期间**所有流量**会暂时走 global 模式，大约每秒换一个节点。经过代理的远程会话（SSH/RDP）可能会断开。

## 环境要求与平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Linux | ✅ | 一般已经装好 bash 4+ 和 curl |
| Windows（Git Bash） | ✅ | 脚本主要就是为这个场景写的。JSON 通过 stdin 传给 `curl.exe`，非 ASCII 节点名不会乱码 |
| macOS | ⚠️ 需 bash 4+ | 系统自带的 bash 是 3.2，没有 `mapfile` / `declare -A`。请用 Homebrew 装 bash 4+（`brew install bash`），然后运行 `$(brew --prefix)/bin/bash ./clash-probe.sh` |
| WSL | 理论可行 | 未测试。需要 `127.0.0.1` 能连到 Windows 侧的 Clash |

另外需要：
- 开启了 `external-controller` 的 Clash / mihomo（Clash Verge：设置 → 外部控制器），记下地址和密钥。
- mixed/HTTP 代理端口。
- `curl`，以及标准的 `grep`/`sed`/`tr`。

## 隐私

脚本会经由各个节点访问以下外部服务：
- **ipbook.net**：`api/whoami`（能看到你的出口 IP）和 `api/risk-lookup?ip=…`（你测的每个出口 IP 都会作为查询参数发过去）。
- **claude.ai**：`cdn-cgi/trace`（Cloudflare 标准 trace 接口，会显示请求来源 IP）。

除此之外不调用任何服务，也不会向作者发送数据。TSV 只保存在本地。里面有你的出口 IP 和节点名，分享前请先打码。

## 免责声明

这是一个**网络诊断**工具，用来报告在你自己的网络配置下，不同服务看到的是哪个出口 IP。它不会改变任何服务的访问判断方式，也不是用来规避任何服务的条款或地区可用性限制的。请遵守你所在地的法律法规、网络服务商的条款，以及你使用的各项服务的条款。

信任分来自第三方（ipbook.net），不具权威性，也可能会变。

**本项目与 Anthropic、ipbook.net、Clash / mihomo 项目均无关联。** Claude 是 Anthropic 的商标。

## 路线图

- [x] 添加 `LICENSE` 文件（MIT）
- [ ] 可选的 IPv6 探测列
- [ ] 可配置目标列表（不只检测 `claude.ai`）
- [ ] 支持指定代理组，不只是 `GLOBAL`
- [ ] 更多 Clash/mihomo skills（规则命中检查、批量测延迟）

欢迎在 [Issues](https://github.com/liush2yuxjtu/clash-skills/issues) 提建议。

## 参与贡献

欢迎 PR。请注意：
- 每个 skill 保持**只用 bash + curl**，并在 Windows Git Bash 下测试（非 ASCII 内容走 stdin，不要放在 argv 里）。
- 每个 skill 放在 `skills/<name>/`，`SKILL.md` 的 frontmatter 要有 `name` 和 `description`。
- 不要提交真实 IP、控制器密钥或订阅链接。
- 本仓库没有 CI。push 前请在本地运行验证 skill 并确保全部通过（兼容 macOS 自带 bash 3.2）：
  ```bash
  bash skills/verify-skill/verify.sh
  BASHES="bash /bin/bash" bash skills/verify-skill/verify.sh   # 同时用 macOS /bin/bash 3.2 测试
  ```
  它会做语法检查、shellcheck（已安装时）、用模拟 Clash API 运行探测脚本，并校验 `.claude-plugin/*.json` 和 SKILL.md frontmatter。在 Claude Code 里也可以直接让它运行 `verify-skill`。
  可选的 **live** 验证（会下载 mihomo，不要提交密钥）：
  ```bash
  CLASH_SUB_URL='…' bash skills/verify-skill/live-verify.sh
  # 或：CLASH_CONFIG=/path/to/local-profile.yaml bash skills/verify-skill/live-verify.sh
  ```
  详见 `skills/verify-skill/SKILL.md`。订阅链接、控制器密钥和配置文件请放在 `.gitignore` 里。

## 许可证

MIT。详见 [LICENSE](LICENSE)。
