# 已知问题与规避手段

[English](KNOWN_ISSUES.en.md) | 中文

在 opencode 1.18.23/1.18.24 + RHEL 系 worker 上发现的、有证据支撑的问题。
套用前先核对版本是否仍然适用。

## 1. 项目内含自定义工具（`.opencode/tools/*.ts`）时 `opencode serve` 挂死

- 症状：工作区 `.opencode/tools/` 里只要有任意 `.ts` 文件，服务端会话就挂死：
  `POST /session/{id}/message` 返回 0-token 的 stub assistant 消息；服务端日志
  停在 `stream ... agent=title`（标题那次 LLM 调用永远不完成），且不记任何错误。
  同一项目目录下 `opencode run`（CLI）正常。
- 二分定位：空 tools 目录 = 正常；无 import 的最小工具 = 挂死。
- 影响版本：1.18.23 与 1.18.24（升级未修复）。
- 规避（本仓库的做法）：A2A 是调用 python3（仅标准库）的纯 bash 脚本，经模型
  内置 bash 工具执行——不涉及自定义工具加载。自定义 `.ts` 工具一律不部署到
  worker。
- 行动项：值得带上二分复现步骤给上游提 issue。

## 2. 实验室网络屏蔽 LLM API 域名；GitHub release 资产不可达

- 症状：worker 能解析 `api.<provider>` 但 TCP 被 RST/超时（出口白名单）。
  `release-assets.githubusercontent.com` 同样被屏蔽，所以即便 `github.com`
  可达，worker 也无法自升级。
- 规避：经编排器反向隧道出网（`ssh -R 127.0.0.1:443:<LLM_HOST>:443` +
  hosts 钉名，见 ARCHITECTURE.md），release tarball 由编排器推送
  （`scripts/upgrade_opencode.sh`）。

## 3. `POST /session/{id}/message` 请求体格式

- 现行：`{"parts":[{"type":"text","text":"..."}]}`。旧的 `{"data": "..."}`
  格式返回 400。升级后若消息发送失败，先查 `GET /doc` 的 OpenAPI。

## 4. assistant 文本提取的嵌套层级

- `POST /session/{id}/message` 返回单个 message 对象：role 在 `info.role`，
  内容却在顶层 `parts[]`
  （`{"info":{"role":"assistant"},"parts":[{"type":"text",...}]}`）。
  `GET .../message` 返回这类对象的列表。提取器必须同时处理两种嵌套
  （`ask_peer.py:extract_assistant_text` 已处理）。

## 5. SELinux Enforcing 主机上的 systemd 203/EXEC

- `ocserve.service` 无法 exec `/root/.opencode/bin/opencode`，因为 home 目录
  路径被打上 `admin_home_t`。修复（P3）：
  `semanage fcontext -a -t bin_t '/root/\.opencode/bin(/.*)?'` +
  `restorecon -Rv`。标签重启后仍在。

## 6. 加固版 sshd 拒绝 TCP 转发

- `AllowTcpForwarding no` 会让反向隧道静默失效（装 drop-in + reload 后才能
  绑定成功）。P1b 在 `sshd -t` 语法门禁后安装 drop-in。改 sshd 配置后，
  旧 sshd 还占着 :443 时，第一次重连可能记 "remote port forwarding failed"
  ——重试循环会解决。

## 7. 认证方式

- serve API 只接受 HTTP Basic
  （`Authorization: Basic base64(user:pw)`）。即使密码正确，Bearer token
  也返回 401。

## 8. 编排器侧网络怪癖（WSL2）

- 部分环境下 Windows 本体到实验室网段打不开 TCP，而 WSL2 可以（NAT vs
  主机侧过滤）。所有编排流量保持在 WSL 内（`scripts/*` 已经如此）。发布在
  WSL loopback 上的端口转发可经 WSL2 `localhostForwarding` 被 Windows
  浏览器访问。
- 经 PowerShell -> wsl -> ssh 多层嵌套驱动 worker 时当心 shell 引号坑：
  优先用本仓库的脚本文件模式（`ssh_put` + `ssh_cmd`），别写内联一行流。

## 9. WSL 重启会杀死全部 tmux 会话（隧道、观察口、转发）

- WSL VM 可能在使用间隔中被回收，tmux server 随之消亡：`tun_<NAME>`（LLM
  出口）、`hub0`（attach TUI）、`fw_<NAME>`（web 转发）全部消失。症状：worker
  模型调用报 "Cannot connect to API"，但直连 SSH 正常；worker 上没有
  `127.0.0.1:443` 监听。
- 恢复（幂等）：`bash wsl/tunnels_up.sh && bash wsl/hub0.sh`

## 10. p2 幂等重跑必须强制重启 ocserve

- `systemctl enable --now` 不会重启已运行的服务——P2 重跑即使更新了
  `opencode.json` 或 `auth.json`，旧进程仍按旧配置/旧凭据服务。因此 P2
  payload 无条件执行 `systemctl enable` + `systemctl restart`。
