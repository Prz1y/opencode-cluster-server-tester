#!/usr/bin/env bash
# oc.sh - single entry for orchestrator operations (run from WSL).
# usage:
#   oc.sh list                                worker names + IPs
#   oc.sh exec  <NAME> <local-script> [args]  upload + run a script on worker
#   oc.sh run   <NAME> 'one-liner'            single remote command (no quoting traps)
#   oc.sh fetch <NAME> <remote> <local>       pull file from worker
#   oc.sh put   <NAME> <local> <remote>       push file to worker
#   oc.sh task  <NAME> <promptfile> [wait] [task-id]
#                                             dispatch an agent task (blocking)
# Convention: ANY non-trivial remote operation goes into a script file and runs
# via `oc.sh exec` - never inline multi-layer quoted one-liners.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

CMD="${1:-list}"
shift || true

case "$CMD" in
  list)
    for k in $(keys); do
      printf '%-10s %s\n' "$(name_of "$k")" "$(ip_of "$k")"
    done
    ;;
  exec)
    K="$1"; SCRIPT="$2"; shift 2
    ssh_put "$K" "$SCRIPT" "/tmp/oc_exec.sh"
    ssh_cmd "$K" "bash /tmp/oc_exec.sh $*"
    ;;
  run)
    K="$1"; shift
    ssh_cmd "$K" "$*"
    ;;
  fetch)
    fetch "$1" "$2" "$3"
    ;;
  put)
    ssh_put "$1" "$2" "$3"
    ;;
  task)
    bash "$OC_ROOT/scripts/dispatch_task.sh" "$@"
    ;;
  *)
    die "unknown command: $CMD (see header for usage)"
    ;;
esac
