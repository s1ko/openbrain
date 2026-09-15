#!/usr/bin/env bash
set -uo pipefail

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || { echo "memory-metrics: cannot source lib/common.sh" >&2; exit 1; }

MEMROOT="${1:-$OPENBRAIN_MEMORY_ROOT}"
[[ -d "$MEMROOT" ]] || { echo "memory-metrics: $MEMROOT not found" >&2; exit 2; }
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
NOW=$(date +%s)

MAP_SLUGS=(); MAP_CWDS=()
if [[ -r "$CLAUDE_JSON" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r -d '' path; do
        [[ -n "$path" ]] || continue
        case "$path" in (*$'\n'*) continue ;; esac
        MAP_SLUGS+=("$(path_to_slug "$path")"); MAP_CWDS+=("$path")
    done < <(jq -j '.projects | keys[] | . + "\u0000"' "$CLAUDE_JSON" 2>/dev/null)
fi
lookup_cwd() {
    local i
    for (( i = 0; i < ${#MAP_SLUGS[@]}; i++ )); do
        [[ "${MAP_SLUGS[$i]}" == "$1" ]] && { printf '%s\n' "${MAP_CWDS[$i]}"; return 0; }
    done
    printf '?\n'
}

printf '%-34s %-34s %5s %4s %3s %s\n' 'project' 'memory_file' 'bytes' 'age' 'sig' 'cwd'
printf '%s\n' '----------------------------------------------------------------------------------------------------------'

shopt -s nullglob
while IFS= read -r memdir; do
    slug="$(basename "$(dirname "$memdir")")"
    cwd="$(lookup_cwd "$slug")"

    for f in "$memdir"/*.md; do
        [[ -L "$f" ]] && continue
        [[ "$(basename "$f")" == 'MEMORY.md' ]] && continue
        stem="$(basename "$f" .md)"
        bytes="$(p_stat_size "$f")"; bytes="${bytes:-0}"
        mtime="$(p_stat_mtime "$f")"; mtime="${mtime:-$NOW}"
        [[ "$mtime" -gt 0 ]] 2>/dev/null || mtime="$NOW"
        age_d=$(( (NOW - mtime) / 86400 ))
        sig='-'
        [[ -f "$f.hmac" ]] && sig='Y'
        printf '%-34s %-34s %5s %4s %3s %s\n' "$slug" "$stem" "$bytes" "$age_d" "$sig" "$cwd"
    done
done < <(resolve_memdirs "$MEMROOT")
