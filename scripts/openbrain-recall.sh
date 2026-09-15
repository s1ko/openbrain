#!/usr/bin/env bash
set -euo pipefail
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODE=search; N=10; JSON=""; Q=()
while [ $# -gt 0 ]; do
    case "$1" in
        --lex) MODE=search; shift ;;
        --hybrid) MODE=query; shift ;;
        -n) N="${2:?-n necesita un número}"; shift 2 ;;
        --json) JSON=--json; shift ;;
        --) shift; Q+=("$@"); break ;;
        *) Q+=("$1"); shift ;;
    esac
done
[ "${#Q[@]}" -gt 0 ] || { echo "uso: openbrain recall [--lex|--hybrid] [-n N] [--json] <consulta>" >&2; exit 2; }
if [ -z "$OPENBRAIN_COLLECTION" ]; then
    echo "openbrain recall: OPENBRAIN_COLLECTION vacía — me niego a buscar sin scope (un qmd sin -c recorre todas las colecciones del host)" >&2
    exit 2
fi
command -v qmd >/dev/null 2>&1 || { echo "openbrain recall: qmd no está en PATH" >&2; exit 1; }
# shellcheck disable=SC2086
exec qmd "$MODE" "${Q[*]}" -c "$OPENBRAIN_COLLECTION" -n "$N" $JSON
