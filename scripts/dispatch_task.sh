#!/usr/bin/env bash
# dispatch_task.sh - orchestrator-side task dispatcher (WSL).
# usage: dispatch_task.sh <NAME|list> <promptfile> [wait_seconds] [task_id]
# Creates a session (titled with task_id when given), sends the prompt
# (blocking), prints session info + the agent's full reply. On client timeout
# the remote session is aborted (no zombie runs). Every dispatch appends one
# line to logs/tasks.jsonl and archives the raw response under logs/.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

CMD="${1:-list}"
if [ "$CMD" = "list" ]; then
  for k in $(keys); do
    printf '%s %s\n' "$(name_of "$k")" "$(ip_of "$k")"
  done
  exit 0
fi

NAME="$CMD"
PROMPTFILE="${2:-}"
WAIT="${3:-300}"
TASKID="${4:-}"
[ -f "$PROMPTFILE" ] || die "promptfile missing: $PROMPTFILE"

KEY=""
for k in $(keys); do
  if [ "$(name_of "$k")" = "$NAME" ]; then KEY="$k"; fi
done
[ -n "$KEY" ] || die "unknown worker name: $NAME (have: $(for k in $(keys); do name_of "$k"; done | tr '\n' ' '))"

PW="$(cat "$(secret "$NAME" .pw)")"
B="http://$(ip_of "$KEY"):$OC_PORT"

BODY="$(mktemp /tmp/oc_disp_body.XXXXXX)"
RESP="$(mktemp /tmp/oc_disp_resp.XXXXXX)"
trap 'rm -f "$BODY" "$RESP"' EXIT

PROMPT="$(cat "$PROMPTFILE")" OUT="$BODY" python3 - <<'PY'
import json, os
open(os.environ["OUT"], "w").write(
    json.dumps({"parts": [{"type": "text", "text": os.environ["PROMPT"]}]}))
PY

if [ -n "$TASKID" ]; then
  SID=$(curl -s -u "$OC_SERVE_USER:$PW" -X POST -H 'content-type: application/json' \
    -d "{\"title\":\"$TASKID\"}" "$B/session" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
else
  SID=$(curl -s -u "$OC_SERVE_USER:$PW" -X POST -H 'content-type: application/json' -d '{}' \
    "$B/session" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
fi
echo "[dispatch] $NAME session: $SID (task: ${TASKID:-none})"

rc=0
code=$(curl -s --max-time "$WAIT" -u "$OC_SERVE_USER:$PW" -X POST -H 'content-type: application/json' \
  -d @"$BODY" "$B/session/$SID/message" -o "$RESP" -w '%{http_code}') || rc=$?
echo "[dispatch] POST -> ${code:-000} (curl rc=$rc)"
if [ "$rc" != "0" ]; then
  curl -s -u "$OC_SERVE_USER:$PW" -X POST "$B/session/$SID/abort" >/dev/null 2>&1 || true
  die "client timeout after ${WAIT}s - remote session aborted (no zombie)"
fi
if [ "$code" != "200" ]; then
  head -c 400 "$RESP"; echo
  die "dispatch failed ($code)"
fi

LOGDIR="$OC_ROOT/logs"
mkdir -p "$LOGDIR"
ARCHIVE="$LOGDIR/$(date +%Y%m%d_%H%M%S)_${NAME}_${TASKID:-notask}.json"
cp "$RESP" "$ARCHIVE"

python3 - "$RESP" "$LOGDIR/tasks.jsonl" "$NAME" "$TASKID" "$SID" "$code" "$ARCHIVE" <<'PY'
import json, sys, os, datetime
resp, ledger, name, taskid, sid, code, archive = sys.argv[1:]
d = json.load(open(resp))
info = d.get("info", {})
tk = info.get("tokens", {})
print("-- model %s/%s tokens in=%s out=%s finish=%s" % (
    info.get("providerID"), info.get("modelID"), tk.get("input"),
    tk.get("output"), info.get("finish")))
texts, tools = [], 0
for p in d.get("parts", []):
    t = p.get("type")
    if t == "text":
        texts.append(p.get("text", ""))
    elif t == "tool":
        tools += 1
        st = p.get("state", {})
        print("[tool %s %s]" % (p.get("tool"), st.get("status")))
print("\n".join(texts))
entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "worker": name, "task": taskid or None, "session": sid,
    "code": code, "tools": tools,
    "tokens_in": tk.get("input"), "tokens_out": tk.get("output"),
    "finish": info.get("finish"), "archive": os.path.basename(archive),
}
with open(ledger, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
PY
