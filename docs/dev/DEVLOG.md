# 开发日志（DEVLOG）

> 用途：跨对话续接的工作笔记。站点敏感信息（IP/密码/拓扑细节）只在私有
> `deploy/DEPLOY_STATE.md`，本文件只写事实、状态与决策。
> 语言：中文工作笔记，不入双语流程（README 语言策略已注明）。

## 快照（2026-08-28）

- 仓库 HEAD：见 `git log`（本文件所在提交之后）
- 集群：编排器（Windows + WSL Debian）↔ 2 台 worker，`opencode serve` systemd 常驻
- worker 模型：`zai/glm-4.5-air`（标准 z.ai 按量计费；coding-plan OAuth 条目保留可回滚）
- 状态：部署阶段 P0-P6 全部完成；**首个真实端到端验证任务已由两个 worker agent
  自主协作跑通**（探测→装工具→配置→执行→还原全自主，A2A 协作多跳留痕）；
  过程中暴露框架问题两类共 11 项 → `docs/dev/ISSUES.md`
- 编排器原生工具：MCP `oc_remote_task` 已注册进项目配置，**重启 opencode 后生效**

## 已完成（时间线）

1. **部署**：P0 选机探测 → P1 安装+LLM 出口隧道 → P2 工作区/配置/服务 → P3
   SELinux+防火墙调优 → P4 通信打通 → P5 Hub-0 观察口 → P5.5 A2A 层 →
   P6 演练（journal 记忆、隧道自愈）。全程幂等脚本，细节见私有
   `deploy/DEPLOY_STATE.md`（含逐项回滚路径）。
2. **模型与计费切换**：coding-plan → 标准计费（`scripts/auth_provider_key.sh`
   原地合并 key，OAuth 条目保留）。
3. **能力验证**：编排器拆任务派发给双 worker，worker 通过 A2A 互相配合完成
   带现场还原的真实任务。任务本身与本仓库无关（网络类测试，细节不入库），
   其价值在于**验证了框架全链路**，并暴露 ISSUES.md 所列问题。
4. **编排器工具链**：`scripts/dispatch_task.sh`（任务派发器）→ `scripts/oc.sh`
   （一站式入口）→ `orchestrator/mcp_remote_task.py`（MCP stdio server，
   把派发暴露成编排器 opencode 的原生工具 `oc_remote_task`）。
5. **文档体系**：双语策略（用户面文档中英同步）；KNOWN_ISSUES 11 条
   （环境/上游问题，含 serve+.ts 挂死、firewalld 误报等，均有取证）。

## 未决 / 下一步（按优先级）

1. **ISSUES C 类修复执行**（见 ISSUES.md 状态列）：
   - C2 统一回复解析模块（dispatch 与 ask_peer 共用，消灭两套实现）
   - C1 流式/轮询观察模式（阻塞派发的中间进度可见化）
   - C5 任务书"前置确认清单"模板（拓扑类先验假设必须先问）
2. **B 类缓解**：`prompts/` 任务书模板库——内置 discovery+fallback 步骤、
   "失败也必须落盘证据"、状态机式 checklist（每步汇报），降低对小模型
   自觉性的依赖。
3. **A2 遗留**：交换机口间转发不稳定（STP/隔离？）排查——需要交换机侧
   配置信息，agent 侧无法独立解决。
4. **P7**：`oc_hub.py` 仪表盘（订阅全部 worker SSE，合并事件流 + 台账可读化）。
5. **重启 opencode 后**：验证 `oc_remote_task` 原生调用（当前会话仍是旧工具集）。
6. **上游 issue**：`opencode serve` + 项目 `.opencode/tools/*.ts` 挂死
   （1.18.23/24 均复现，bisect 证据在 KNOWN_ISSUES #1，CLI 不受影响）。

## 下个对话怎么续接

1. 先读本文件 + `docs/dev/ISSUES.md`（问题与方案）。
2. 站点细节（IP/密码/回滚）：私有 `deploy/DEPLOY_STATE.md`。
3. 常用入口：`scripts/oc.sh`（list/exec/run/fetch/put/task）、
   `scripts/dispatch_task.sh`、`wsl/tunnels_up.sh`+`wsl/hub0.sh`（WSL 重启后必跑）。
4. 已知坑全集：`docs/KNOWN_ISSUES.md`（11 条）。
5. 密钥/站点 env 全部 gitignored，位置见 README 密钥布局表。
