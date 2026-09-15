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

_brain_sign_sessions_dir() { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/openbrain/sessions"; }
_brain_sign_log_file()     { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/openbrain/sign-memory.log"; }

_brain_sign_sid() {
    brain_sid_ok "$1" || return 0
    printf '%s' "$1"
}

_brain_sign_log() {
    local action="$1" detail="$2" sid="${3:-}" log ts
    log="$(_brain_sign_log_file)"
    mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    if command -v jq >/dev/null 2>&1; then
        ( umask 077; jq -cn --arg ts "$ts" --arg sid "$sid" --arg a "$action" --arg d "$detail" \
            '{ts:$ts, session_id:$sid, event:"sign_memory", action:$a, detail:$d}' >> "$log" ) 2>/dev/null
    else
        ( umask 077; printf '{"ts":"%s","session_id":"%s","event":"sign_memory","action":"%s","detail":"%s"}\n' \
            "$ts" "$sid" "$action" "$detail" >> "$log" ) 2>/dev/null
    fi
    brain_prune_lines "$log" 4000 2000
    return 0
}

_brain_hook_sign_memory_mark() {
    set +e
    [ "${OPENBRAIN_SIGN_ON_STOP:-1}" = 1 ] || return 0
    local payload="$1" sid dir
    sid="$(_brain_sign_sid "$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)")"
    [ -n "$sid" ] || return 0
    dir="$(_brain_sign_sessions_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    chmod 700 "$dir" 2>/dev/null
    find "$dir" -type f -name '*.start' -mtime +7 2>/dev/null \
      | while IFS= read -r f; do rm -f "$f"; done
    [ -L "$dir/$sid.start" ] && rm -f "$dir/$sid.start" 2>/dev/null
    [ -f "$dir/$sid.start" ] && return 0
    ( umask 077; : > "$dir/$sid.start" ) 2>/dev/null
    local back
    back="$(TZ=UTC date -v-2S +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC date -d '2 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)"
    [ -n "$back" ] && TZ=UTC touch -t "$back" "$dir/$sid.start" 2>/dev/null
    return 0
}

_brain_hook_sign_memory() {
    set +e
    [ "${OPENBRAIN_SIGN_ON_STOP:-1}" = 1 ] || return 0

    local payload="$1" sid dir marker scripts
    sid="$(_brain_sign_sid "$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)")"
    scripts="$PLUGIN_ROOT/scripts"
    [ -r "$scripts/verify-memory-hmac.sh" ] || return 0

    if [ -z "$sid" ]; then
        _brain_sign_log skipped "session_id ausente o invalido" ""
        return 0
    fi

    dir="$(_brain_sign_sessions_dir)"
    marker="$dir/$sid.start"
    if [ ! -f "$marker" ]; then
        _brain_sign_log skipped "sin marca de inicio de sesion" "$sid"
        return 0
    fi

    local out vrc fails=() line f
    out="$(bash "$scripts/verify-memory-hmac.sh" "$OPENBRAIN_MEMORY_ROOT" verify 2>/dev/null)"; vrc=$?
    if [ "$vrc" -eq 2 ]; then
        _brain_sign_log skipped "verify rc=2 (clave HMAC o raiz de memoria)" "$sid"
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            FAIL\ *|MISS\ *) ;;
            *) continue ;;
        esac
        f="${line#* }"
        case "$f" in
            *' ('*')') f="${f% (*}" ;;
        esac
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        fails+=( "$f" )
    done <<< "$out"

    [ "${#fails[@]}" -eq 0 ] && return 0

    local max="${OPENBRAIN_SIGN_ON_STOP_MAX:-25}"
    case "$max" in ''|*[!0-9]*) max=25 ;; esac
    if [ "${#fails[@]}" -gt "$max" ]; then
        _brain_sign_log refused "${#fails[@]} fallos (max $max) — revisar con 'openbrain memory verify'" "$sid"
        return 0
    fi

    local signed=0 outband=0 blocked=0 errors=0 rc
    for f in "${fails[@]}"; do
        if [ ! "$f" -nt "$marker" ]; then
            outband=$(( outband + 1 ))
            _brain_sign_log out_of_band "$f" "$sid"
            continue
        fi
        bash "$scripts/lint-memory.sh" "$f" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -gt 1 ]; then
            blocked=$(( blocked + 1 ))
            _brain_sign_log lint_blocked "$f (lint rc=$rc)" "$sid"
            continue
        fi
        if bash "$scripts/verify-memory-hmac.sh" "$f" sign >/dev/null 2>&1; then
            signed=$(( signed + 1 ))
            _brain_sign_log signed "$f" "$sid"
        else
            errors=$(( errors + 1 ))
            _brain_sign_log error "$f" "$sid"
        fi
    done

    if [ "$outband" -gt 0 ] || [ "$blocked" -gt 0 ] || [ "$errors" -gt 0 ]; then
        echo "openbrain/sign-memory: firmadas $signed; $outband fuera de banda, $blocked bloqueadas por lint, $errors con error — ver $(_brain_sign_log_file)" >&2
    fi
    return 0
}

if [ "${OPENBRAIN_HOOK_SOURCED:-}" != 1 ]; then
    PAYLOAD=""; [ -t 0 ] || PAYLOAD="$(cat 2>/dev/null)"
    case "${1:-Stop}" in
        SessionStart) _brain_hook_sign_memory_mark "$PAYLOAD" ;;
        *)            _brain_hook_sign_memory "$PAYLOAD" ;;
    esac
    exit 0
fi
