#!/usr/bin/env bash
# dispatch_task.sh - orchestrator-side task dispatcher (WSL): create a session on
# a named worker, send the prompt from a file (blocking), print session info and
# the agent's reply (text parts + tool-call trace).
# usage: dispatch_task.sh <NAME|list> <promptfile> [wait_seconds]
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

SID=$(curl -s -u "$OC_SERVE_USER:$PW" -X POST -H 'content-type: application/json' -d '{}' \
  "$B/session" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
echo "[dispatch] $NAME session: $SID"

code=$(curl -s --max-time "$WAIT" -u "$OC_SERVE_USER:$PW" -X POST -H 'content-type: application/json' \
  -d @"$BODY" "$B/session/$SID/message" -o "$RESP" -w '%{http_code}')
echo "[dispatch] POST -> $code"
if [ "$code" != "200" ]; then
  head -c 400 "$RESP"; echo
  die "dispatch failed ($code)"
fi

python3 - "$RESP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
info = d.get("info", {})
tk = info.get("tokens", {})
print("-- model %s/%s tokens in=%s out=%s finish=%s" % (
    info.get("providerID"), info.get("modelID"), tk.get("input"), tk.get("output"), info.get("finish")))
for p in d.get("parts", []):
    t = p.get("type")
    if t == "text":
        print(p.get("text", ""))
    elif t == "tool":
        st = p.get("state", {})
        print("[tool %s %s]" % (p.get("tool"), st.get("status")))
PY
