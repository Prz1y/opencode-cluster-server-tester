#!/bin/bash
# oc worker reverse LLM tunnel: worker 127.0.0.1:443 -> this host -> $LLM:443.
# Auto-reconnects every 5s; log in ~/oc_tunnels/.
# usage: tunnel.sh <user@worker-ip> <sshpass-file> <llm-host> [tag]
set -u
DEST="$1"; PWFILE="$2"; LLM="$3"; TAG="${4:-$DEST}"
mkdir -p "$HOME/oc_tunnels"
LOG="$HOME/oc_tunnels/tunnel_${TAG}.log"
export SSHPASS="$(cat "$PWFILE")"
while true; do
  sshpass -e ssh -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -R "127.0.0.1:443:$LLM:443" -N "$DEST"
  echo "$(date '+%F %T') rc=$? reconnect in 5s" >> "$LOG"
  sleep 5
done
