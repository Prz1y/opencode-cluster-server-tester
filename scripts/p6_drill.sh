#!/usr/bin/env bash
# P6: post-deploy drills against ONE worker (default: first in WORKERS).
#   Drill 1: memory protocol — task asks the model to run uptime and append a
#            journal JSONL entry; verify the entry landed.
#   Drill 2: tunnel self-heal — kill the reverse tunnel ssh, verify the
#            reconnect loop restores the worker-side listener + LLM egress.
# usage: p6_drill.sh [KEY]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

KEY="${1:-$(printf '%s' "$WORKERS" | awk '{print $1}')}"
n="$(name_of "$KEY")"
PW="$(cat "$(secret "$n" .pw)")"
B="http://$(ip_of "$KEY"):$OC_PORT"
AUTH="$OC_SERVE_USER:$PW"

echo "### DRILL 1: memory/journal on $n ###"
BODY="$(mktemp /tmp/oc_p6_body.XXXXXX)"
TASKID="MEMTEST-$(date +%m%d)-DRILL"
python3 - > "$BODY" <<PYEOF
import json
prompt = ("Task $TASKID: run \`uptime\` on this machine and report the load average. "
          "Follow your AGENTS.md memory protocol: after finishing, append the journal JSONL entry for this task. "
          "Reply with: UPTIME=<one-line> JOURNAL=written|skipped")
print(json.dumps({"parts":[{"type":"text","text":prompt}]}))
PYEOF
SID="$(curl -s -u "$AUTH" -X POST -H 'content-type: application/json' -d '{}' "$B/session" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
log "drill session: $SID"
RESP="$(mktemp /tmp/oc_p6_resp.XXXXXX)"
curl -s --max-time 150 -u "$AUTH" -X POST -H 'content-type: application/json' \
  -d @"$BODY" "$B/session/$SID/message" -o "$RESP" -w "POST -> %{http_code}\n"
grep -q "UPTIME=" "$RESP" && echo "UPTIME_REPORTED" || echo "WARN: no UPTIME= in reply"
rm -f "$BODY" "$RESP"
log "journal on $n:"
ssh_cmd "$KEY" "cat /root/ocws/oc_tasks/journal/journal.jsonl 2>/dev/null || echo NO_JOURNAL"

echo
echo "### DRILL 2: tunnel self-heal ($n) ###"
pkill -f "127.0.0.1:443:$OC_LLM_HOST:443 -N $(user_of "$KEY")@$(ip_of "$KEY")" 2>/dev/null \
  && echo "killed tunnel ssh for $n" || echo "no matching tunnel process found (is wsl/tunnels_up.sh running?)"
echo "waiting 12s for reconnect loop..."
sleep 12
ssh_cmd "$KEY" "ss -tlnp | grep ':443 ' || echo NO_443_LISTENER; \
  curl -s -o /dev/null -w '$OC_LLM_HOST from worker: %{http_code} in %{time_total}s\n' --max-time 10 https://$OC_LLM_HOST/"
echo "### P6 DRILLS DONE ###"
