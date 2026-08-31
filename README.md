# opencode-cluster-server-tester

[English](README.en.md) | 中文

多 worker opencode 集群：一台编排器通过 HTTP 驱动 N 个 `opencode serve` worker，具备 agent 间（A2A）通信、基于文件的记忆和观察入口。工具包代号 `oc-cluster`（脚本与路径中统一使用该短名）。

一套基于 [opencode](https://opencode.ai) 的小型、文件驱动的多智能体集群：一台编排器主机（Windows + WSL）驱动 N 台 Linux worker 机器，每台以 systemd 服务运行 `opencode serve`。worker 之间通过机器可解析的 A2A（agent-to-agent）协议互相通信，把任务记忆持久化为 JSONL journal 加一份提炼后的长期记忆索引，并暴露两个观察面（远程 TUI attach + 浏览器 web UI）。

面向实验室/硬件测试环境设计——worker 通常没有直接外网出口：worker 的 LLM 流量经 SSH 反向隧道从编排器穿出，因此 worker 只需要 SSH 可达。

## 文档语言策略

本仓库文档以中英双语维护：中文版为 `*.md`，英文版为 `*.en.md`。后续每一次文档更新必须中英文各一份同步修改。

开发工作笔记（`docs/dev/` 下的 `DEVLOG.md` 与 `ISSUES.md`）为中文单语工作文档，不入双语流程。

## 特性

- **环境变量驱动拓扑** — 所有机器/端口/模型集中在一个 `env/cluster.env` 里；新增一个 worker 只需加一段配置再重跑一次。
- **幂等的分阶段脚本**（`P0` 探测 → `P1` 安装 → `P2` serve+工作区 → `P3` 调优 → `P4` 端到端 → `P5` 观察口 → `P5.5` A2A → `P6` 演练），每阶段都带门禁，并在目标机上留有便于回滚的备份。
- **离线可装** — opencode tarball 由编排器推送；worker 不依赖任何软件源。
- **worker 间 A2A** — 紧凑 JSON 信封、严格 JSON 回复、深度受限的委托、每跳写一条 JSONL 台账。
- **两层记忆** — 每个任务只追加写入的 `journal.jsonl` + 每个会话自动加载的 30 行提炼版 `MEMORY.md`。
- **可观测性** — tmux 中的 `opencode attach` TUI 窗格、经 SSH 端口转发访问的每 worker web UI、逐跳 A2A 台账。

## 快速开始（编排器：WSL）

```bash
# 0) 前置条件：WSL Debian/Ubuntu，装有 tmux、sshpass、python3、curl
sudo apt-get install -y tmux sshpass curl python3

# 1) 获取仓库并完成站点配置
git clone <this-repo> oc-cluster && cd oc-cluster
cp env/cluster.env.example env/cluster.env   # 编辑：worker IP/名称、模型、tarball 路径

# 2) 放置密钥（已 gitignore，绝不入库）
secrets/<NAME>.sshpass   # 每个 worker 的 SSH 密码（单行）
secrets/auth.json        # opencode auth.json（在任意执行过 `opencode auth login` 的机器上取得）

# 3) 一键部署
bash scripts/bootstrap.sh --with-hub --with-drills
```

验证矩阵、回滚表、加 worker 配方：[docs/DEPLOY.md](docs/DEPLOY.md)（[English](docs/DEPLOY.en.md)）。
设计与协议细节：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)（[English](docs/ARCHITECTURE.en.md)）。
已知上游问题与规避手段：[docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md)（[English](docs/KNOWN_ISSUES.en.md)）。

## 仓库地图

```
env/cluster.env.example   拓扑 + 可调参数（复制为 env/cluster.env，已 gitignore）
scripts/lib.sh            公共辅助函数：ssh_cmd/ssh_put/fetch/render、worker 遍历
scripts/bootstrap.sh      按顺序执行全部阶段
scripts/p0_probe.sh       只读预检（avx2、端口门禁）
scripts/p1_install.sh     推送 tarball、安装二进制、把 LLM 域名钉到 loopback
scripts/p1_fix_sshd.sh    开启 sshd AllowTcpForwarding（drop-in，语法门禁）
scripts/p2_setup.sh       渲染并推送工作区/配置、ocserve.service、生成密码
scripts/p3_tuning.sh      SELinux 标签 + firewalld 端口（均可选、幂等）
scripts/p4_e2e.sh         编排器 -> worker API 往返验证，带每 worker 标记
scripts/p55_a2a.sh        渲染并推送每 worker 的 peers.json（A2A 目录）
scripts/p6_drill.sh       记忆 journal 演练 + 隧道自愈演练
scripts/upgrade_opencode.sh  滚动升级二进制，带备份+恢复
scripts/dispatch_task.sh     编排器侧任务派发器（WSL）：建会话 + 阻塞式发 prompt
scripts/oc.sh               编排器一站式入口（list/exec/run/fetch/put/task）
orchestrator/mcp_remote_task.py  MCP stdio server：把派发暴露成编排器 opencode 的
                             原生 `remote_task` 工具（跑在 WSL 内）
wsl/tunnel.sh             单条反向 LLM 隧道循环（worker lo:443 -> LLM:443）
wsl/tunnels_up.sh         每 worker 一条 detached tmux 隧道
wsl/hub0.sh               Hub-0：attach TUI 窗格 + web UI 端口转发
worker/                   推送到 worker 的文件（部署时渲染模板）
docs/                     架构、部署手册、已知问题
```

## 密钥布局（全部已 gitignore）

| 文件 | 用途 |
|------|------|
| `secrets/<NAME>.sshpass` | 该 worker `<USER>@<IP>` 的 SSH 密码 |
| `secrets/<NAME>.pw` | opencode serve API 密码（P2 在 worker 上生成后拉回） |
| `secrets/auth.json` | opencode auth，复制进每台 worker 的 `~/.local/share/opencode/` |
| `secrets/zai_api_key` | z.ai 标准计费 API key（供 `scripts/auth_provider_key.sh zai secrets/zai_api_key` 使用） |
| `env/cluster.env` | 你的真实 IP/名称（示例文件的副本） |
| `worker/notes.d/<NAME>.md` | 可选的每 worker 机器事实，注入其 AGENTS.md |

## 状态

已在 2-worker 实验室集群上部署并验证（opencode 1.18.x，RHEL 系 worker，SELinux Enforcing）。向上游提 issue 前，先看文档中有证据支撑的已知问题清单。

## 许可证

GPLv3 — 见 [LICENSE](LICENSE)。
