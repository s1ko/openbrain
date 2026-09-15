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

_brain_hook_doctrine_journal() {
    set +e
    local PAYLOAD="${1-}"

    local JOURNAL_DIR="$OPENBRAIN_DOCTRINE_DIR/_journal"
    ( umask 077; mkdir -p "${JOURNAL_DIR}" )

    command -v jq >/dev/null 2>&1 || return 0

    local SID TRANSCRIPT
    { read -r SID; read -r TRANSCRIPT; } <<EOF
$(printf '%s' "${PAYLOAD}" | jq -r '.session_id // "", .transcript_path // ""' 2>/dev/null)
EOF
    SID="${SID:-${CLAUDE_SESSION_ID:-}}"
    brain_sid_ok "$SID" || SID=""
    [[ -z "${SID}" ]] && return 0

    local JOURNAL_SESSIONS="${JOURNAL_DIR}/_sessions.jsonl"
    local TS_END CWD
    TS_END="$(p_now_iso)"
    CWD="$(pwd 2>/dev/null || echo /)"

    local DOCTRINES=""
    if [[ -s "${JOURNAL_SESSIONS}" ]]; then
      DOCTRINES="$(grep -F "\"session_id\":\"${SID}\"" "${JOURNAL_SESSIONS}" 2>/dev/null \
                   | grep -E '"event":"doctrine_(loaded|extended)"' | jq -r '.doctrines[]?' 2>/dev/null | sort -u)"
    fi
    [[ -z "${DOCTRINES}" ]] && return 0

    local STATS='{"edit_count":0,"edited_paths":[],"tools_used":[],"blocked_actions":[]}'
    case "$TRANSCRIPT" in
      /*) [[ -f "$TRANSCRIPT" && ! -L "$TRANSCRIPT" && -r "$TRANSCRIPT" ]] || TRANSCRIPT="" ;;
      *)  TRANSCRIPT="" ;;
    esac
    if [[ -n "$TRANSCRIPT" ]]; then
      STATS="$(jq -cRn '
        [inputs | fromjson? | select(type == "object")] as $all
        | [$all[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")] as $tu
        | ($tu | map({key: (.id // ""), value: (.name // "")}) | from_entries) as $tool_of
        | [$all[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true) | ($tool_of[.tool_use_id // ""] // "?")] as $err
        | [$tu[] | select(.name == "Write" or .name == "Edit" or .name == "MultiEdit") | .input.file_path? // empty] as $edits
        | { edit_count: ($edits | length),
            edited_paths: ($edits | reverse | reduce .[] as $p ([]; if index($p) then . else . + [$p] end) | .[0:10]),
            tools_used: ([$tu[] | .name] | group_by(.) | map({tool: .[0], count: length}) | sort_by(-.count) | .[0:10]),
            blocked_actions: ($err | group_by(.) | map({tool: .[0], count: length}) | sort_by(-.count) | .[0:10]) }
      ' "$TRANSCRIPT" 2>/dev/null)"
      [[ -n "$STATS" ]] || STATS='{"edit_count":0,"edited_paths":[],"tools_used":[],"blocked_actions":[]}'
    fi

    _dj_upsert() {
      local f="$1" line="$2" t
      if [[ -s "$f" ]] && grep -qF "\"sid\":\"${SID}\"" "$f" 2>/dev/null; then
        t="$(mktemp "${JOURNAL_DIR}/.upsert.XXXXXX" 2>/dev/null)" || { printf '%s\n' "$line" >> "$f"; return; }
        grep -vF "\"sid\":\"${SID}\"" "$f" > "$t" 2>/dev/null
        printf '%s\n' "$line" >> "$t"
        chmod 600 "$t" 2>/dev/null
        mv -f "$t" "$f" 2>/dev/null || { rm -f "$t"; printf '%s\n' "$line" >> "$f"; }
      else
        printf '%s\n' "$line" >> "$f"
      fi
    }

    local name out_file ts_start line
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      out_file="${JOURNAL_DIR}/${name}.jsonl"
      ts_start=""
      [[ -s "${out_file}" ]] && ts_start="$(grep -F "\"sid\":\"${SID}\"" "${out_file}" 2>/dev/null | tail -1 | jq -r '.ts // empty' 2>/dev/null)"
      line="$(jq -cn \
        --arg ts "${ts_start:-$TS_END}" --arg ts_end "${TS_END}" \
        --arg sid "${SID}" --arg cwd "${CWD}" --arg doctrine "${name}" \
        --argjson stats "${STATS}" \
        '{ts: $ts, ts_end: $ts_end, sid: $sid, doctrine: $doctrine, cwd: $cwd, event: "session"} + $stats' 2>/dev/null)"
      [[ -n "$line" ]] || continue
      ( umask 077; _dj_upsert "${out_file}" "${line}" ) 2>/dev/null
    done <<< "${DOCTRINES}"

    brain_prune_lines "${JOURNAL_SESSIONS}" 2000 1000
    while IFS= read -r name; do
      [[ -z "${name}" ]] && continue
      brain_prune_lines "${JOURNAL_DIR}/${name}.jsonl" 5000 2500
    done <<< "${DOCTRINES}"

    return 0
}

if [ "${OPENBRAIN_HOOK_SOURCED:-}" != 1 ]; then
    _bp=""; [ -t 0 ] || _bp="$(cat 2>/dev/null)"
    _brain_hook_doctrine_journal "${_bp}"
    exit 0
fi
