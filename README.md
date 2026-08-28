# opencode-cluster-server-tester

Multi-worker opencode cluster: one orchestrator drives N `opencode serve`
workers over HTTP, with agent-to-agent (A2A) messaging, file-based memory, and
observation hubs. Toolkit codename: `oc-cluster` (short names used throughout
the scripts and paths).

A small, file-driven multi-agent cluster built on [opencode](https://opencode.ai):
one orchestrator host (Windows + WSL) drives N Linux worker machines, each running
`opencode serve` as a systemd service. Workers talk to each other through a
machine-parsed A2A (agent-to-agent) protocol, persist task memory as JSONL
journals plus a distilled long-term memory index, and expose two observation
surfaces (remote TUI attach + browser web UI).

Designed for lab/hardware-test environments where the workers have no direct
internet egress: worker LLM traffic is tunneled out through the orchestrator
via an SSH reverse tunnel, so the only thing workers need is SSH reachability.

## Features

- **Env-driven topology** — all machines/ports/models live in one
  `env/cluster.env`; adding a worker is one block + one rerun.
- **Idempotent phase scripts** (`P0` probe → `P1` install → `P2` serve+workspace
  → `P3` tuning → `P4` e2e → `P5` hub → `P5.5` A2A → `P6` drills), each with
  gates and rollback-friendly backups on the target.
- **Offline-capable install** — the opencode tarball is pushed from the
  orchestrator; workers never need package repos.
- **A2A between workers** — compact JSON envelopes, strict-JSON replies,
  depth-limited delegation, JSONL ledger per hop.
- **Two-tier memory** — write-only `journal.jsonl` per task + 30-line distilled
  `MEMORY.md` auto-loaded every session.
- **Observability** — `opencode attach` TUI panes in tmux, per-worker web UI
  via SSH port forwards, per-hop A2A ledger.

## Quickstart (orchestrator: WSL)

```bash
# 0) prerequisites: WSL Debian/Ubuntu with tmux, sshpass, python3, curl
sudo apt-get install -y tmux sshpass curl python3

# 1) get the repo and configure your site
git clone <this-repo> oc-cluster && cd oc-cluster
cp env/cluster.env.example env/cluster.env   # edit: worker IPs/names, model, tarball path

# 2) provide secrets (gitignored, never committed)
secrets/<NAME>.sshpass   # SSH password per worker (one line)
secrets/auth.json        # opencode auth.json (from any machine where you ran `opencode auth login`)

# 3) deploy everything
bash scripts/bootstrap.sh --with-hub --with-drills
```

Verification matrix, rollback table, add-worker recipe: [docs/DEPLOY.md](docs/DEPLOY.md).
Design and protocol details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Known upstream issues and workarounds: [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md).

## Repo map

```
env/cluster.env.example   topology + tunables (copy to env/cluster.env, gitignored)
scripts/lib.sh            shared helpers: ssh_cmd/ssh_put/fetch/render, worker iteration
scripts/bootstrap.sh      run all phases in order
scripts/p0_probe.sh       read-only precheck (avx2, port gates)
scripts/p1_install.sh     push tarball, install binary, pin LLM host to loopback
scripts/p1_fix_sshd.sh    enable sshd AllowTcpForwarding (drop-in, syntax-gated)
scripts/p2_setup.sh       render+push workspace/config, ocserve.service, password gen
scripts/p3_tuning.sh      SELinux label + firewalld port (both optional, idempotent)
scripts/p4_e2e.sh         orchestrator->worker API roundtrip with per-worker marker
scripts/p55_a2a.sh        render+push per-worker peers.json (A2A directory)
scripts/p6_drill.sh       memory journal drill + tunnel self-heal drill
scripts/upgrade_opencode.sh  rolling binary upgrade with backup+restore
wsl/tunnel.sh             single reverse LLM tunnel loop (worker lo:443 -> LLM:443)
wsl/tunnels_up.sh         one detached tmux tunnel per worker
wsl/hub0.sh               Hub-0: attach TUI panes + web UI port forwards
worker/                   files pushed to workers (templates rendered at deploy)
docs/                     architecture, deploy runbook, known issues
```

## Secrets layout (all gitignored)

| File | Purpose |
|------|---------|
| `secrets/<NAME>.sshpass` | SSH password for `<USER>@<IP>` of that worker |
| `secrets/<NAME>.pw` | opencode serve API password (generated on worker, pulled back by P2) |
| `secrets/auth.json` | opencode auth copied into every worker's `~/.local/share/opencode/` |
| `env/cluster.env` | your real IPs/names (copy of the example) |
| `worker/notes.d/<NAME>.md` | optional per-worker machine facts injected into its AGENTS.md |

## Status

Deployed and verified on a 2-worker lab cluster (opencode 1.18.x, RHEL-family
workers with SELinux Enforcing). See docs for the evidence-backed known-issues
list before filing upstream bugs.

## License

MIT — see [LICENSE](LICENSE).
