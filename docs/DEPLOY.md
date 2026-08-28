# 部署手册

[English](DEPLOY.en.md) | 中文

一切都在编排器主机的 WSL 里执行。对 worker 的假设：Linux + systemd，SSH root 登录（否则调整 `W*_USER`），已装 python3，端口 443（loopback 隧道绑定）与 4096（serve API）空闲。

## 0. 前置条件

编排器 WSL：

```bash
sudo apt-get install -y tmux sshpass curl python3
# Hub-0 的 attach 客户端（任何装了 opencode 的机器都行）：
curl -fsSL https://opencode.ai/install | bash
```

worker 的 LLM 认证：在任意有浏览器的机器上对你的 provider 执行 `opencode auth login`，然后把生成的 `~/.local/share/opencode/auth.json` 复制到仓库的 `secrets/auth.json`。

## 1. 配置

```bash
cp env/cluster.env.example env/cluster.env
$EDITOR env/cluster.env   # worker 名称/IP/用户、模型、LLM 域名、tarball 路径
```

先在编排器侧下载一次 opencode linux x64 tarball（便于走代理）：

```bash
curl -fL -o ~/opencode-linux-x64.tar.gz \
  https://github.com/sst/opencode/releases/latest/download/opencode-linux-x64.tar.gz
```

可选的每 worker 机器事实（渲染时注入该 worker 的 AGENTS.md）：

```markdown
<!-- worker/notes.d/wk-1.md（已 gitignore） -->
- History: AC power-cycle DUT; no persistent jobs.
- 16-port NIC; BMC on the management segment.
```

## 2. 密钥（已 gitignore，绝不提交）

```bash
mkdir -p secrets
printf 'your-ssh-password' > secrets/wk-1.sshpass
printf 'your-ssh-password' > secrets/wk-2.sshpass
cp /path/to/auth.json secrets/auth.json
chmod 600 secrets/*
```

`secrets/<NAME>.pw`（serve API 密码）由 P2 在每台 worker 上生成并自动拉回——不要手工创建。

### 标准计费 provider 的 key（如 z.ai API key）

若 `OC_MODEL` 使用按 key 计费的 provider（`zai/glm-4.5-air` 等），把 key 安装进每台 worker 的 auth（原地合并；已有 OAuth 条目保留以便回滚），然后重渲染配置并重启：

```bash
bash scripts/auth_provider_key.sh zai secrets/zai_api_key
bash scripts/p2_setup.sh   # 按 OC_MODEL 重渲染 opencode.json 并重启 ocserve
bash scripts/p4_e2e.sh     # 验证往返
```

## 3. 部署

```bash
bash scripts/bootstrap.sh                 # P0 P1 P1b T P2 P3 P5.5 P4
bash scripts/bootstrap.sh --with-hub      # + Hub-0 attach 窗格与 web 转发
bash scripts/bootstrap.sh --with-drills   # + P6 记忆/隧道演练
```

各阶段幂等；单独重跑任一阶段也可以：

```bash
bash scripts/p4_e2e.sh          # 重新验证 API 往返
bash scripts/upgrade_opencode.sh https://github.com/sst/opencode/releases/latest/download/opencode-linux-x64.tar.gz
```

## 4. 验证矩阵

| 检查项 | 命令（WSL） | 预期 |
|--------|-------------|------|
| 隧道已起 | `tmux ls` | 每个 worker 一个 `tun_<NAME>` |
| worker 隧道监听 | `ssh <worker> ss -tlnp \| grep :443` | sshd 在 127.0.0.1:443 LISTEN |
| worker LLM 出口 | worker 内：`curl -sI https://<LLM_HOST>` | HTTP 200/301 |
| serve 认证 | P4 输出 `GET /session -> 200` | 200 |
| 模型往返 | P4 每 worker 输出 `MARKER OK` | 回复中含标记 |
| A2A 目录 | `ssh <worker> cat /root/ocws/oc_tasks/a2a/peers.json` | JSON，chmod 600 |
| A2A 端到端 | POST 一个让模型调用 ask_peer.sh 的任务 | 严格 JSON 回复 + 台账一行 |
| journal 演练 | P6 演练 1 | `journal.jsonl` 新增一行 |
| 自愈演练 | P6 演练 2 | kill 后约 5-10s 监听恢复 |
| Hub-0 TUI | `tmux attach -t hub0` | 每 worker 一个窗格渲染 TUI |
| web UI | 浏览器 `http://localhost:<FWD_BASE+i>` | Basic auth 后出现 web 应用 |

## 5. 回滚（逐项变更，全部可逆）

| 变更 | 回滚方法 |
|------|----------|
| 二进制安装 | `/root/.opencode/bin/opencode.bak.<ts>`（升级脚本失败时自动恢复） |
| /etc/hosts 钉名 | `/etc/hosts.bak.<ts>`；删除 `127.0.0.1 <LLM_HOST>` 行 |
| sshd 转发 | 删除 `/etc/ssh/sshd_config.d/60-oc-forward.conf`（或恢复 `sshd_config.bak.<ts>`）+ `systemctl reload sshd` |
| SELinux 标签 | `semanage fcontext -d '/root/\.opencode/bin(/.*)?'` + `restorecon -Rv` |
| 防火墙端口 | `firewall-cmd --remove-port=4096/tcp --permanent && firewall-cmd --reload` |
| ocserve 服务 | `systemctl disable --now ocserve && rm /etc/systemd/system/ocserve.service` |
| 工作区/配置 | 每个被替换文件旁都有 `.bak.<ts>` 副本；`MEMORY.md` 一旦播种不再覆盖 |
| 隧道/观察口 | `tmux kill-session -t tun_<NAME>` / `-t hub0` / `-t fw_<NAME>` |

## 6. 新增 worker

1. `env/cluster.env`：追加该 worker 的配置段（`W3_NAME/W3_IP/W3_USER`），并把 `W3` 加进 `WORKERS`。
2. `printf 'ssh-pass' > secrets/wk-3.sshpass`。
3. `bash scripts/bootstrap.sh` — 每个阶段都遍历 `$WORKERS`，已有 worker 自动 no-op。

## 7. 日常运维（Day-2）

- 与某 worker 对话：`curl -u opencode:$(cat secrets/wk-1.pw) http://<ip>:4096/...`
  （会话创建/消息格式见 [ARCHITECTURE.md](ARCHITECTURE.md)）。
- 实时观察 worker：`tmux attach -t hub0`（或 `wsl/hub0.sh` 重建）。
- 读 A2A 历史：`ssh <worker> cat /root/ocws/oc_tasks/journal/a2a.jsonl`。
- 收集证据：`ssh <worker> cat /root/ocws/oc_tasks/journal/journal.jsonl`。
