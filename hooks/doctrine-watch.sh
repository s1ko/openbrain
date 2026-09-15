#!/usr/bin/env bash
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
if triggers_touched; then triggers_compile 2>/dev/null; fi
triggers_load

command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=""; [ -t 0 ] || PAYLOAD="$(cat 2>/dev/null)"

{ read -r SID; read -r TOOL_NAME; read -r TOOL_CMD; read -r TOOL_FILE; } <<EOF
$(printf '%s' "${PAYLOAD}" | jq -r '.session_id // "", .tool_name // "", (.tool_input.command // "" | gsub("\n"; " ")), .tool_input.file_path // ""' 2>/dev/null)
EOF
SID="${SID:-${CLAUDE_SESSION_ID:-}}"
brain_sid_ok "$SID" || SID=""
[[ -z "${SID}" ]] && exit 0

STATE_FILE="$(brain_state_file "${SID}")"
CWD="$(pwd 2>/dev/null || echo /)"
CWD_REAL="$(cd "${CWD}" 2>/dev/null && pwd -P || echo "${CWD}")"

{ read -r BRANCH; read -r REPO; } <<EOF
$(brain_git_branch_repo "${CWD}")
EOF

TARGET_BRANCH="${BRANCH}"; BRANCH_EXPLICIT=0
if [[ "${TOOL_NAME}" == "Bash" && -n "${TOOL_CMD}" ]]; then
  BRANCH_NAME=""; BRANCH_CREATED=0
  if [[ "${TOOL_CMD}" =~ git[[:space:]]+checkout[[:space:]]+-[bB][[:space:]]+([^[:space:]~^:]+)([[:space:]]+[^[:space:]]+)?$ ]]; then
    BRANCH_NAME="${BASH_REMATCH[1]}"; BRANCH_CREATED=1
  elif [[ "${TOOL_CMD}" =~ git[[:space:]]+switch[[:space:]]+(-[cC]|--create)[[:space:]]+([^[:space:]~^:]+)([[:space:]]+[^[:space:]]+)?$ ]]; then
    BRANCH_NAME="${BASH_REMATCH[2]}"; BRANCH_CREATED=1
  elif [[ "${TOOL_CMD}" =~ git[[:space:]]+(checkout|switch)[[:space:]]+([^[:space:]~^:]+)$ ]]; then
    BRANCH_NAME="${BASH_REMATCH[2]}"
  fi
  if [[ -n "${BRANCH_NAME}" ]]; then
    if [[ "${BRANCH_CREATED}" -eq 1 ]]; then
      TARGET_BRANCH="${BRANCH_NAME}"; BRANCH_EXPLICIT=1
    elif git -C "${CWD}" rev-parse --verify --quiet "refs/heads/${BRANCH_NAME}" >/dev/null 2>&1; then
      TARGET_BRANCH="${BRANCH_NAME}"; BRANCH_EXPLICIT=1
    fi
  fi
fi

LOCK="${STATE_FILE}.lock"
brain_lock_acquire "${LOCK}" || exit 0
trap 'brain_lock_release "${LOCK}"' EXIT

declare -a PREV_ACTIVE=()
{ read -r PREV_BRANCH; read -r PREV_REPO; read -r PREV_FALLBACK
  while IFS= read -r _name; do
    PREV_ACTIVE+=("${_name}")
  done
} <<EOF
$(jq -r '.branch // "", .repo // "", .prev // "", (.active[]? | select(type == "string" and length > 0))' "${STATE_FILE}" 2>/dev/null)
EOF

[[ "$TOOL_NAME" == Read ]] || TOOL_FILE=""
triggers_active watch "$CWD_REAL" "$TARGET_BRANCH" "$TOOL_NAME" "$TOOL_FILE"
MATCHED=("${TRIG_ACTIVE[@]}")

declare -a NEW_ONLY=()
_prev_set=" ${PREV_ACTIVE[*]} "
for name in "${MATCHED[@]}"; do
  [[ "${_prev_set}" != *" ${name} "* ]] && NEW_ONLY+=("${name}")
done
ACTIVE=("${PREV_ACTIVE[@]}" "${NEW_ONLY[@]}")

BRANCH_CHANGED=0; BRANCH_SILENT=0
if [[ -n "${TARGET_BRANCH}" && "${TARGET_BRANCH}" != "${PREV_BRANCH}" ]]; then
  if [[ "${BRANCH_EXPLICIT}" -eq 0 && -n "${PREV_FALLBACK}" && "${TARGET_BRANCH}" == "${PREV_FALLBACK}" && ( -z "${PREV_REPO}" || "${REPO}" == "${PREV_REPO}" ) ]]; then
    BRANCH_SILENT=1
  elif [[ "${BRANCH_EXPLICIT}" -eq 1 || -z "${PREV_REPO}" || "${REPO}" == "${PREV_REPO}" ]]; then
    BRANCH_CHANGED=1
  fi
fi

if [[ "${BRANCH_CHANGED}" -eq 0 && ${#NEW_ONLY[@]} -eq 0 && "${BRANCH_SILENT}" -eq 0 ]]; then
  exit 0
fi

PREV_VAL=""; [[ "${BRANCH_EXPLICIT}" -eq 1 ]] && PREV_VAL="${BRANCH}"
ACTIVE_JSON="$(printf '%s\n' "${ACTIVE[@]}" | jq -Rn '[inputs|select(length>0)]' 2>/dev/null || echo '[]')"
jq -cn --arg branch "${TARGET_BRANCH}" --arg repo "${REPO}" --arg prev "${PREV_VAL}" --argjson active "${ACTIVE_JSON}" \
  '{branch:$branch, repo:$repo, prev:$prev, active:$active}' 2>/dev/null | brain_state_write "${STATE_FILE}"

if [[ "${BRANCH_CHANGED}" -eq 0 && ${#NEW_ONLY[@]} -eq 0 ]]; then
  exit 0
fi

ADDITIONAL=""
NONCE="$(brain_nonce)"
if [[ "${BRANCH_CHANGED}" -eq 1 ]]; then
  ADDITIONAL+=$'\n'"# === DOCTRINA ACTUALIZADA (cambio de branch) ${NONCE} ==="$'\n'
  ADDITIONAL+="Branch: ${PREV_BRANCH:-<ninguno>} → ${TARGET_BRANCH}"$'\n'
  [[ -n "${TOOL_CMD}" ]] && ADDITIONAL+="Comando detectado: ${TOOL_CMD}"$'\n'
  ADDITIONAL+="Bloques activos ahora: ${ACTIVE[*]:-ninguno}"$'\n'
  if (( ${#NEW_ONLY[@]} > 0 )); then
    ADDITIONAL+="Nuevos bloques: ${NEW_ONLY[*]}"$'\n\n'
    ADDITIONAL+="$(doctrine_blocks_render "${NONCE}" "${NEW_ONLY[@]}")"
  else
    ADDITIONAL+="Sin bloques nuevos: los activos ya están inyectados."$'\n'
  fi
  ADDITIONAL+=$'\n'"# === FIN DOCTRINA ACTUALIZADA ${NONCE} ==="$'\n'
elif (( ${#NEW_ONLY[@]} > 0 )); then
  ADDITIONAL+=$'\n'"# === DOCTRINA AMPLIADA (nuevo contexto detectado) ${NONCE} ==="$'\n'
  [[ -n "${TOOL_FILE}" ]] && ADDITIONAL+="Archivo detectado: ${TOOL_FILE}"$'\n'
  ADDITIONAL+="Nuevos bloques: ${NEW_ONLY[*]}"$'\n\n'
  ADDITIONAL+="$(doctrine_blocks_render "${NONCE}" "${NEW_ONLY[@]}")"
  ADDITIONAL+=$'\n'"# === FIN DOCTRINA AMPLIADA ${NONCE} ==="$'\n'
fi

if [[ -n "${ADDITIONAL}" ]]; then
  (( ${#ACTIVE[@]} > 0 )) && ( umask 077; mkdir -p "${OPENBRAIN_DOCTRINE_DIR}/_journal" && jq -cn \
      --arg ts "$(p_now_iso)" --arg sid "${SID}" --arg cwd "${CWD_REAL}" \
      --arg branch "${TARGET_BRANCH}" --argjson doctrines "${ACTIVE_JSON}" \
      '{ts:$ts, session_id:$sid, event:"doctrine_extended", cwd:$cwd, branch:$branch, doctrines:$doctrines}' \
      >> "${OPENBRAIN_DOCTRINE_DIR}/_journal/_sessions.jsonl" ) 2>/dev/null
  jq -cn --arg ac "${ADDITIONAL}" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":$ac}}'
fi

exit 0
