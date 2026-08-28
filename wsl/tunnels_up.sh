#!/usr/bin/env bash
# Start one detached tmux reverse-tunnel session per worker (idempotent).
# Sessions are named tun_<NAME>; logs in ~/oc_tunnels/.
set -euo pipefail
. "$(dirname "$0")/../scripts/lib.sh"

command -v tmux >/dev/null || die "tmux not installed in WSL"
for k in $(keys); do
  n="$(name_of "$k")"
  tmux kill-session -t "tun_$n" 2>/dev/null || true
  tmux new-session -d -s "tun_$n" \
    "bash $OC_ROOT/wsl/tunnel.sh $(user_of "$k")@$(ip_of "$k") $(secret "$n" .sshpass) $OC_LLM_HOST $n"
  log "tunnel tmux session: tun_$n"
done
sleep 2
tmux ls
