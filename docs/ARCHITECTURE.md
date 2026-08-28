# 架构

[English](ARCHITECTURE.en.md) | 中文

## 拓扑

```
+---------------------------- orchestrator host ----------------------------+
|  Windows                                                                  |
|    browser -> http://localhost:<FWD_BASE+i>  (worker web UI, Basic auth)  |
|  WSL (all orchestration runs here)                                        |
|    scripts/*.sh  --sshpass-ssh-->  workers                                |
|    tmux tun_<NAME>  : ssh -R 127.0.0.1:443:<LLM_HOST>:443  (per worker)   |
|    tmux fw_<NAME>   : ssh -L 127.0.0.1:<port>:worker:4096                 |
|    tmux hub0        : opencode attach http://<worker>:4096  (TUI panes)   |
+---------------------------------------------------------------------------+
                |                                    |
        +-------v--------+                  +-------v--------+
        | worker wk-1    |                  | worker wk-2    |
        | ocserve.service|<---- A2A HTTP -->| ocserve.service|
        | :4096          |                  | :4096          |
        | /root/ocws     |                  | /root/ocws     |
        +----------------+                  +----------------+
```

## 物理隔离 worker 的 LLM 出口

> **状态（2026-08-28）**：SSH 反向隧道方案已在部署站点整体拆除（用户决定不再使用
> SSH/内网穿透），worker 当前无 LLM 出口，替代方案评估中。本节保留作为设计参考。

worker 常处于只做白名单的实验室网络，没有到 LLM API 的直连路由。oc-cluster 不动出口策略就解决了这个问题：

1. P1 把 `127.0.0.1 <LLM_HOST>` 追加进 worker 的 `/etc/hosts`（先备份）。
2. 编排器为每台 worker 跑一条常驻 `ssh -R 127.0.0.1:443:<LLM_HOST>:443 -N`
   （tmux，自动重连循环，日志在 `~/oc_tunnels/`）。
3. worker 到 `<LLM_HOST>` 的 HTTPS 流量路径变为：worker loopback -> sshd ->
   编排器 -> 真实 API。TLS 端到端（SNI/证书原样穿透）。
4. 需要 worker 上 `AllowTcpForwarding yes` — P1b 在 `sshd -t` 门禁之后安装
   drop-in（`/etc/ssh/sshd_config.d/60-oc-forward.conf`）。

隧道断了，模型调用就失败；重连循环约 5 秒内恢复。
worker 被（AGENTS.md）要求上报隧道故障，而不是自己去"修"网络。

## worker 侧组件

| 组件 | 路径 | 说明 |
|------|------|------|
| opencode 二进制 | `/root/.opencode/bin/opencode` | 推送的 tarball，无自动更新 |
| serve API | systemd `ocserve.service`，端口 4096 | `Restart=always`，密码写进 unit（chmod 600） |
| auth | `/root/.local/share/opencode/auth.json` | 从编排器密钥复制 |
| 配置 | `/root/.config/opencode/opencode.json` | 模型 + instructions AGENTS.md/MEMORY.md |
| 工作区 | `/root/ocws` | 会话起始目录（WorkingDirectory） |
| A2A 脚本 | `/root/ocws/bin/ask_peer.{sh,py}` | 仅依赖 python3 标准库 |
| A2A 目录 | `/root/ocws/oc_tasks/a2a/peers.json` | 全部 peer + 密码，chmod 600 |
| journal | `/root/ocws/oc_tasks/journal/*.jsonl` | 只写不改的证据链 |
| LTM | `/root/ocws/MEMORY.md` + `ltm/store/` | 30 行提炼索引，自动加载 |

## 记忆模型（两层，全自动）

- **短期/情节记忆**：每完成一个任务，模型向 `oc_tasks/journal/journal.jsonl`
  追加一行 JSONL（`{"ts","task","topic","conclusion","evidence"}`）。只写不改，
  绝不自动加载进上下文——查询之前零 token 成本。
- **长期/提炼记忆**：`MEMORY.md` 上限 30 行（约 500 token），经 opencode
  `instructions` 挂载，因此每个会话付出固定的小成本。当 journal 超过 50 行，
  模型执行压缩：把新事实合并进 MEMORY.md（先备份），被取代的条目保留为一行
  删除线，然后截断 journal。细节分片放在 `ltm/store/<topic>.md`。
- **集体记忆**：A2A 回复携带 `evidence` 路径，一个 worker 可以直接取用另一台
  worker 磁盘上的证据，而不复制内容。

## A2A 协议

调用（模型经其内置 bash 工具发起——不涉及自定义工具加载，见 KNOWN_ISSUES）：

```bash
bash /root/ocws/bin/ask_peer.sh --peer <peer-name> --task <TASK-ID> \
  --intent <query|request|report> --subject "<one line>" --depth <n> \
  --body "<full message>"
```

HTTP POST `/session/<peer-session>/message` 上传输的内容：

```
[A2A] {"v":1,"from":"wk-1","task":"TASK-1","depth":1,"intent":"query",
       "subject":"...","body":"..."}
You are answering a peer agent, not a human. Reply with STRICT JSON only...
```

回复契约（按 `"status"` 正则解析）：

```json
{"status":"answered|partial|refused","body":"...","evidence":["path or cmd output"]}
```

规则：

- 每个 peer 的会话持久复用（映射在 `oc_tasks/a2a/sessions.json`）——
  上下文会累积，但 body 保持自包含。
- `depth >= 2` 拒绝（末跳规则，防止委托循环）。
- 每一跳向 `oc_tasks/journal/a2a.jsonl` 追加一条 JSONL
  （`{"ts","dir","from","to","task","intent","subject","depth","status","ms",...}`）。
- `peers.json` 存放 peer 凭据；AGENTS.md 禁止模型打印或复制其内容。

## 编排器 -> worker API（opencode serve）

- 认证：HTTP Basic，用户 `opencode`（可配），密码来自 `secrets/<NAME>.pw`。
  Bearer token 无效。
- 创建会话：`POST /session` `{}` -> `{"id": ...}`
- 阻塞式 prompt：`POST /session/{id}/message`
  `{"parts":[{"type":"text","text":"..."}]}`（注意：`{"data": ...}` 是旧格式，
  返回 400）
- 异步：`POST /session/{id}/prompt_async`；SSE：`GET /event`
- OpenAPI：`GET /doc`

## 扩展

- **新增 worker**：向 `env/cluster.env` 追加 `W3_NAME/W3_IP/W3_USER`，把
  `W3` 加进 `WORKERS`，放入 `secrets/wk-3.sshpass`，重跑 `bootstrap.sh`。
  所有阶段遍历 `$WORKERS` 且幂等。
- **新增站点相关的机器事实**：`worker/notes.d/<NAME>.md` — 渲染时注入该
  worker 的 AGENTS.md。
- **换模型/换 provider**：改 env 里的 `OC_MODEL` / `OC_LLM_HOST`；重跑 P2
  （配置渲染）— 隧道经 `tunnels_up.sh` 自动改指向。
- **规划中（P7）**：`oc_hub.py` 仪表盘，订阅所有 worker 的 SSE `GET /event`，
  汇成合并 JSONL，支持按 worker/TASK-ID/depth 过滤。
