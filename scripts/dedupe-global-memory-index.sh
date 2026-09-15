#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APPLY=0
[[ "${DEDUPE_APPLY:-0}" == 1 ]] && APPLY=1
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        *) POSITIONAL+=( "$arg" ) ;;
    esac
done

ROOT="${POSITIONAL[0]:-$OPENBRAIN_MEMORY_ROOT}"
GLOBAL="$ROOT/_global/memory"
KEY_FILE="$OPENBRAIN_HMAC_KEY"

if [[ ! -d "$GLOBAL" ]]; then
    echo "ERROR: $GLOBAL not found" >&2
    exit 2
fi

shopt -s nullglob
globals=()
for f in "$GLOBAL"/*.md; do
    base="$(basename "$f")"
    [[ "$base" == 'MEMORY.md' ]] && continue
    globals+=( "$base" )
done

if (( ${#globals[@]} == 0 )); then
    echo 'no global memory files'
    exit 0
fi

green "globals: ${globals[*]}"

if (( APPLY )); then
    bold 'apply mode: pruned lines are printed below, then written'
else
    bold 'dry-run (default): nothing will be written — pass --apply (or DEDUPE_APPLY=1) to prune'
fi

RESIGN_FAIL=0
TOTAL_REMOVED=0
PROJECTS_AFFECTED=0
trap 'rm -f "${tmp:-}"' EXIT
while IFS= read -r memdir; do
    slug="$(basename "$(dirname "$memdir")")"
    [[ "$slug" == '_global' ]] && continue
    idx="$memdir/MEMORY.md"
    [[ -f "$idx" ]] || continue
    [[ -L "$idx" ]] && continue

    (( APPLY )) && tmp="$(mktemp "$memdir/.MEMORY.md.XXXXXX")"
    removed=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        skip=0
        matched_g=''
        target="$(memory_index_link_target "$line")" || target=''
        for g in "${globals[@]}"; do
            if [[ -n "$target" ]] && [[ "$target" == "$g" ]] && [[ ! -e "$memdir/$g" ]]; then
                skip=1
                matched_g="$g"
                break
            fi
        done
        if (( skip )); then
            removed=$((removed+1))
            if (( APPLY )); then
                yellow "  $slug: removing (matches $GLOBAL/$matched_g):"
            else
                yellow "  $slug: would remove (matches $GLOBAL/$matched_g):"
            fi
            printf '    %s\n' "$line"
        elif (( APPLY )); then
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$idx"

    if (( removed > 0 )); then
        TOTAL_REMOVED=$((TOTAL_REMOVED+removed))
        PROJECTS_AFFECTED=$((PROJECTS_AFFECTED+1))
        if (( APPLY )); then
            p_replace_keep_mode "$idx" "$tmp"
            if [[ -f "$idx.hmac" ]] && ! hmac_write_sidecar "$KEY_FILE" "$idx"; then
                RESIGN_FAIL=1
            fi
            yellow "  $slug: removed $removed line(s)"
        else
            yellow "  $slug: would remove $removed line(s)"
        fi
    else
        (( APPLY )) && rm -f "$tmp"
    fi
done < <(resolve_memdirs "$ROOT")

if (( ! APPLY )); then
    if (( TOTAL_REMOVED > 0 )); then
        bold "dry-run: $TOTAL_REMOVED line(s) across $PROJECTS_AFFECTED project(s) would be removed"
        echo 'Re-run with --apply (or DEDUPE_APPLY=1) to prune them.'
    else
        green 'dry-run: nothing to remove'
    fi
    exit 0
fi

if (( RESIGN_FAIL )); then
    red 'done, but one or more HMAC re-signs failed (stale signatures above)'
    exit 1
fi
green 'done'
