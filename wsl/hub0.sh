#!/usr/bin/env bash
# Hub-0 observation: one tmux session (hub0) with a TUI attach window per
# worker, plus one ssh -L forward per worker so a browser on the orchestrator's
# desktop can open the worker web UI (Basic auth: OC_SERVE_USER + secrets/<NAME>.pw).
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"

command -v tmux >/dev/null || die "tmux not installed in WSL"
[ -x "$OC_ATTACH_BIN" ] || die "attach client not found: $OC_ATTACH_BIN (install opencode in WSL, see docs/DEPLOY.md)"

tmux kill-session -t hub0 2>/dev/null || true
i=0
first=1
for k in $(keys); do
  n="$(name_of "$k")"
  PW="$(cat "$(secret "$n" .pw)")"
  if [ "$first" = 1 ]; then
    tmux new-session -d -s hub0 -n "$n"
    first=0
  else
    tmux new-window -t hub0 -n "$n"
  fi
  tmux send-keys -t "hub0:$n" \
    "OPENCODE_SERVER_PASSWORD='$PW' $OC_ATTACH_BIN attach http://$(ip_of "$k"):$OC_PORT -u $OC_SERVE_USER" C-m
  port=$((OC_FWD_BASE + i)); i=$((i + 1))
  tmux kill-session -t "fw_$n" 2>/dev/null || true
  tmux new-session -d -s "fw_$n" \
    "SSHPASS='$(cat "$(secret "$n" .sshpass)")' sshpass -e ssh -N -o ServerAliveInterval=15 -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -L 127.0.0.1:$port:127.0.0.1:$OC_PORT $(user_of "$k")@$(ip_of "$k")"
  log "$n: attach window 'hub0:$n' | web UI http://localhost:$port"
done
sleep 3
tmux ls
