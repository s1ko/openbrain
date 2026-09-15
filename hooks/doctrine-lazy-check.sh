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

_brain_hook_doctrine_lazy_check() {
    set +e
    [[ "$OPENBRAIN_REVIEW_SKIP" == "1" ]] && return 0

    local DOCTRINE_DIR="$OPENBRAIN_DOCTRINE_DIR"
    local JOURNAL_DIR="${DOCTRINE_DIR}/_journal"
    local REVIEW_ROOT="${DOCTRINE_DIR}/_review"
    local CONSOLIDATE_SCRIPT="${OPENBRAIN_CONSOLIDATE_BIN:-$PLUGIN_ROOT/scripts/doctrine-consolidate.sh}"
    local MIN_HOURS=1

    command -v jq >/dev/null 2>&1 || return 0
    [[ ! -x "${CONSOLIDATE_SCRIPT}" ]] && return 0
    ( umask 077; mkdir -p "${REVIEW_ROOT}" )

    local cutoff_h
    cutoff_h="$(p_date_iso "$(p_epoch_ago "$MIN_HOURS" h)" 2>/dev/null || echo '')"

    local TO_REVIEW=()

    local NAMES=() journal_file name
    while IFS= read -r name; do
      NAMES+=("${name}")
    done < <(doctrine_journal_blocks "${JOURNAL_DIR}" "${DOCTRINE_DIR}")

    local notes_file last_review_file last_ts jsonl_count notes_count new_count
    for name in "${NAMES[@]}"; do
      journal_file="${JOURNAL_DIR}/${name}.jsonl"
      notes_file="${JOURNAL_DIR}/${name}.notes.md"
      last_review_file="${REVIEW_ROOT}/.last_review.${name}"

      last_ts=""
      if [[ -f "${last_review_file}" && -n "${cutoff_h}" ]]; then
        last_ts="$(cat "${last_review_file}" 2>/dev/null)"
        [[ "${last_ts}" > "${cutoff_h}" ]] && continue
      else
        [[ -f "${last_review_file}" ]] && last_ts="$(cat "${last_review_file}" 2>/dev/null)"
      fi

      jsonl_count=0
      if [[ -s "${journal_file}" ]]; then
        jsonl_count="$(awk -v cutoff="${last_ts}" '{
            if (!match($0, /"ts":"[^"]*"/)) next
            ts = substr($0, RSTART + 6, RLENGTH - 7)
            if (ts <= cutoff) next
            sid = match($0, /"sid":"[^"]*"/) ? substr($0, RSTART + 7, RLENGTH - 8) : "#" NR
            if (!(sid in seen)) { seen[sid] = 1; c++ }
          } END { print c+0 }' "${journal_file}" 2>/dev/null)"
      fi

      notes_count=0
      if [[ -s "${notes_file}" ]]; then
        notes_count="$(awk -v cutoff="${last_ts}" '
            function flush() {
              if (started && cand && has_body && !applied) c++
            }
            /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z[[:space:]]*$/ {
              flush()
              cand = ($2 > cutoff); has_body = 0; applied = 0; started = 1
              next
            }
            {
              if (!started) next
              if ($0 ~ /^[[:space:]]*$/) next
              has_body = 1
              if ($0 ~ /^>[[:space:]]*APLICADA/) applied = 1
            }
          END { flush(); print c+0 }' "${notes_file}" 2>/dev/null)"
      fi

      new_count=$(( ${jsonl_count:-0} + ${notes_count:-0} ))
      [[ "${new_count}" -gt 0 ]] && TO_REVIEW+=("${name}")
    done

    (( ${#TO_REVIEW[@]} == 0 )) && return 0

    local LOG_DIR="${HOME}/.claude/logs"
    mkdir -p "${LOG_DIR}"
    brain_prune_older "${LOG_DIR}" 'doctrine-consolidate-*.log' 30
    local LOCK STAMP TS_NOW
    LOCK="$(brain_state_dir)/consolidate.lock"
    brain_lock_acquire "${LOCK}" || return 0

    TS_NOW="$(p_now_iso)"
    for name in "${TO_REVIEW[@]}"; do
      printf '%s' "${TS_NOW}" > "${REVIEW_ROOT}/.last_review.${name}"
    done

    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    (
      trap '' HUP
      trap 'brain_lock_release "${LOCK}"' EXIT
      for name in "${TO_REVIEW[@]}"; do
        "${CONSOLIDATE_SCRIPT}" "${name}" >"${LOG_DIR}/doctrine-consolidate-${name}-${STAMP}.log" 2>&1
      done
    ) >/dev/null 2>&1 &
    printf '%s' "$!" > "${LOCK}/pid" 2>/dev/null
    disown $! 2>/dev/null

    return 0
}

if [ "${OPENBRAIN_HOOK_SOURCED:-}" != 1 ]; then
    _brain_hook_doctrine_lazy_check
    exit 0
fi
