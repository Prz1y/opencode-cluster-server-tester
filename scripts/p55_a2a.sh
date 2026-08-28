#!/usr/bin/env bash
# P5.5: render per-worker peers.json (machine-consumable A2A directory) and push it.
# ask_peer.{sh,py} are already deployed by P2; this step only needs the serve
# passwords of ALL workers, so it runs after the full P2 loop.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

STAGE="$(mktemp -d /tmp/oc_p55.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

PAIRS=""
for k in $(keys); do
  PAIRS="$PAIRS $(name_of "$k"):$(ip_of "$k")"
done

for k in $(keys); do
  n="$(name_of "$k")"
  SELF="$n" OUT="$STAGE/peers_$n.json" PAIRS="$PAIRS" OC_PORT="$OC_PORT" SECRETS="$SECRETS" \
  python3 - <<'PY'
import json, os
self_id = os.environ["SELF"]
out = os.environ["OUT"]
pairs = os.environ["PAIRS"].split()
port = os.environ["OC_PORT"]
sec = os.environ["SECRETS"]
peers = {}
for p in pairs:
    nm, ip = p.split(":", 1)
    pw = open(os.path.join(sec, nm + ".pw")).read().strip()
    peers[nm] = {"url": "http://%s:%s" % (ip, port), "password": pw}
json.dump({"self": self_id, "peers": peers}, open(out, "w"), indent=2)
PY
  log "P5.5 peers.json -> $n"
  ssh_put "$k" "$STAGE/peers_$n.json" "/root/ocws/oc_tasks/a2a/peers.json"
  ssh_cmd "$k" "chmod 600 /root/ocws/oc_tasks/a2a/peers.json && bash /root/ocws/bin/ask_peer.sh --help >/dev/null && echo ask_peer_ok"
done
log "P5.5 PASS"
