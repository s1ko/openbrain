#!/usr/bin/env bash
set +e
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
PLUGIN_ROOT="$(cd "$(dirname "$_self")/.." 2>/dev/null && pwd -P)"
if [ -z "$PLUGIN_ROOT" ] || [ ! -r "$PLUGIN_ROOT/scripts/lib/common.sh" ]; then
    echo "openbrain/$(basename "$_self"): no resuelvo PLUGIN_ROOT desde $_self — hook inactivo" >&2
    exit 0
fi
export PLUGIN_ROOT
# shellcheck source=../scripts/lib/common.sh
source "$PLUGIN_ROOT/scripts/lib/common.sh"
# shellcheck source=../scripts/lib/triggers.sh
source "$PLUGIN_ROOT/scripts/lib/triggers.sh"

export OPENBRAIN_HOOK_SOURCED=1

PAYLOAD=""; [ -t 0 ] || PAYLOAD="$(cat 2>/dev/null)"

_load() {
    local f="$PLUGIN_ROOT/hooks/$1.sh"
    [ -r "$f" ] || return 0
    # shellcheck disable=SC1090
    source "$f"
}

case "${1:-}" in
    SessionStart)
        _load refresh-doctrine; _load session-doctrine; _load load-global-memory; _load sign-memory
        export OPENBRAIN_HOOK_CTX=1
        ( _brain_hook_refresh_doctrine "$PAYLOAD" ) >/dev/null 2>&1 & _rd_pid=$!
        ( _brain_hook_sign_memory_mark "$PAYLOAD" ) >/dev/null 2>&1
        CTX=""
        part="$( ( _brain_hook_session_doctrine "$PAYLOAD" ); printf X )";   CTX+="${part%X}"
        part="$( ( _brain_hook_load_global_memory "$PAYLOAD" ); printf X )"; CTX+="${part%X}"
        wait "$_rd_pid" 2>/dev/null
        if [ -n "$CTX" ]; then
            brain_hook_json SessionStart "$CTX" && exit 0
            echo "openbrain-hook: sin jq ni python3 para envolver el contexto de SessionStart — no se inyecta nada" >&2
        fi
        printf '{"continue":true}\n'
        ;;
    Stop)
        _load doctrine-journal; _load capture-flush; _load doctrine-lazy-check; _load sign-memory
        ( _brain_hook_doctrine_journal "$PAYLOAD" )   >/dev/null 2>&1
        ( _brain_hook_capture_flush "$PAYLOAD" )      >/dev/null 2>&1
        ( _brain_hook_doctrine_lazy_check "$PAYLOAD" ) >/dev/null 2>&1
        ( _brain_hook_sign_memory "$PAYLOAD" ) 2>&1 >/dev/null | head -3 >&2
        ;;
    *)
        echo "openbrain-hook: evento desconocido '${1:-}'" >&2
        ;;
esac
exit 0
