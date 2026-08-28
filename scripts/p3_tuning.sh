#!/usr/bin/env bash
# P3: distro tuning on hardened systems, both idempotent and both no-op
# gracefully when the subsystem is absent:
#   - SELinux: label /root/.opencode/bin as bin_t (fixes systemd 203/EXEC)
#   - firewalld: open the serve port
set -euo pipefail
. "$(dirname "$0")/lib.sh"

SEL="$(mktemp /tmp/oc_p3sel.XXXXXX)"
FW="$(mktemp /tmp/oc_p3fw.XXXXXX)"
cat > "$SEL" <<'PAYLOAD'
#!/bin/bash
set -u
if ! command -v getenforce >/dev/null 2>&1; then echo "no SELinux, skip"; exit 0; fi
if [ "$(getenforce)" != "Enforcing" ]; then echo "SELinux not Enforcing, skip"; exit 0; fi
echo "== label opencode bin as bin_t (fixes systemd 203/EXEC) =="
semanage fcontext -a -t bin_t '/root/\.opencode/bin(/.*)?' 2>/dev/null \
  || semanage fcontext -m -t bin_t '/root/\.opencode/bin(/.*)?'
restorecon -Rv /root/.opencode/bin
ls -Z /root/.opencode/bin/opencode
systemctl restart ocserve.service || true
sleep 4
systemctl is-active ocserve.service || true
ss -tlnp | grep ':4096' || echo "WARN: no 4096 listener yet"
echo "== SELINUX FIX DONE =="
PAYLOAD
cat > "$FW" <<'PAYLOAD'
#!/bin/bash
set -u
PORT="$1"
if ! systemctl is-active firewalld >/dev/null 2>&1; then echo "firewalld inactive, skip"; exit 0; fi
echo "== current =="
firewall-cmd --list-ports || true
echo "== open $PORT/tcp =="
firewall-cmd --add-port=$PORT/tcp --permanent
firewall-cmd --reload
firewall-cmd --list-ports
echo "== FW DONE =="
PAYLOAD

for k in $(keys); do
  log "P3 SELinux -> $(name_of "$k")"
  ssh_put "$k" "$SEL" "/tmp/oc_p3_sel.sh"
  ssh_cmd "$k" "bash /tmp/oc_p3_sel.sh"
  log "P3 firewall -> $(name_of "$k")"
  ssh_put "$k" "$FW" "/tmp/oc_p3_fw.sh"
  ssh_cmd "$k" "bash /tmp/oc_p3_fw.sh $OC_PORT"
done
rm -f "$SEL" "$FW"
log "P3 PASS"
