#!/usr/bin/env bash
# Install an API-key provider into every worker's opencode auth (merge, not
# replace - existing entries like zai-coding-plan OAuth are kept for rollback).
# usage: auth_provider_key.sh <provider-id> <keyfile>
#   keyfile: one line containing the API key (e.g. secrets/zai_api_key)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PROVIDER="${1:-}"
KEYFILE="${2:-}"
[ -n "$PROVIDER" ] || die "usage: auth_provider_key.sh <provider-id> <keyfile>"
[ -f "$KEYFILE" ] || die "keyfile not found: $KEYFILE"

KEY="$(tr -d ' \r\n' < "$KEYFILE")"
[ -n "$KEY" ] || die "keyfile is empty: $KEYFILE"

for k in $(keys); do
  n="$(name_of "$k")"
  STAGE="$(mktemp /tmp/oc_auth.XXXXXX)"
  log "auth[$PROVIDER] -> $n"
  fetch "$k" "/root/.local/share/opencode/auth.json" "$STAGE/auth.json"
  KEY="$KEY" PROVIDER="$PROVIDER" STAGE="$STAGE" python3 - <<'PY'
import json, os
p = os.path.join(os.environ["STAGE"], "auth.json")
try:
    d = json.load(open(p))
except Exception:
    d = {}
d[os.environ["PROVIDER"]] = {"type": "api", "key": os.environ["KEY"]}
json.dump(d, open(p, "w"), indent=2)
PY
  ssh_put "$k" "$STAGE/auth.json" "/root/.local/share/opencode/auth.json"
  ssh_cmd "$k" "chmod 600 /root/.local/share/opencode/auth.json && grep -c $PROVIDER /root/.local/share/opencode/auth.json"
  rm -f "$STAGE/auth.json"
done
log "auth_provider_key PASS (provider=$PROVIDER)"
