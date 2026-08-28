# Deploy runbook

English | [中文](DEPLOY.md)

Everything runs on the orchestrator host in WSL. Worker assumptions: Linux with
systemd, SSH root login (or adjust `W*_USER`), python3 present, ports 443 (loopback
tunnel bind) and 4096 (serve API) free.

## 0. Prerequisites

Orchestrator WSL:

```bash
sudo apt-get install -y tmux sshpass curl python3
# attach client for Hub-0 (any machine with opencode works):
curl -fsSL https://opencode.ai/install | bash
```

Worker LLM auth: on any machine with a browser run `opencode auth login` for your
provider, then copy the resulting `~/.local/share/opencode/auth.json` to
`secrets/auth.json` in the repo.

## 1. Configure

```bash
cp env/cluster.env.example env/cluster.env
$EDITOR env/cluster.env   # worker names/IPs/user, model, LLM host, tarball path
```

Download the opencode linux x64 tarball once (orchestrator side, proxy-friendly):

```bash
curl -fL -o ~/opencode-linux-x64.tar.gz \
  https://github.com/sst/opencode/releases/latest/download/opencode-linux-x64.tar.gz
```

Optional per-worker machine facts (injected into that worker's AGENTS.md):

```markdown
<!-- worker/notes.d/wk-1.md (gitignored) -->
- History: AC power-cycle DUT; no persistent jobs.
- 16-port NIC; BMC on the management segment.
```

## 2. Secrets (gitignored, never commit)

```bash
mkdir -p secrets
printf 'your-ssh-password' > secrets/wk-1.sshpass
printf 'your-ssh-password' > secrets/wk-2.sshpass
cp /path/to/auth.json secrets/auth.json
chmod 600 secrets/*
```

`secrets/<NAME>.pw` (serve API passwords) are generated ON each worker by P2 and
pulled back automatically — do not create them by hand.

### Standard-billing provider keys (e.g. z.ai API key)

If `OC_MODEL` uses a key-billed provider (`zai/glm-4.5-air` etc.), install the
key into every worker's auth (merged in-place; existing OAuth entries are kept
for rollback), then re-render config and restart:

```bash
bash scripts/auth_provider_key.sh zai secrets/zai_api_key
bash scripts/p2_setup.sh   # re-renders opencode.json from OC_MODEL and restarts ocserve
bash scripts/p4_e2e.sh     # verify roundtrip
```

## 3. Deploy

```bash
bash scripts/bootstrap.sh                 # P0 P1 P1b T P2 P3 P5.5 P4
bash scripts/bootstrap.sh --with-hub      # + Hub-0 attach panes and web forwards
bash scripts/bootstrap.sh --with-drills   # + P6 memory/tunnel drills
```

Phases are idempotent; re-running any single phase works:

```bash
bash scripts/p4_e2e.sh          # re-validate API roundtrip
bash scripts/upgrade_opencode.sh https://github.com/sst/opencode/releases/latest/download/opencode-linux-x64.tar.gz
```

## 4. Verification matrix

| Check | Command (WSL) | Expect |
|-------|---------------|--------|
| tunnels up | `tmux ls` | `tun_<NAME>` per worker |
| worker tunnel listener | `ssh <worker> ss -tlnp \| grep :443` | sshd LISTEN on 127.0.0.1:443 |
| worker LLM egress | inside worker: `curl -sI https://<LLM_HOST>` | HTTP 200/301 |
| serve auth | P4 output `GET /session -> 200` | 200 |
| model roundtrip | P4 output `MARKER OK` per worker | marker in reply |
| A2A dir | `ssh <worker> cat /root/ocws/oc_tasks/a2a/peers.json` | JSON, chmod 600 |
| A2A e2e | POST a task telling the model to call ask_peer.sh | strict-JSON reply + ledger line |
| journal drill | P6 drill 1 | new line in `journal.jsonl` |
| self-heal drill | P6 drill 2 | listener restored ~5-10s after kill |
| Hub-0 TUI | `tmux attach -t hub0` | one pane per worker rendering the TUI |
| web UI | browser `http://localhost:<FWD_BASE+i>` | web app after Basic auth |

## 5. Rollback (per change, all reversible)

| Change | Rollback |
|--------|----------|
| binary install | `/root/.opencode/bin/opencode.bak.<ts>` (upgrade script restores automatically on failure) |
| /etc/hosts pin | `/etc/hosts.bak.<ts>`; remove the `127.0.0.1 <LLM_HOST>` line |
| sshd forwarding | remove `/etc/ssh/sshd_config.d/60-oc-forward.conf` (or restore `sshd_config.bak.<ts>`) + `systemctl reload sshd` |
| SELinux label | `semanage fcontext -d '/root/\.opencode/bin(/.*)?'` + `restorecon -Rv` |
| firewall port | `firewall-cmd --remove-port=4096/tcp --permanent && firewall-cmd --reload` |
| ocserve service | `systemctl disable --now ocserve && rm /etc/systemd/system/ocserve.service` |
| workspace/config | `.bak.<ts>` copies sit next to every replaced file; `MEMORY.md` is never overwritten once seeded |
| tunnels/hub | `tmux kill-session -t tun_<NAME>` / `-t hub0` / `-t fw_<NAME>` |

## 6. Add a worker

1. `env/cluster.env`: append the per-key block (`W3_NAME/W3_IP/W3_USER`), add `W3` to `WORKERS`.
2. `printf 'ssh-pass' > secrets/wk-3.sshpass`.
3. `bash scripts/bootstrap.sh` — every phase loops over `$WORKERS`, existing workers no-op.

## 7. Day-2 operations

- Talk to a worker: `curl -u opencode:$(cat secrets/wk-1.pw) http://<ip>:4096/...`
  (session create/message shapes in ARCHITECTURE.en.md).
- Watch a worker live: `tmux attach -t hub0` (or `wsl/hub0.sh` to rebuild).
- Read A2A history: `ssh <worker> cat /root/ocws/oc_tasks/journal/a2a.jsonl`.
- Collect evidence: `ssh <worker> cat /root/ocws/oc_tasks/journal/journal.jsonl`.

## 8. Orchestrator-native tool (MCP)

Install the dispatcher as a native tool in the orchestrator's own opencode so a
task dispatch becomes one tool call instead of hand-written curl:

1. The repo ships `orchestrator/mcp_remote_task.py` — a dependency-free MCP
   stdio server (python3 stdlib, runs inside WSL) wrapping
   `scripts/dispatch_task.sh`.
2. Register it in the orchestrator's opencode config (global, or project
   `.opencode/opencode.json`):

```json
{
  "mcp": {
    "oc": {
      "type": "local",
      "command": ["wsl.exe", "-d", "Debian", "--", "python3", "-u",
                  "/mnt/<drive>/<path>/oc-cluster/orchestrator/mcp_remote_task.py"],
      "enabled": true,
      "timeout": 10000
    }
  }
}
```

3. Restart opencode. The tool registers as `oc_remote_task(worker, task, prompt,
   wait_seconds)`; `worker="list"` enumerates workers. Long tasks block the call
   up to `wait_seconds` (default 300, cap 1800).

Why MCP instead of a `.ts` custom tool: see docs/KNOWN_ISSUES.md #1 — project
`.opencode/tools/*.ts` files hang `opencode serve` sessions (1.18.23/24). The
MCP server runs out-of-process and is unaffected.

Smoke test (no opencode needed):

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | python3 -u orchestrator/mcp_remote_task.py
```
