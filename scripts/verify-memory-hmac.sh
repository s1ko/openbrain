#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="${1:-$OPENBRAIN_MEMORY_ROOT}"
KEY_FILE="$OPENBRAIN_HMAC_KEY"
MODE="${2:-verify}"

if [[ ! -f "$KEY_FILE" ]]; then
    echo "ERROR: HMAC key not found at $KEY_FILE" >&2
    echo "  generate with: install -m 600 /dev/null '$KEY_FILE' && head -c 32 /dev/urandom | base64 > '$KEY_FILE'" >&2
    exit 2
fi
if [[ -L "$KEY_FILE" ]]; then
    echo "ERROR: $KEY_FILE is a symlink — refusing (fail closed)" >&2
    exit 2
fi
key_perms="$(p_stat_perms "$KEY_FILE")"
if [[ -z "$key_perms" ]]; then
    echo "ERROR: cannot determine permissions of $KEY_FILE — refusing (fail closed)" >&2
    exit 2
fi
if [[ "$key_perms" != "600" && "$key_perms" != "400" ]]; then
    echo "ERROR: $KEY_FILE has loose permissions ($key_perms), expected 600" >&2
    echo "  fix with: chmod 600 '$KEY_FILE'" >&2
    exit 2
fi
if ! key="$(cat "$KEY_FILE")"; then
    echo "ERROR: cannot read $KEY_FILE despite mode $key_perms (ACL/immutable flag?) — refusing (fail closed)" >&2
    exit 2
fi

SINGLE_FILE=""
if [[ -f "$ROOT" && ! -L "$ROOT" && "$ROOT" == *.md ]]; then
    SINGLE_FILE="$ROOT"
    single_dir="$(dirname "$SINGLE_FILE")"
    root_abs="$(p_abspath "$OPENBRAIN_MEMORY_ROOT" || true)"
    dir_abs="$(p_abspath "$single_dir" || true)"
    if [[ -L "$single_dir" || -L "$(dirname "$single_dir")" || -z "$root_abs" || -z "$dir_abs" ]] \
       || [[ ! "$dir_abs" =~ ^"$root_abs"/[^/]+/memory$ ]]; then
        echo "ERROR: $SINGLE_FILE is not a memory file under $OPENBRAIN_MEMORY_ROOT — refusing (fail closed)" >&2
        exit 2
    fi
fi

dirs=()
if [[ -z "$SINGLE_FILE" ]]; then
    while IFS= read -r _d; do dirs+=( "$_d" ); done < <(resolve_memdirs "$ROOT")
    if [[ ${#dirs[@]} -eq 0 ]]; then
        echo "ERROR: no memory directories found under $ROOT" >&2
        exit 2
    fi
fi

fail=0
shopt -s nullglob dotglob

LIST="$(mktemp)"; DIGESTS="$(mktemp)"
trap 'rm -f "$LIST" "$DIGESTS"' EXIT
chmod 600 "$LIST" "$DIGESTS" 2>/dev/null || true

collect_files() {
    local memdir f
    : > "$LIST"
    if [[ -n "$SINGLE_FILE" ]]; then
        if [[ "$SINGLE_FILE" == *$'\n'* ]]; then
            echo "SKIP $SINGLE_FILE (newline in path)" >&2
            fail=1
            return 0
        fi
        printf '%s\n' "$SINGLE_FILE" >> "$LIST"
        return 0
    fi
    for memdir in "${dirs[@]}"; do
        for f in "$memdir"/*.md; do
            [[ -L "$f" ]] && continue
            [[ "$f" == *$'\n'* ]] && { echo "SKIP $f (newline in path)" >&2; fail=1; continue; }
            printf '%s\n' "$f" >> "$LIST"
        done
    done
}

compute_digests() { hmac_digest_list "$KEY_FILE" "$LIST" "$DIGESTS"; }

case "$MODE" in
    sign)
        collect_files
        compute_digests
        while IFS=$'\t' read -r sig_content f; do
            [[ -n "$f" ]] || continue
            if [[ ! -r "$f" ]]; then
                echo "ERROR: cannot read $f" >&2
                fail=1
                continue
            fi
            if [[ -L "$f" ]]; then
                echo "SKIP $f (became a symlink during read)" >&2
                fail=1
                continue
            fi
            if [[ "$sig_content" == '-' ]]; then
                echo "ERROR: failed to hash $f" >&2
                fail=1
                continue
            fi
            if ! hmac_install_sidecar "$sig_content" "$f" 2>/dev/null; then
                echo "ERROR: cannot install sidecar for $f" >&2
                fail=1
                continue
            fi
            if [[ -n "$SINGLE_FILE" ]] && [[ "$(hmac_file "$key" "$f")" != "$sig_content" ]]; then
                hmac_write_sidecar "$KEY_FILE" "$f" || fail=1
            fi
        done < "$DIGESTS"
        if [[ "$fail" -eq 0 ]]; then
            if [[ -n "$SINGLE_FILE" ]]; then
                echo "OK signed (1 file)"
            else
                echo "OK signed (${#dirs[@]} dir(s))"
            fi
        else
            echo "FAILED to sign one or more files" >&2
        fi
        exit "$fail"
        ;;
    verify)
        collect_files
        compute_digests
        while IFS=$'\t' read -r got f; do
            [[ -n "$f" ]] || continue
            sig="$f.hmac"
            if [[ -L "$sig" ]]; then
                echo "FAIL $f (signature is a symlink)"
                fail=1
                continue
            fi
            if [[ ! -f "$sig" ]]; then
                echo "MISS $f"
                fail=1
                continue
            fi
            if ! expect="$(cat "$sig" 2>/dev/null)"; then
                echo "FAIL $f (unreadable signature)"
                fail=1
                continue
            fi
            if [[ "$got" == '-' ]]; then
                echo "FAIL $f (hash error)"
                fail=1
                continue
            fi
            if ! hmac_equal "$expect" "$got"; then
                echo "FAIL $f"
                fail=1
            else
                echo "OK   $f"
            fi
        done < "$DIGESTS"
        if [[ -z "$SINGLE_FILE" ]]; then
            for memdir in "${dirs[@]}"; do
                for sig in "$memdir"/*.md.hmac; do
                    [[ -L "$sig" ]] && continue
                    if [[ ! -e "${sig%.hmac}" ]]; then
                        echo "ORPHAN $sig"
                        fail=1
                    fi
                done
            done
        fi
        exit "$fail"
        ;;
    *)
        echo "usage: $0 [root|memdir] [sign|verify]" >&2
        exit 2
        ;;
esac
