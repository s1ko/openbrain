#!/usr/bin/env bash
set -uo pipefail

[ -t 0 ] && exit 0
FILE=$(jq -r '.tool_input.file_path // ""' 2>/dev/null || true)

[[ -z "$FILE" ]] && exit 0
case "$FILE" in *.md) ;; *) exit 0 ;; esac

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
PLUGIN_ROOT="$(cd "$(dirname "$_self")/.." 2>/dev/null && pwd -P)"
if [ -z "$PLUGIN_ROOT" ] || [ ! -r "$PLUGIN_ROOT/scripts/lib/common.sh" ]; then
    echo "openbrain/$(basename "$_self"): no resuelvo PLUGIN_ROOT desde $_self — hook inactivo" >&2
    exit 0
fi
# shellcheck source=../scripts/lib/common.sh
source "$PLUGIN_ROOT/scripts/lib/common.sh"

PROJECTS_DIR="$(p_abspath "$OPENBRAIN_MEMORY_ROOT")"
[[ -z "$PROJECTS_DIR" ]] && exit 0
FILE="$(p_abspath "$FILE" || true)"
[[ -z "$FILE" ]] && exit 0
[[ "$FILE" =~ ^"$PROJECTS_DIR"/[^/]+/memory/[^/]+\.md$ ]] || exit 0

SCRIPTS="$PLUGIN_ROOT/scripts"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
rc=0
bash "$SCRIPTS/lint-memory.sh" "$FILE" >"$LOG" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
    grep -E 'FAIL|WARN|STYLE' "$LOG" >&2 || true
fi
if [[ "$rc" -eq 0 || "$rc" -eq 1 ]]; then
    if ! bash "$SCRIPTS/verify-memory-hmac.sh" "$FILE" sign >/dev/null 2>&1; then
        echo "verify-memory: HMAC sign failed for $FILE — memory written without a valid signature" >&2
        exit 2
    fi
fi
if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    echo "verify-memory: lint-memory failed (rc=$rc) for $FILE — signing blocked, memory left unsigned" >&2
    exit 2
fi
exit 0
