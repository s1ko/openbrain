#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

KEY_FILE="$OPENBRAIN_HMAC_KEY"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <memory-file.md> [YYYY-MM-DD]" >&2
    exit 2
fi

FILE="$1"
DATE="${2:-$(date +%Y-%m-%d)}"

if [[ ! -f "$FILE" ]]; then
    echo "ERROR: $FILE not found" >&2
    exit 2
fi

if [[ -L "$FILE" ]]; then
    echo "ERROR: $FILE is a symlink" >&2
    exit 2
fi

_file_real="$(p_abspath "$FILE")"
_root_real="$(p_abspath "$OPENBRAIN_MEMORY_ROOT")"
if [[ -z "$_file_real" || -z "$_root_real" || "$_file_real" != "$_root_real"/* ]]; then
    echo "ERROR: $FILE resolves outside $OPENBRAIN_MEMORY_ROOT — set OPENBRAIN_MEMORY_ROOT to operate elsewhere" >&2
    exit 2
fi

if [[ -z "$(p_date_to_epoch "$DATE")" ]]; then
    echo "ERROR: invalid date '$DATE'" >&2
    exit 2
fi

resign() {
    local f="$1"
    if [[ ! -f "$f.hmac" ]]; then
        echo "  warn: $f has no HMAC sidecar — reviewed date written but file remains unsigned (openbrain memory sign)" >&2
        return 0
    fi
    hmac_write_sidecar "$KEY_FILE" "$f"
}

orig="$(cat "$FILE"; printf X)"
orig="${orig%X}"

if ! printf '%s' "$orig" | head -n1 | grep -q '^---$'; then
    echo "ERROR: $FILE has no frontmatter" >&2
    exit 1
fi
if [[ "$(printf '%s' "$orig" | grep -c '^---$')" -lt 2 ]]; then
    echo "ERROR: $FILE has malformed frontmatter (no closing ---)" >&2
    exit 1
fi

TMP="$(mktemp "$FILE.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
if printf '%s' "$orig" | awk '/^---$/{c++} c==1 && /^reviewed:/{found=1} END{exit !found}'; then
    printf '%s' "$orig" | awk -v d="$DATE" '
        /^---$/ { c++ }
        c==1 && /^reviewed:/ && !done { print "reviewed: " d; done=1; next }
        c==1 && /^reviewed:/ { next }
        { print }
    ' > "$TMP"
else
    printf '%s' "$orig" | awk -v d="$DATE" '
        /^---$/ && c==0 { print; c++; next }
        /^---$/ && c==1 { print "reviewed: " d; print; c++; next }
        { print }
    ' > "$TMP"
fi
p_replace_keep_mode "$FILE" "$TMP"

if awk -v d="$DATE" '/^---$/{c++} c==1 && $0=="reviewed: " d {found=1} END{exit !found}' "$FILE"; then
    if resign "$FILE"; then
        echo "OK reviewed=$DATE → $FILE"
    else
        echo "ERROR: reviewed=$DATE written to $FILE but its HMAC re-sign failed — signature is stale" >&2
        exit 1
    fi
else
    echo "ERROR: reviewed field not set in $FILE" >&2
    exit 1
fi
