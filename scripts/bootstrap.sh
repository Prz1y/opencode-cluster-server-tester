#!/usr/bin/env bash
# oc-cluster bootstrap: run all deployment phases in dependency order.
# Every phase script is idempotent; re-running is safe.
# usage: bootstrap.sh [--with-hub] [--with-drills]
set -euo pipefail
OC_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WITH_HUB=0
WITH_DRILLS=0
for a in "$@"; do
  case "$a" in
    --with-hub)    WITH_HUB=1 ;;
    --with-drills) WITH_DRILLS=1 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

run() { log "$1"; bash "$OC_SCRIPT_DIR/$2"; }
log() { printf '[oc] %s\n' "$*"; }

run "phase P0: probe (read-only gates)"        p0_probe.sh
run "phase P1: install opencode + hosts pin"   p1_install.sh
run "phase P1b: sshd TCP forwarding"           p1_fix_sshd.sh
run "phase T: reverse LLM tunnels (tmux)"      ../wsl/tunnels_up.sh
log    "waiting 5s for tunnels to settle";     sleep 5
run "phase P2: workspace + config + ocserve"   p2_setup.sh
run "phase P3: SELinux + firewall tuning"      p3_tuning.sh
run "phase P5.5: A2A peers.json deploy"        p55_a2a.sh
run "phase P4: e2e validation"                 p4_e2e.sh

if [ "$WITH_HUB" = 1 ]; then
  run "phase P5: Hub-0 (attach + web forwards)" ../wsl/hub0.sh
fi
if [ "$WITH_DRILLS" = 1 ]; then
  run "phase P6: drills"                        p6_drill.sh
fi

log "bootstrap complete"
