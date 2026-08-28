#!/usr/bin/env bash
# P1: push opencode tarball, install binary, pin LLM host to loopback (for ssh -R tunnel).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

[ -f "$OC_TARBALL" ] || die "OC_TARBALL not found: $OC_TARBALL"

PAYLOAD="$(mktemp /tmp/oc_p1.XXXXXX)"
cat > "$PAYLOAD" <<'PAYLOAD'
#!/bin/bash
set -u
LLM="$1"
echo "=== [1] port 443 free? ==="
if ss -tln | grep -q ':443 '; then
  ss -tlnp | grep ':443 ' || true
  echo "FATAL: port 443 occupied, tunnel cannot bind"; exit 1
fi
echo "OK: 443 free"
echo "=== [2] install binary ==="
mkdir -p /root/.opencode/bin
tar xzf /root/oc_opencode.tar.gz -C /root/.opencode/bin
chmod +x /root/.opencode/bin/opencode
grep -q '.opencode/bin' /root/.bashrc || echo 'export PATH=/root/.opencode/bin:$PATH' >> /root/.bashrc
/root/.opencode/bin/opencode --version || { echo "FATAL: binary failed to run"; exit 1; }
echo "=== [3] hosts pin (reversible) ==="
if ! grep -q "$LLM" /etc/hosts; then
  cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)"
  echo "127.0.0.1 $LLM" >> /etc/hosts
  echo "pinned + backup created"
else
  echo "already pinned:"; grep "$LLM" /etc/hosts
fi
echo "=== P1 INSTALL DONE ==="
PAYLOAD

for k in $(keys); do
  n="$(name_of "$k")"
  log "P1 upload tarball -> $n"
  ssh_put "$k" "$OC_TARBALL" "/root/oc_opencode.tar.gz"
  ssh_put "$k" "$PAYLOAD" "/tmp/oc_p1.sh"
  ssh_cmd "$k" "bash /tmp/oc_p1.sh $OC_LLM_HOST"
done
rm -f "$PAYLOAD"
log "P1 PASS"
