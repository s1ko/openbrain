#!/usr/bin/env bash
if [ "${OPENBRAIN_HOOK_SOURCED:-}" != 1 ]; then
    set +e
    _self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
    PLUGIN_ROOT="$(cd "$(dirname "$_self")/.." 2>/dev/null && pwd -P)"
    if [ -z "$PLUGIN_ROOT" ] || [ ! -r "$PLUGIN_ROOT/scripts/lib/common.sh" ]; then
        echo "openbrain/$(basename "$_self"): no resuelvo PLUGIN_ROOT desde $_self — hook inactivo" >&2
        exit 0
    fi
    # shellcheck source=../scripts/lib/common.sh
    source "$PLUGIN_ROOT/scripts/lib/common.sh"
fi

_brain_hook_capture_flush() {
    set +e
    [ -d "$OPENBRAIN_CAPTURE_DIR" ] || return 0
    capture_purge_expired "$OPENBRAIN_CAPTURE_DIR" "$OPENBRAIN_CAPTURE_TTL_DAYS"
    local total
    total="$(cat "$OPENBRAIN_CAPTURE_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
    ( umask 077; printf '%s' "$total" > "$OPENBRAIN_CAPTURE_DIR/.pending" ) 2>/dev/null
    return 0
}

if [ "${OPENBRAIN_HOOK_SOURCED:-}" != 1 ]; then
    [ -t 0 ] || cat >/dev/null 2>&1
    _brain_hook_capture_flush ""
    exit 0
fi
