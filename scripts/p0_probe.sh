#!/usr/bin/env bash
# P0: read-only precheck on every worker. Makes no changes. Gates: avx2, port 4096 free.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PAYLOAD="$(mktemp /tmp/oc_p0.XXXXXX)"
cat > "$PAYLOAD" <<'PAYLOAD'
#!/bin/bash
LLM="${1:-api.z.ai}"
echo "=== identity ==="
hostname
grep PRETTY_NAME /etc/os-release || true
uname -m; uname -r
echo "=== uptime/load ==="; uptime
echo "=== mem ==="; free -h | head -2
echo "=== disk / ==="; df -h / | tail -1
echo "=== leftover test processes ==="
pgrep -af 'pangu|spdk|iperf|fio|memtester|stressapptest|stress-ng' || echo "none"
echo "=== tmux sessions ==="
tmux ls 2>/dev/null || echo "no tmux server"
echo "=== opencode present ==="
command -v opencode || echo "not installed"
ls ~/.opencode/bin 2>/dev/null || echo "no ~/.opencode/bin"
echo "=== DNS $LLM ==="
getent hosts "$LLM" || echo "DNS_FAIL $LLM"
echo "=== outbound TLS $LLM ==="
curl -sS -o /dev/null -w "$LLM HTTP %{http_code} total %{time_total}s\n" --connect-timeout 8 "https://$LLM" 2>&1 || echo "CURL_FAIL $LLM"
echo "=== proxy env ==="
env | grep -i proxy || echo "no proxy env"
echo "=== port 4096 ==="
ss -tlnp 2>/dev/null | grep ':4096' || echo "4096 free"
echo "=== cpu avx2 ==="
grep -qwi avx2 /proc/cpuinfo && echo "avx2 yes" || echo "avx2 NO (needs baseline build)"
echo "=== probe done ==="
PAYLOAD

FAILED=0
for k in $(keys); do
  n="$(name_of "$k")"
  log "P0 probe -> $n ($(ip_of "$k"))"
  ssh_put "$k" "$PAYLOAD" "/tmp/oc_p0.sh"
  OUT="$(ssh_cmd "$k" "bash /tmp/oc_p0.sh $OC_LLM_HOST")" || { log "probe failed on $n"; FAILED=1; continue; }
  printf '%s\n' "$OUT"
  printf '%s\n' "$OUT" | grep -q "avx2 yes" || { log "GATE FAIL: no avx2 on $n"; FAILED=1; }
  printf '%s\n' "$OUT" | grep -q "4096 free" || { log "GATE FAIL: port 4096 busy on $n"; FAILED=1; }
done
rm -f "$PAYLOAD"
[ "$FAILED" = 0 ] || die "P0 gates failed (see output above)"
log "P0 PASS"
