# Known issues and workarounds

English | [中文](KNOWN_ISSUES.md)

Evidence-backed issues found on opencode 1.18.23/1.18.24 with RHEL-family
workers. Verify versions before assuming these still apply.

## 1. `opencode serve` hangs when the project contains custom tools (`.opencode/tools/*.ts`)

- Symptom: ANY `.ts` file in the workspace's `.opencode/tools/` makes server-side
  sessions hang: `POST /session/{id}/message` returns a 0-token stub assistant
  message; the server log stops at `stream ... agent=title` (the title LLM call
  never completes) and no error is logged. `opencode run` (CLI) from the same
  project directory works fine.
- Bisected: empty tools dir = works; minimal tool with no imports = hangs.
- Affected: 1.18.23 and 1.18.24 (upgrade did not fix).
- Workaround (what this repo does): A2A is a plain bash script calling python3
  (stdlib only), invoked through the model's built-in bash tool — no custom-tool
  loading involved. Custom `.ts` tools are simply not deployed to workers.
- Action: worth an upstream issue report with the bisect recipe.

## 2. LLM API hosts blocked from lab networks; GitHub release assets unreachable

- Symptom: workers resolve `api.<provider>` but TCP is RST/timeout (egress
  whitelist). `release-assets.githubusercontent.com` also blocked, so workers
  cannot self-upgrade even when `github.com` works.
- Workaround: reverse-tunnel egress through the orchestrator (`ssh -R
  127.0.0.1:443:<LLM_HOST>:443` + hosts pin, see ARCHITECTURE.en.md) and push
  release tarballs from the orchestrator (`scripts/upgrade_opencode.sh`).

## 3. `POST /session/{id}/message` body shape

- Current: `{"parts":[{"type":"text","text":"..."}]}`. The older
  `{"data": "..."}` shape returns 400. If message posts fail after an upgrade,
  check the OpenAPI at `GET /doc` first.

## 4. Assistant-text extraction nesting

- `POST /session/{id}/message` returns ONE message object where the role lives
  at `info.role` but the content lives at the top level `parts[]`
  (`{"info":{"role":"assistant"},"parts":[{"type":"text",...}]}`). `GET
  .../message` returns a LIST of such objects. Extractors must handle both
  nesting levels (`ask_peer.py:extract_assistant_text` does).

## 5. systemd 203/EXEC on SELinux-enforcing hosts

- `ocserve.service` fails to exec `/root/.opencode/bin/opencode` because the
  home-dir path gets `admin_home_t`. Fix (P3): `semanage fcontext -a -t bin_t
  '/root/\.opencode/bin(/.*)?'` + `restorecon -Rv`. Label survives reboot.

## 6. Hardened sshd refuses TCP forwarding

- `AllowTcpForwarding no` breaks the reverse tunnel silently (bind succeeds only
  after the drop-in + reload). P1b installs the drop-in behind an `sshd -t`
  syntax gate. After changing sshd config, one reconnect attempt may log
  "remote port forwarding failed" while the old sshd still holds :443 — the
  retry loop resolves it.

## 7. Auth scheme

- The serve API accepts HTTP Basic only (`Authorization: Basic base64(user:pw)`).
  Bearer tokens return 401 even with the correct password.

## 8. Orchestrator-side networking quirks (WSL2)

- On some setups the Windows host itself cannot open TCP to the lab segment
  while WSL2 can (NAT vs host filtering). Keep ALL orchestration traffic in WSL
  (`scripts/*` already do). Port forwards published on WSL loopback reach the
  Windows browser via WSL2 `localhostForwarding`.
- Watch out for shell-quoting pitfalls when driving workers through nested
  PowerShell -> wsl -> ssh layers: prefer the repo's script-file pattern
  (`ssh_put` + `ssh_cmd`) over inline one-liners.
