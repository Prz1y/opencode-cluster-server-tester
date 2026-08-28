#!/usr/bin/env bash
# P1b: enable sshd TCP forwarding on workers (required by the reverse LLM tunnel).
# Reversible: remove the drop-in (or restore the .bak) + systemctl reload sshd.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PAYLOAD="$(mktemp /tmp/oc_p1sshd.XXXXXX)"
cat > "$PAYLOAD" <<'PAYLOAD'
#!/bin/bash
set -u
TS=$(date +%Y%m%d_%H%M%S)
echo "== current =="
sshd -T 2>/dev/null | grep -i allowtcpforwarding || true
if grep -qi '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null; then
  mkdir -p /etc/ssh/sshd_config.d
  printf 'AllowTcpForwarding yes\n' > /etc/ssh/sshd_config.d/60-oc-forward.conf
  echo "drop-in written: 60-oc-forward.conf"
else
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$TS"
  printf '\n# oc-cluster-add %s\nAllowTcpForwarding yes\n' "$TS" >> /etc/ssh/sshd_config
  echo "appended to main config (no Include support)"
fi
echo "== syntax gate =="
if ! sshd -t 2>&1; then
  echo "FATAL: sshd -t failed, rolling back"
  if [ -f /etc/ssh/sshd_config.d/60-oc-forward.conf ]; then
    mv -f /etc/ssh/sshd_config.d/60-oc-forward.conf "/etc/ssh/sshd_config.d/60-oc-forward.conf.bak.$TS"
  else
    cp -f "/etc/ssh/sshd_config.bak.$TS" /etc/ssh/sshd_config
  fi
  exit 1
fi
systemctl reload sshd && echo RELOADED
sleep 1
sshd -T 2>/dev/null | grep -i allowtcpforwarding
echo "== DONE =="
PAYLOAD

for k in $(keys); do
  log "P1 sshd forwarding -> $(name_of "$k")"
  ssh_put "$k" "$PAYLOAD" "/tmp/oc_p1_sshd.sh"
  ssh_cmd "$k" "bash /tmp/oc_p1_sshd.sh"
done
rm -f "$PAYLOAD"
log "P1 sshd PASS"
