#!/usr/bin/env bash
# Rolling opencode binary upgrade across all workers:
# download on the orchestrator (URL) or reuse a local tarball -> md5 -> backup
# remote binary -> swap -> restart ocserve -> local health check.
# usage: upgrade_opencode.sh <tarball-path | URL>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

SRC="${1:-}"
[ -n "$SRC" ] || die "usage: upgrade_opencode.sh <tarball-path | URL>"

LOCAL="$SRC"
DOWNLOADED=0
case "$SRC" in
  http*) LOCAL="$(mktemp /tmp/oc_upgrade.XXXXXX.tar.gz)"
         log "downloading $SRC"
         curl -fL --retry 3 -o "$LOCAL" "$SRC"
         DOWNLOADED=1 ;;
esac
[ -f "$LOCAL" ] || die "tarball missing: $LOCAL"
log "md5: $(md5sum "$LOCAL" | awk '{print $1}')"

PAYLOAD="$(mktemp /tmp/oc_up.XXXXXX)"
cat > "$PAYLOAD" <<'PAYLOAD'
#!/bin/bash
set -u
TS=$(date +%Y%m%d_%H%M%S)
cp /root/.opencode/bin/opencode "/root/.opencode/bin/opencode.bak.$TS"
tar xzf /root/oc_opencode_new.tar.gz -C /root/.opencode/bin
chmod +x /root/.opencode/bin/opencode
if ! V=$(/root/.opencode/bin/opencode --version); then
  echo "FATAL: new binary broken; restoring backup"
  cp "/root/.opencode/bin/opencode.bak.$TS" /root/.opencode/bin/opencode
  exit 1
fi
echo "installed: $V"
systemctl restart ocserve.service
sleep 3
systemctl is-active ocserve.service
PW=$(cat /root/.oc_serve_pw)
curl -s -o /dev/null -w 'auth /session -> %{http_code}\n' -u "opencode:$PW" http://127.0.0.1:4096/session
echo "backup: /root/.opencode/bin/opencode.bak.$TS"
echo "== UPGRADE DONE =="
PAYLOAD

for k in $(keys); do
  log "upgrade -> $(name_of "$k")"
  ssh_put "$k" "$LOCAL" "/root/oc_opencode_new.tar.gz"
  ssh_put "$k" "$PAYLOAD" "/tmp/oc_upgrade.sh"
  ssh_cmd "$k" "bash /tmp/oc_upgrade.sh"
done
rm -f "$PAYLOAD"
[ "$DOWNLOADED" = 1 ] && rm -f "$LOCAL"
log "upgrade PASS"
