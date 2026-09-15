#!/usr/bin/env bash
set -euo pipefail
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
R="$OPENBRAIN_DOCTRINE_DIR/_review"
usage() { echo "uso: openbrain review [--run <bloque> | --mark <bloque> <fecha>]" >&2; exit 2; }

case "${1:-}" in
    --run)
        [ -n "${2:-}" ] || usage
        brain_sid_ok "$2" || { echo "openbrain review: bloque no válido: '$2'" >&2; exit 2; }
        exec bash "$SCRIPT_DIR/doctrine-consolidate.sh" "$2" ;;
    --mark)
        b="${2:-}"; d="${3:-}"
        brain_sid_ok "$b" || { echo "openbrain review: bloque no válido: '$b'" >&2; exit 2; }
        [ -n "$(p_date_to_epoch "$d")" ] || { echo "openbrain review: fecha no válida (YYYY-MM-DD): '$d'" >&2; exit 2; }
        [ -f "$R/$d/$b.md" ] || { echo "openbrain review: no existe el review $R/$d/$b.md" >&2; exit 2; }
        t="$(mktemp "$R/$d/.applied.$b.XXXXXX")"; mv -f "$t" "$R/$d/.applied.$b"
        echo "aplicado: $b ($d)"
        exit 0 ;;
    '') ;;
    *) usage ;;
esac

[ -d "$R" ] || { echo "sin directorio de reviews: $R"; exit 0; }
found=0
while IFS=$'\t' read -r d b state rf; do
    printf '%-12s %-20s %-10s %s\n' "$d" "$b" "$state" "$rf"; found=1
done < <(doctrine_reviews "$R")
[ "$found" = 1 ] || echo "sin reviews generados. Lanzar uno: openbrain review --run <bloque>"
