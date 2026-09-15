#!/usr/bin/env bash
set -euo pipefail
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/triggers.sh
source "$SCRIPT_DIR/lib/triggers.sh"

[ -d "$OPENBRAIN_DOCTRINE_DIR" ] || { echo "openbrain-triggers-compile: no existe $OPENBRAIN_DOCTRINE_DIR" >&2; exit 1; }
case "${1:-}" in
    '')      if triggers_touched; then triggers_compile; fi ;;
    --force) triggers_compile ;;
    --check) if triggers_stale; then exit 1; fi ;;
    *)       echo "uso: openbrain triggers [--force|--check]" >&2; exit 2 ;;
esac
