#!/usr/bin/env bash
# P4: end-to-end API validation from the orchestrator:
# auth -> session create -> blocking prompt with per-worker marker -> marker readback.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

for k in $(keys); do
  n="$(name_of "$k")"
  PW="$(cat "$(secret "$n" .pw)")"
  B="http://$(ip_of "$k"):$OC_PORT"
  MARKER="CLUSTER_OK_${n}"
  log "P4 e2e -> $n ($B)"

  code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -u "$OC_SERVE_USER:$PW" "$B/session")"
  [ "$code" = "200" ] || die "$n auth check: GET /session -> $code (expected 200)"

  RAW="$(curl -s --max-time 15 -u "$OC_SERVE_USER:$PW" -H 'content-type: application/json' -d '{}' "$B/session")"
  SID="$(printf '%s' "$RAW" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
  log "$n session: $SID"

  RESP="$(mktemp /tmp/oc_p4.XXXXXX)"
  curl -s --max-time 180 -u "$OC_SERVE_USER:$PW" -H 'content-type: application/json' \
    -d "{\"parts\":[{\"type\":\"text\",\"text\":\"Reply with exactly: $MARKER\"}]}" \
    "$B/session/$SID/message" -o "$RESP" \
    -w "POST message -> %{http_code} (%{time_total}s)\n"
  if grep -q "$MARKER" "$RESP"; then
    log "$n MARKER OK"
  else
    head -c 300 "$RESP"; echo
    rm -f "$RESP"
    die "$n marker NOT found in reply"
  fi
  rm -f "$RESP"
done
log "P4 PASS"
