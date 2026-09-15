#!/usr/bin/env bash
set -euo pipefail
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
HERE="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=../scripts/lib/common.sh
source "$HERE/../scripts/lib/common.sh"

BACKEND=search
if [ "${1:-}" = "--hybrid" ]; then BACKEND=query; shift; fi
command -v qmd >/dev/null 2>&1 || { echo "run.sh: qmd no está en PATH — me niego a registrar una línea falsa" >&2; exit 1; }
[ -r "$OPENBRAIN_EVAL_GOLDEN" ] || { echo "run.sh: golden set no legible: $OPENBRAIN_EVAL_GOLDEN (OPENBRAIN_EVAL_GOLDEN)" >&2; exit 1; }
GCOL="$(jq -r '.collection // empty' "$OPENBRAIN_EVAL_GOLDEN" 2>/dev/null || true)"
if [ -n "$GCOL" ] && [ -n "$OPENBRAIN_COLLECTION" ] && [ "$GCOL" != "$OPENBRAIN_COLLECTION" ]; then
    echo "run.sh: el golden set mide la colección '$GCOL' pero openbrain recall usa '$OPENBRAIN_COLLECTION' (OPENBRAIN_COLLECTION) — me niego a medir otra colección" >&2
    exit 1
fi
mkdir -p "$(dirname "$OPENBRAIN_EVAL_METRICS")"

STAMP="$(p_now_iso)"
python3 "$HERE/index-freshness.py" "${GCOL:-$OPENBRAIN_COLLECTION}" "$OPENBRAIN_WIKI_ROOT" >&2 || true
OUT="$(python3 "$HERE/recall-eval.py" "$OPENBRAIN_EVAL_GOLDEN" --backend "$BACKEND" "$@")"
printf '%s %s\n' "$STAMP" "$OUT" >> "$OPENBRAIN_EVAL_METRICS"
echo "registrado $STAMP: $OUT"
