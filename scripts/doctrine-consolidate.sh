#!/usr/bin/env bash
set +e
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
PLUGIN_ROOT="$(cd "$(dirname "$_self")/.." 2>/dev/null && pwd -P)"
if [ -z "$PLUGIN_ROOT" ] || [ ! -r "$PLUGIN_ROOT/scripts/lib/common.sh" ]; then
    echo "openbrain/$(basename "$_self"): no resuelvo PLUGIN_ROOT desde $_self — hook inactivo" >&2
    exit 0
fi
SCRIPT_DIR="$PLUGIN_ROOT/scripts"
# shellcheck source=../scripts/lib/common.sh
source "$PLUGIN_ROOT/scripts/lib/common.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

DAYS=7
ONLY_NAME=""
DRY=0
SKIPPED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      [[ $# -ge 2 ]] || { echo "ERROR: --days requiere un valor" >&2; exit 1; }
      DAYS="$2"
      [[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: --days requiere un valor numérico: '${DAYS}'" >&2; exit 1; }
      shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --help|-h)
      echo "uso: doctrine-consolidate.sh [--days N] [--dry-run] [<bloque>]"
      exit 0 ;;
    *)
      brain_sid_ok "$1" || { echo "ERROR: nombre de bloque no válido: '$1'" >&2; exit 1; }
      ONLY_NAME="$1"; shift ;;
  esac
done

DOCTRINE_DIR="$OPENBRAIN_DOCTRINE_DIR"
JOURNAL_DIR="${DOCTRINE_DIR}/_journal"
REVIEW_ROOT="${DOCTRINE_DIR}/_review"
TODAY="$(date -u +%Y-%m-%d)"
REVIEW_DIR="${REVIEW_ROOT}/${TODAY}"

if [[ "$DRY" != 1 ]] && ! ( umask 077; mkdir -p "${REVIEW_DIR}" ); then
  echo "ERROR: no se pudo crear ${REVIEW_DIR}" >&2
  exit 1
fi

if [[ "$DRY" != 1 ]] && ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: 'claude' CLI no disponible en PATH" >&2
  exit 1
fi

declare -a BLOQUES
declare -a DONE
if [[ -n "${ONLY_NAME}" ]]; then
  if [[ -f "${DOCTRINE_DIR}/${ONLY_NAME}.md" ]]; then
    BLOQUES=("${ONLY_NAME}")
  else
    echo "ERROR: bloque '${ONLY_NAME}' no existe" >&2
    exit 1
  fi
else
  while IFS= read -r name; do
    BLOQUES+=("${name}")
  done < <(doctrine_journal_blocks "${JOURNAL_DIR}" "${DOCTRINE_DIR}" "${DAYS}")
fi

if (( ${#BLOQUES[@]} == 0 )); then
  echo "Ningún bloque con journal en los últimos ${DAYS} días. Nada que revisar."
  exit 0
fi

echo "Consolidando ${#BLOQUES[@]} bloque(s): ${BLOQUES[*]}"
echo "Ventana: ${DAYS} días"
echo "Output: ${REVIEW_DIR}/"

cutoff_iso="$(p_date_iso "$(p_epoch_ago "$DAYS" d)" 2>/dev/null || echo '1970-01-01T00:00:00Z')"

recent_commits=""
if [[ -n "${OPENBRAIN_CODE_REPO}" && -d "${OPENBRAIN_CODE_REPO}/.git" ]]; then
  recent_commits="$(git -C "${OPENBRAIN_CODE_REPO}" log --since="${DAYS} days ago" \
                     --pretty=format:'%h %s' 2>/dev/null | head -50)"
fi

sessions_recent=""
if [[ -f "${JOURNAL_DIR}/_sessions.jsonl" ]]; then
  sessions_recent="$(awk -v cutoff="$cutoff_iso" '{
      if (!match($0, /"ts":"[^"]*"/)) next
      if (substr($0, RSTART + 6, RLENGTH - 7) >= cutoff) print
    }' "${JOURNAL_DIR}/_sessions.jsonl" 2>/dev/null | grep -E '"event":"doctrine_(loaded|extended)"')"
fi

for name in "${BLOQUES[@]}"; do
  echo ""
  echo ">>> Revisando: ${name}"

  doctrine_file="${DOCTRINE_DIR}/${name}.md"
  journal_file="${JOURNAL_DIR}/${name}.jsonl"
  output_file="${REVIEW_DIR}/${name}.md"

  doctrine_contents="$(cat "${doctrine_file}" 2>/dev/null)"
  journal_recent=""
  if [[ -f "${journal_file}" ]]; then
    journal_recent="$(awk -v cutoff="$cutoff_iso" '{
        if (!match($0, /"ts":"[^"]*"/)) next
        if (substr($0, RSTART + 6, RLENGTH - 7) < cutoff) next
        n++; line[n] = $0
        sid[n] = match($0, /"sid":"[^"]*"/) ? substr($0, RSTART + 7, RLENGTH - 8) : "#" n
        last[sid[n]] = n
      } END { for (i = 1; i <= n; i++) if (last[sid[i]] == i) print line[i] }' "${journal_file}" 2>/dev/null | tail -200)"
  fi

  audit_doctrine="$(printf '%s\n' "$sessions_recent" | grep -F "\"${name}\"" | tail -50)"

  notes_file="${DOCTRINE_DIR}/_journal/${name}.notes.md"
  notes_contents=""
  [[ -f "${notes_file}" ]] && notes_contents="$(cat "${notes_file}")"

  vars_file="$(mktemp -t doctrine-vars.XXXXXX)"
  jq -n \
    --arg NAME "$name" --arg DAYS "$DAYS" --arg OUTPUT_FILE "$output_file" \
    --arg TODAY "$TODAY" --arg NOW "$(p_date_iso)" \
    --arg OPERATOR_CONTEXT "$OPENBRAIN_OPERATOR_CONTEXT" --arg CODE_REPO "${OPENBRAIN_CODE_REPO:-ninguno}" \
    --arg DOCTRINE_CONTENTS "$doctrine_contents" \
    --arg JOURNAL_RECENT "${journal_recent:-<sin entradas>}" \
    --arg AUDIT_DOCTRINE "${audit_doctrine:-<sin eventos>}" \
    --arg NOTES_CONTENTS "${notes_contents:-<sin notas>}" \
    --arg RECENT_COMMITS "${recent_commits:-<sin commits>}" \
    '$ARGS.named' > "$vars_file"
  prompt_file="$(mktemp -t doctrine-prompt.XXXXXX)"
  if ! render_template "$SCRIPT_DIR/../templates/doctrine-review-prompt.md" "$vars_file" > "$prompt_file"; then
    echo "ERROR: fallo al renderizar el prompt del bloque '${name}'" >&2
    rm -f "$vars_file" "$prompt_file"
    exit 1
  fi
  rm -f "$vars_file"

  if [[ "$DRY" == 1 ]]; then
    cat "$prompt_file"
    rm -f "$prompt_file"
    continue
  fi

  blk_lock="$(brain_state_dir)/consolidate.${name}.lock"
  if ! brain_lock_acquire "${blk_lock}"; then
    echo "  ✗ Ya hay una consolidación de '${name}' en curso; se omite." >&2
    rm -f "${prompt_file}"
    SKIPPED=1
    continue
  fi
  trap 'rm -f "${prompt_file}" "${claude_log:-}"; brain_lock_release "${blk_lock}"' EXIT

  p_now_iso > "${REVIEW_ROOT}/.last_review.${name}"

  prev_cksum=""; [[ -f "${output_file}" ]] && prev_cksum="$(cksum < "${output_file}" 2>/dev/null)"
  claude_log="$(mktemp -t doctrine-claude.XXXXXX)"
  OPENBRAIN_REVIEW_SKIP=1 claude -p "$(cat "${prompt_file}")" \
    --output-format text --max-turns "${OPENBRAIN_REVIEW_MAX_TURNS}" --allowedTools Write >"${claude_log}" 2>&1
  rc=$?
  rm -f "${prompt_file}"

  if [[ -s "${output_file}" ]] && [[ "$(cksum < "${output_file}" 2>/dev/null)" != "${prev_cksum}" ]]; then
    rm -f "${REVIEW_DIR}/.applied.${name}"
    if grep -q '^## Sin cambios propuestos' "${output_file}"; then
      applied_t="$(mktemp "${REVIEW_DIR}/.applied.${name}.XXXXXX")" && mv -f "${applied_t}" "${REVIEW_DIR}/.applied.${name}"
      echo "  ✓ Review sin cambios: ${output_file} (marcado como aplicado)"
    else
      echo "  ✓ Review escrito: ${output_file}"
    fi
    DONE+=("${name}")
  elif [[ -s "${output_file}" ]]; then
    echo "  ✗ Sin review nuevo (claude exit ${rc}): se conserva el anterior. Últimas líneas:"
    tail -5 "${claude_log}" | sed 's/^/    /'
  else
    echo "  ✗ Sin review utilizable (claude exit ${rc}). Últimas líneas:"
    tail -5 "${claude_log}" | sed 's/^/    /'
    [[ -e "${output_file}" ]] && rm -f "${output_file}"
  fi
  rm -f "${claude_log}"
  brain_lock_release "${blk_lock}"
  trap - EXIT
done

[[ "$DRY" == 1 ]] && exit 0

if (( ${#DONE[@]} > 0 )) && [[ -f "${HOME}/.claude/hooks/lib/audit.sh" ]] && command -v jq >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${HOME}/.claude/hooks/lib/audit.sh"
  bloques_json="$(printf '%s\n' "${DONE[@]}" | jq -R . | jq -s .)"
  audit_log_json "$(jq -cn \
    --arg ts "$(p_now_iso)" \
    --arg today "${TODAY}" \
    --argjson bloques "${bloques_json}" \
    --argjson days "${DAYS}" \
    '{ts:$ts, event:"doctrine_consolidate", date:$today,
      bloques:$bloques, window_days:$days}')"
fi

echo ""
echo "=== Consolidación completa ==="
echo "Reviews en: ${REVIEW_DIR}/"
echo "Aplica a mano las propuestas [x] en doctrine/<bloque>.md y registra: openbrain review --mark <bloque> ${TODAY}"
if [[ "$SKIPPED" == 1 ]]; then
  echo "Algún bloque se omitió por tener una consolidación en curso: repite más tarde." >&2
  exit 1
fi
