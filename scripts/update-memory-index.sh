#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="${1:-$OPENBRAIN_MEMORY_ROOT}"
KEY_FILE="$OPENBRAIN_HMAC_KEY"
TODAY="$(date +%Y-%m-%d)"
NOW_TS="$(date +%s)"

RESIGN_FAIL=0
stale_re='^(.*[^[:space:]])[[:space:]]*\ \(([0-9]{4}-[0-9]{2}-[0-9]{2})(,\ stale)?\)$'
trap 'rm -f "${tmp:-}"' EXIT
memdirs=()
while IFS= read -r _d; do memdirs+=( "$_d" ); done < <(resolve_memdirs "$ROOT")
if [[ ${#memdirs[@]} -eq 0 ]]; then
    red "update-memory-index: no memory directories found under $ROOT"
    exit 2
fi
for memdir in "${memdirs[@]}"; do
    index="$memdir/MEMORY.md"
    [[ -f "$index" ]] || continue
    echo
    green "→ $memdir"
    tmp="$(mktemp "$memdir/.MEMORY.md.XXXXXX")"
    memdir_real="$(p_abspath "$memdir")"
    [[ -n "$memdir_real" ]] || { rm -f "$tmp"; continue; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        target="$(memory_index_link_target "$line")" || target=""
        if [[ -n "$target" && -e "$memdir/$target" ]]; then real="$(p_abspath "$memdir/$target")"; else real=""; fi
        if [[ -z "$target" ]] || [[ "$target" == /* ]] || [[ "$target" == *..* ]] || [[ -L "$memdir/$target" ]] || [[ ! -f "$memdir/$target" ]] || [[ -z "$real" ]] || [[ "$real" != "$memdir_real"/* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        if ! ts="$(memory_review_epoch "$real")"; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        shown="$(p_epoch_to_ymd "$ts")"
        age=$(( ( NOW_TS - ts ) / 86400 ))
        if [[ "$line" =~ $stale_re ]]; then
            clean="${BASH_REMATCH[1]}"
        else
            clean="$line"
        fi
        if (( age > OPENBRAIN_STALE_DAYS )); then
            printf '%s (%s, stale)\n' "$clean" "$shown" >> "$tmp"
            yellow "  stale ($age d): $target"
        else
            printf '%s (%s)\n' "$clean" "$shown" >> "$tmp"
        fi
    done < "$index"
    if cmp -s "$tmp" "$index"; then
        rm -f "$tmp"
    else
        p_replace_keep_mode "$index" "$tmp"
        if [[ -f "$index.hmac" ]] && ! hmac_write_sidecar "$KEY_FILE" "$index"; then
            RESIGN_FAIL=1
        fi
    fi
done

if (( RESIGN_FAIL )); then
    red "done — $TODAY, but one or more HMAC re-signs failed (stale signatures above)"
    exit 1
fi
green "done — $TODAY"
