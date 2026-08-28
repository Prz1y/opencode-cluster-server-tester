#!/usr/bin/env bash
# P2: render + push worker config/workspace templates, install, generate serve
# password, write ocserve.service, enable, local health check. Idempotent
# (existing files are backed up with a timestamp before overwrite).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

STAGE="$(mktemp -d /tmp/oc_p2_stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

PAYLOAD="$(mktemp /tmp/oc_p2.XXXXXX)"
cat > "$PAYLOAD" <<'PAYLOAD'
#!/bin/bash
set -u
PORT="$1"
TS=$(date +%Y%m%d_%H%M%S)
echo "== [1] dirs =="
mkdir -p /root/ocws/oc_tasks/tasks /root/ocws/oc_tasks/journal /root/ocws/oc_tasks/exports \
         /root/ocws/oc_tasks/a2a /root/ocws/ltm/store /root/ocws/bin /root/trash /root/.config/opencode
echo "== [2] config =="
if [ -f /root/.config/opencode/opencode.json ]; then
  cp /root/.config/opencode/opencode.json /root/.config/opencode/opencode.json.bak.$TS
fi
cp /root/oc_stage_opencode.json /root/.config/opencode/opencode.json
echo "== [3] workspace files =="
if [ -f /root/ocws/AGENTS.md ]; then cp /root/ocws/AGENTS.md /root/ocws/AGENTS.md.bak.$TS; fi
cp /root/oc_stage_AGENTS.md /root/ocws/AGENTS.md
if [ ! -f /root/ocws/MEMORY.md ]; then
  cp /root/oc_stage_MEMORY.md /root/ocws/MEMORY.md
  echo "MEMORY.md seeded"
else
  echo "MEMORY.md exists, kept"
fi
touch /root/ocws/oc_tasks/journal/journal.jsonl
if [ -f /root/oc_stage_auth.json ]; then
  mkdir -p /root/.local/share/opencode
  cp /root/oc_stage_auth.json /root/.local/share/opencode/auth.json
  echo "auth.json installed"
else
  echo "WARN: no auth.json staged - model calls fail until auth is provided"
fi
echo "== [4] ask_peer scripts =="
cp /root/oc_stage_ask_peer.sh /root/ocws/bin/ask_peer.sh
cp /root/oc_stage_ask_peer.py /root/ocws/bin/ask_peer.py
chmod 750 /root/ocws/bin/ask_peer.sh /root/ocws/bin/ask_peer.py
echo "== [5] password =="
if [ ! -f /root/.oc_serve_pw ]; then
  openssl rand -hex 16 > /root/.oc_serve_pw 2>/dev/null || head -c 24 /dev/urandom | base64 | tr -d '\n' > /root/.oc_serve_pw
  chmod 600 /root/.oc_serve_pw
  echo "password generated"
else
  echo "password exists (kept)"
fi
PW=$(cat /root/.oc_serve_pw)
echo "== [6] service =="
sed "s/__PW__/$PW/; s/__PORT__/$PORT/" /root/oc_stage_ocserve.service > /etc/systemd/system/ocserve.service
chmod 600 /etc/systemd/system/ocserve.service
systemctl daemon-reload
systemctl enable --now ocserve.service 2>&1 | tail -1 || true
sleep 3
systemctl is-active ocserve.service || true
echo "== [7] local health =="
echo -n "auth /session (expect 200): "
curl -s -o /dev/null -w '%{http_code}' -u "opencode:$PW" "http://127.0.0.1:$PORT/session"; echo
echo -n "noauth /session (expect 401): "
curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/session"; echo
echo "== P2 DONE =="
PAYLOAD

for k in $(keys); do
  n="$(name_of "$k")"
  NOTES_BODY=""
  if [ -f "$OC_ROOT/worker/notes.d/$n.md" ]; then
    NOTES_BODY="$(cat "$OC_ROOT/worker/notes.d/$n.md")"$'\n'
  fi
  render "$OC_ROOT/worker/opencode.template.json" "$STAGE/opencode.json" \
    "__MODEL__=$OC_MODEL" "__SMALL_MODEL__=$OC_SMALL_MODEL"
  render "$OC_ROOT/worker/AGENTS.template.md" "$STAGE/AGENTS.md" \
    "__WORKER__=$n" "__IP__=$(ip_of "$k")" "__HOSTNAME__=$n" \
    "__OC_VERSION__=$OC_VERSION" "__LLM_HOST__=$OC_LLM_HOST" "__MACHINE_NOTES__=$NOTES_BODY"
  render "$OC_ROOT/worker/MEMORY.seed.md" "$STAGE/MEMORY.md" \
    "__WORKER__=$n" "__LLM_HOST__=$OC_LLM_HOST" "__PORT__=$OC_PORT"
  render "$OC_ROOT/worker/ocserve.template.service" "$STAGE/ocserve.service" \
    "__PORT__=$OC_PORT" "__PW__=PLACEHOLDER"

  log "P2 stage -> $n"
  ssh_put "$k" "$STAGE/opencode.json"   "/root/oc_stage_opencode.json"
  ssh_put "$k" "$STAGE/AGENTS.md"       "/root/oc_stage_AGENTS.md"
  ssh_put "$k" "$STAGE/MEMORY.md"       "/root/oc_stage_MEMORY.md"
  ssh_put "$k" "$STAGE/ocserve.service" "/root/oc_stage_ocserve.service"
  ssh_put "$k" "$OC_ROOT/worker/bin/ask_peer.sh" "/root/oc_stage_ask_peer.sh"
  ssh_put "$k" "$OC_ROOT/worker/bin/ask_peer.py" "/root/oc_stage_ask_peer.py"
  if [ -f "$SECRETS/auth.json" ]; then
    ssh_put "$k" "$SECRETS/auth.json" "/root/oc_stage_auth.json"
  fi
  ssh_put "$k" "$PAYLOAD" "/tmp/oc_p2.sh"
  ssh_cmd "$k" "bash /tmp/oc_p2.sh $OC_PORT"
  log "P2 pull serve password -> secrets/$n.pw"
  fetch "$k" "/root/.oc_serve_pw" "$SECRETS/$n.pw"
done
log "P2 PASS"
