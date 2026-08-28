#!/usr/bin/env bash
# oc-cluster shared helpers. Phase scripts source this; everything runs on the
# orchestrator host (WSL) and drives workers over SSH (sshpass, password auth).

set -euo pipefail

OC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$OC_ROOT/env/cluster.env" ]; then
  echo "FATAL: $OC_ROOT/env/cluster.env not found." >&2
  echo "       cp env/cluster.env.example env/cluster.env  # then edit" >&2
  exit 1
fi
# shellcheck source=../env/cluster.env.example disable=SC1091
source "$OC_ROOT/env/cluster.env"

SECRETS="$OC_ROOT/secrets"
mkdir -p "$SECRETS"

log() { printf '[oc] %s\n' "$*"; }
die() { printf '[oc] FATAL: %s\n' "$*" >&2; exit 1; }

# wvar W1 IP -> value of $W1_IP
wvar() {
  local var="${1}_${2}"
  [ -n "${!var:-}" ] || die "env var $var is not set (check env/cluster.env)"
  printf '%s' "${!var}"
}

keys()    { for k in $WORKERS; do printf '%s\n' "$k"; done; }
name_of() { wvar "$1" NAME; }
ip_of()   { wvar "$1" IP; }
user_of() { wvar "$1" USER; }

secret() { # secret <NAME> <suffix> -> path (must exist)
  local f="$SECRETS/$1$2"
  [ -f "$f" ] || die "missing $f"
  printf '%s' "$f"
}

ssh_cmd() { # ssh_cmd <KEY> 'remote command'   (stdin detached with -n)
  local k="$1"; shift
  SSHPASS="$(cat "$(secret "$(name_of "$k")" .sshpass)")" \
    sshpass -e ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "$(user_of "$k")@$(ip_of "$k")" "$@"
}

ssh_put() { # ssh_put <KEY> <local file> <remote path>   (payload via stdin; no -n)
  local k="$1" lp="$2" rp="$3"
  SSHPASS="$(cat "$(secret "$(name_of "$k")" .sshpass)")" \
    sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "$(user_of "$k")@$(ip_of "$k")" "cat > '$rp'" < "$lp"
}

fetch() { # fetch <KEY> <remote path> <local path>
  local k="$1" rp="$2" lp="$3"
  SSHPASS="$(cat "$(secret "$(name_of "$k")" .sshpass)")" \
    sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "$(user_of "$k")@$(ip_of "$k")" "cat '$rp'" > "$lp"
}

render() { # render <template> <out> __TOK__=value ...
  local src="$1" dst="$2"; shift 2
  [ -f "$src" ] || die "template missing: $src"
  python3 - "$src" "$dst" "$@" <<'PY'
import sys
src, dst, *toks = sys.argv[1:]
s = open(src, encoding="utf-8").read()
for t in toks:
    tok, val = t.split("=", 1)
    s = s.replace(tok, val)
open(dst, "w", encoding="utf-8", newline="\n").write(s)
PY
}
