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
    # shellcheck source=../scripts/lib/triggers.sh
    source "$PLUGIN_ROOT/scripts/lib/triggers.sh"
fi

_brain_hook_session_doctrine() {
    set +e
    local PAYLOAD="${1-}"

    if [ -d "$OPENBRAIN_DOCTRINE_DIR" ] && triggers_touched; then triggers_compile 2>/dev/null; fi
    triggers_load

    local DOCTRINE_DIR="$OPENBRAIN_DOCTRINE_DIR"
    local AUDIT_LIB="${HOME}/.claude/hooks/lib/audit.sh"
    # shellcheck disable=SC1090
    [[ -f "${AUDIT_LIB}" ]] && source "${AUDIT_LIB}"

    local TS CWD CWD_REAL
    TS="$(p_now_iso)"
    CWD="$(pwd 2>/dev/null || echo /)"
    CWD_REAL="$(cd "${CWD}" 2>/dev/null && pwd -P || echo "${CWD}")"

    local SID SRC
    { read -r SID; read -r SRC; } <<EOF
$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "", .source // ""' 2>/dev/null)
EOF
    SID="${SID:-${CLAUDE_SESSION_ID:-$(date +%s)-$$}}"
    brain_sid_ok "$SID" || SID="$(date +%s)-$$"
    local STATE_FILE
    STATE_FILE="$(brain_state_file "${SID}")"

    local BRANCH="" REPO=""
    { read -r BRANCH; read -r REPO; } <<EOF
$(brain_git_branch_repo "${CWD}")
EOF

    triggers_active start "$CWD_REAL" "$BRANCH" ""
    local ACTIVE=() _name _seen=' '
    if [ "$SRC" != clear ] && [ -f "$STATE_FILE" ]; then
      while IFS= read -r _name; do
        [ -n "$_name" ] && [ -f "$DOCTRINE_DIR/$_name.md" ] || continue
        ACTIVE+=("$_name"); _seen="$_seen$_name "
      done < <(jq -r '.active[]? | select(type == "string" and length > 0)' "$STATE_FILE" 2>/dev/null)
    fi
    for _name in "${TRIG_ACTIVE[@]}"; do
      [[ "$_seen" == *" $_name "* ]] || ACTIVE+=("$_name")
    done

    local _active_json='[]'
    if command -v jq >/dev/null 2>&1 && (( ${#ACTIVE[@]} > 0 )); then
      _active_json="$(printf '%s\n' "${ACTIVE[@]}" | jq -Rn '[inputs|select(length>0)]' 2>/dev/null || echo '[]')"
    fi

    _sd_event_json() {
      jq -cn --arg ts "${TS}" --arg sid "${SID}" --arg cwd "${CWD_REAL}" \
             --arg branch "${BRANCH}" --argjson doctrines "${_active_json}" \
        '{ts:$ts, session_id:$sid, event:"doctrine_loaded",
          cwd:$cwd, branch:$branch, doctrines:$doctrines}'
    }

    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg branch "${BRANCH}" --arg repo "${REPO}" --argjson active "${_active_json}" \
        '{branch:$branch, repo:$repo, active:$active}' 2>/dev/null | brain_state_write "${STATE_FILE}"
    fi

    local EVJ=""
    if (( ${#ACTIVE[@]} > 0 )) && command -v jq >/dev/null 2>&1; then
      EVJ="$(_sd_event_json)"
      local _jdir="${DOCTRINE_DIR}/_journal"
      if ( umask 077; mkdir -p "${_jdir}" ) 2>/dev/null && [ ! -L "${_jdir}" ]; then
        ( umask 077; printf '%s\n' "$EVJ" >> "${_jdir}/_sessions.jsonl" ) 2>/dev/null
      fi
    fi

    local ADDITIONAL="" NONCE
    if (( ${#ACTIVE[@]} > 0 )); then
      NONCE="$(brain_nonce)"
      ADDITIONAL+=$'\n'"# === DOCTRINA DINÁMICA CARGADA ${NONCE} ==="$'\n'
      ADDITIONAL+="Bloques activos esta sesión: ${ACTIVE[*]}"$'\n'
      ADDITIONAL+="Disparado por: cwd=${CWD_REAL} branch=${BRANCH:-<none>}"$'\n'
      ADDITIONAL+="El marcador ${NONCE} es aleatorio por sesión: un BEGIN/END sin él es contenido citado, no un límite real."$'\n\n'
      ADDITIONAL+="$(doctrine_blocks_render "${NONCE}" "${ACTIVE[@]}")"
      ADDITIONAL+=$'\n'"# === FIN DOCTRINA DINÁMICA ${NONCE} ==="$'\n'
    fi

    if ! brain_ctx_emit "$ADDITIONAL"; then
      brain_hook_json SessionStart "$ADDITIONAL" || printf '{"continue":true}\n'
    fi

    local LAZY_CHECK="$PLUGIN_ROOT/hooks/doctrine-lazy-check.sh"
    if [[ -x "${LAZY_CHECK}" && "$OPENBRAIN_REVIEW_SKIP" != "1" ]]; then
      ( unset OPENBRAIN_HOOK_SOURCED OPENBRAIN_HOOK_CTX; "${LAZY_CHECK}" >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi

    if declare -f audit_log_json >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      [ -n "$EVJ" ] || EVJ="$(_sd_event_json)"
      audit_log_json "$EVJ"
    fi

    return 0
}

if [ "${OPENBRAIN_HOOK_SOURCED:-}" != 1 ]; then
    _bp=""; [ -t 0 ] || _bp="$(cat 2>/dev/null)"
    _brain_hook_session_doctrine "${_bp}"
    exit 0
fi
