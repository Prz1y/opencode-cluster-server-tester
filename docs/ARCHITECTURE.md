# Architecture

## Topology

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

## LLM egress for air-gapped workers

Workers often sit in whitelisted lab networks with no direct route to the LLM
API. oc-cluster solves this without touching the egress policy:

1. P1 appends `127.0.0.1 <LLM_HOST>` to the worker's `/etc/hosts` (backed up).
2. The orchestrator runs a persistent `ssh -R 127.0.0.1:443:<LLM_HOST>:443 -N`
   per worker (tmux, auto-reconnect loop, log in `~/oc_tunnels/`).
3. Worker HTTPS to `<LLM_HOST>` now flows: worker loopback -> sshd -> orchestrator
   -> real API. TLS is end-to-end (SNI/cert pass through untouched).
4. Requires `AllowTcpForwarding yes` on workers — P1b installs a drop-in
   (`/etc/ssh/sshd_config.d/60-oc-forward.conf`) behind an `sshd -t` gate.

If the tunnel dies, model calls fail; the reconnect loop restores it in ~5s.
Workers are told (AGENTS.md) to report tunnel failures, not "fix" the network.

## Worker components

| Component | Path | Notes |
|-----------|------|-------|
| opencode binary | `/root/.opencode/bin/opencode` | pushed tarball, no autoupdate |
| serve API | systemd `ocserve.service`, port 4096 | `Restart=always`, password in unit (chmod 600) |
| auth | `/root/.local/share/opencode/auth.json` | copied from orchestrator secret |
| config | `/root/.config/opencode/opencode.json` | model + instructions AGENTS.md/MEMORY.md |
| workspace | `/root/ocws` | sessions start here (WorkingDirectory) |
| A2A scripts | `/root/ocws/bin/ask_peer.{sh,py}` | python3 stdlib only |
| A2A directory | `/root/ocws/oc_tasks/a2a/peers.json` | all peers + passwords, chmod 600 |
| journals | `/root/ocws/oc_tasks/journal/*.jsonl` | write-only evidence trail |
| LTM | `/root/ocws/MEMORY.md` + `ltm/store/` | 30-line distilled index, auto-loaded |

## Memory model (two tiers, fully automatic)

- **Short-term / episodic**: after every task the model appends one JSONL line to
  `oc_tasks/journal/journal.jsonl`
  (`{"ts","task","topic","conclusion","evidence"}`). Write-only, never auto-loaded
  into context — zero token cost until queried.
- **Long-term / distilled**: `MEMORY.md` is capped at 30 lines (~500 tokens) and
  mounted via opencode `instructions`, so every session pays a fixed small cost.
  When the journal exceeds 50 lines the model compacts: merge new facts into
  MEMORY.md (backup first), keep superseded items as one strikethrough line,
  truncate the journal. Detail shards live in `ltm/store/<topic>.md`.
- **Collective**: A2A replies carry `evidence` paths, so one worker can pull
  another's on-disk evidence without duplicating content.

## A2A protocol

Call (the model invokes it via its built-in bash tool — no custom-tool loading
involved, see KNOWN_ISSUES):

```bash
bash /root/ocws/bin/ask_peer.sh --peer <peer-name> --task <TASK-ID> \
  --intent <query|request|report> --subject "<one line>" --depth <n> \
  --body "<full message>"
```

What travels over HTTP POST `/session/<peer-session>/message`:

```
[A2A] {"v":1,"from":"wk-1","task":"TASK-1","depth":1,"intent":"query",
       "subject":"...","body":"..."}
You are answering a peer agent, not a human. Reply with STRICT JSON only...
```

Reply contract (parsed by regex for `"status"`):

```json
{"status":"answered|partial|refused","body":"...","evidence":["path or cmd output"]}
```

Rules:

- Peer sessions are persistent per peer (map in `oc_tasks/a2a/sessions.json`) —
  context accumulates, but bodies stay self-contained.
- `depth >= 2` is refused (last-hop rule prevents delegation loops).
- Every hop appends one JSONL entry to `oc_tasks/journal/a2a.jsonl`
  (`{"ts","dir","from","to","task","intent","subject","depth","status","ms",...}`).
- `peers.json` holds peer credentials; AGENTS.md forbids the model from printing
  or copying its contents.

## Orchestrator -> worker API (opencode serve)

- Auth: HTTP Basic, user `opencode` (configurable), password from
  `secrets/<NAME>.pw`. Bearer tokens do NOT work.
- Create session: `POST /session` `{}` -> `{"id": ...}`
- Blocking prompt: `POST /session/{id}/message`
  `{"parts":[{"type":"text","text":"..."}]}` (note: `{"data": ...}` is the old
  shape and returns 400)
- Async: `POST /session/{id}/prompt_async`; SSE: `GET /event`
- OpenAPI: `GET /doc`

## Extensibility

- **Add a worker**: append `W3_NAME/W3_IP/W3_USER` to `env/cluster.env`, add
  `W3` to `WORKERS`, drop `secrets/wk-3.sshpass`, rerun `bootstrap.sh`. All
  phases loop over `$WORKERS` and are idempotent.
- **Add a site-specific machine fact**: `worker/notes.d/<NAME>.md` — injected
  into that worker's AGENTS.md at render time.
- **Change model/provider**: `OC_MODEL` / `OC_LLM_HOST` in env; re-run P2
  (config render) — tunnels re-target automatically via `tunnels_up.sh`.
- **Planned (P7)**: `oc_hub.py` dashboard subscribing SSE `GET /event` from all
  workers into a merged JSONL with worker/TASK-ID/depth filters.
