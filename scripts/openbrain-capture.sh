#!/usr/bin/env bash
set -euo pipefail
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
D="$OPENBRAIN_CAPTURE_DIR"
case "${1:-list}" in
    list)
        [ -d "$D" ] || { echo "sin candidatos"; exit 0; }
        printf '%-40s %5s  %s\n' SESION N KINDS
        for f in "$D"/*.jsonl; do [ -f "$f" ] || continue
            printf '%-40s %5s  %s\n' "$(basename "$f" .jsonl)" "$(wc -l < "$f" | tr -d ' ')" "$(jq -r .kind "$f" | sort | uniq -c | awk '{printf "%s×%s ",$2,$1}')"
        done ;;
    show)
        sid="${2:?session_id}"
        brain_sid_ok "$sid" || { echo "session_id no valido" >&2; exit 2; }
        f="$D/$sid.jsonl"; [ -r "$f" ] || { echo "no existe $f" >&2; exit 1; }
        jq -r '"[\(.ts)] \(.kind) (\(.signal)) @ \(.cwd)\n  \(.text)\n"' "$f" ;;
    purge)
        [ -d "$D" ] || exit 0
        if [ "${2:-}" = "--all" ]; then for f in "$D"/*.jsonl; do [ -f "$f" ] && p_secure_rm "$f"; done; printf '0' > "$D/.pending"
        else capture_purge_expired "$D" "$OPENBRAIN_CAPTURE_TTL_DAYS"; fi ;;
    *) echo "uso: openbrain-capture.sh list | show <sid> | purge [--all]" >&2; exit 2 ;;
esac
