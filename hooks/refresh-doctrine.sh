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

_brain_hook_refresh_doctrine() {
    set +e
    local TOOL="$PLUGIN_ROOT/tools/refresh-claude-md/refresh_claude_md.py"
    [[ -r "$TOOL" ]] && command -v python3 >/dev/null 2>&1 || return 0

    local CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude"
    local TTL="$OPENBRAIN_DOCTRINE_TTL"
    local ALLOWLIST="$OPENBRAIN_REFRESH_ALLOWLIST"
    mkdir -p "$CACHE_DIR" 2>/dev/null || echo "refresh-doctrine: warning: cannot create $CACHE_DIR, TTL cache disabled" >&2
    local BOUND=""
    if command -v timeout >/dev/null 2>&1; then BOUND="timeout 10"
    elif command -v gtimeout >/dev/null 2>&1; then BOUND="gtimeout 10"; fi

    _rd_run() {
        local target="$1" manifest="$2" marker="${3:-}"
        [[ -f "$target" && -f "$manifest" ]] || return 0
        if [[ -n "$marker" ]]; then
            if [[ -L "$marker" ]]; then
                rm -f -- "$marker" 2>/dev/null || true
            elif [[ -e "$marker" ]]; then
                local mtime
                mtime="$(p_stat_mtime "$marker")"; [ -n "$mtime" ] || mtime=0
                local age=$(( $(date +%s) - mtime ))
                (( age < TTL )) && return 0
            fi
        fi
        local rc=0
        # shellcheck disable=SC2086
        $BOUND python3 "$TOOL" "$target" "$manifest" >/dev/null 2>&1 || rc=$?
        [[ "$rc" -eq 0 && -n "$marker" ]] && touch -- "$marker" 2>/dev/null
        return 0
    }

    _rd_cwd_allowlisted() {
        [[ -f "$ALLOWLIST" && ! -L "$ALLOWLIST" ]] || return 1
        local cwd_real line entry
        cwd_real="$(pwd -P)" || return 1
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            line="$(_brain_expand_home "$line")"
            [[ "$line" == "$cwd_real" ]] && return 0
            entry="$(cd "$line" 2>/dev/null && pwd -P)" || continue
            [[ "$entry" == "$cwd_real" ]] && return 0
        done < "$ALLOWLIST"
        return 1
    }

    _rd_run "${HOME}/.claude/CLAUDE.md" "${HOME}/.claude/refresh.toml" "$CACHE_DIR/refresh-global.marker"

    if [[ -f "${PWD}/.claude/refresh.toml" && -f "${PWD}/CLAUDE.md" ]] && _rd_cwd_allowlisted; then
        _rd_run "${PWD}/CLAUDE.md" "${PWD}/.claude/refresh.toml" \
            "$CACHE_DIR/refresh-local-$(pwd -P | cksum | awk '{print $1}').marker"
    fi
    return 0
}

if [ "${OPENBRAIN_HOOK_SOURCED:-}" != 1 ]; then
    _brain_hook_refresh_doctrine
    exit 0
fi
