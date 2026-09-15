#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ARCHIVE="${1:-}"
DEST="${2:-}"
MODE="${3:-extract}"
KEY_FILE="$OPENBRAIN_HMAC_KEY"

if [[ -z "$ARCHIVE" || -z "$DEST" ]]; then
    cat >&2 <<EOF
usage: $0 <archive.tar.gz.gpg|archive.tar.gz.age> <dest-dir> [extract|test]
  extract: decrypt + verify + extract into dest-dir
  test:    decrypt + extract into a tmp dir, print file count, then clean up
env:
  OPENBRAIN_BACKUP_AGE_IDENTITY   age identity file (default ~/.config/claude/memory-backup-key.txt)
  OPENBRAIN_HMAC_KEY              HMAC key used to verify restored memories
  RESTORE_FORCE=1             allow overwriting a dest-dir that already holds .md files
  RESTORE_ALLOW_UNVERIFIED=1  restore only the files whose HMAC verifies, listing and
                              dropping the rest (exits 1 — never a clean restore)
EOF
    exit 2
fi

if [[ ! -f "$ARCHIVE" ]]; then
    echo "ERROR: archive not found: $ARCHIVE" >&2
    exit 2
fi

verify_gpg_status() {
    local status="$1"
    if grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG)' "$status"; then
        return 1
    fi
    if grep -q '^\[GNUPG:\] GOODSIG' "$status" \
        && ! grep -Eq '^\[GNUPG:\] TRUST_(ULTIMATE|FULLY)' "$status"; then
        return 1
    fi
    return 0
}

decrypt_to() {
    local out="$1" gstatus
    case "$ARCHIVE" in
        *.age)
            local identity="$OPENBRAIN_BACKUP_AGE_IDENTITY"
            if ! command -v age >/dev/null 2>&1; then
                echo 'ERROR: age not in PATH' >&2
                exit 2
            fi
            if [[ ! -r "$identity" ]]; then
                echo "ERROR: age identity not readable: $identity" >&2
                exit 2
            fi
            age -d -i "$identity" "$ARCHIVE" > "$out"
            ;;
        *.gpg)
            if ! command -v gpg >/dev/null 2>&1; then
                echo 'ERROR: gpg not in PATH' >&2
                exit 2
            fi
            gstatus="$(mktemp)"
            gpg --quiet --batch --status-file "$gstatus" --decrypt "$ARCHIVE" > "$out"
            if ! verify_gpg_status "$gstatus"; then
                rm -f "$gstatus"
                echo 'ERROR: signature present but signer is not fully/ultimately trusted (or bad/expired/revoked signature)' >&2
                exit 1
            fi
            rm -f "$gstatus"
            ;;
        *)
            echo "ERROR: unknown archive type (expected .gpg or .age): $ARCHIVE" >&2
            exit 2
            ;;
    esac
}

UNVERIFIED=()
verify_staged_hmac() {
    local stage="$1" f sig expect got list digests
    UNVERIFIED=()
    if ! hmac_key_ok "$KEY_FILE"; then
        echo "ERROR: HMAC key unusable ($KEY_FILE) — cannot verify staged backup" >&2
        while IFS= read -r f; do
            UNVERIFIED+=( "$f" )
        done < <(find "$stage" -name '*.md' -type f)
        return 1
    fi
    list="$(mktemp)"
    digests="$(mktemp)"
    while IFS= read -r f; do
        if [[ -L "$f" ]]; then
            echo "UNSIGNED $f (symlink, not verified)" >&2
            UNVERIFIED+=( "$f" ); continue
        fi
        printf '%s\n' "$f" >> "$list"
    done < <(find "$stage" -name '*.md' -type f)
    hmac_digest_list "$KEY_FILE" "$list" "$digests"
    while IFS=$'\t' read -r got f; do
        [[ -n "$f" ]] || continue
        sig="$f.hmac"
        if [[ ! -f "$sig" ]]; then
            echo "UNSIGNED $f (no sidecar in the archive)" >&2
            UNVERIFIED+=( "$f" ); continue
        fi
        if ! expect="$(cat "$sig" 2>/dev/null)"; then
            echo "FAIL $f (unreadable staged signature)" >&2
            UNVERIFIED+=( "$f" ); continue
        fi
        if [[ "$got" == '-' ]]; then
            echo "FAIL $f (hash error)" >&2
            UNVERIFIED+=( "$f" ); continue
        fi
        hmac_equal "$expect" "$got" || {
            echo "FAIL $f (HMAC mismatch)" >&2
            UNVERIFIED+=( "$f" )
        }
    done < "$digests"
    rm -f "$list" "$digests"
    (( ${#UNVERIFIED[@]} == 0 ))
}

case "$MODE" in
    extract)
        while [[ "$DEST" == */ && ${#DEST} -gt 1 ]]; do DEST="${DEST%/}"; done
        if [[ -L "$DEST" ]]; then
            echo "ERROR: $DEST is a symlink" >&2
            exit 2
        fi
        install -d -m 700 "$DEST"
        stage="$(mktemp -d)"
        work="$(mktemp)"
        trap 'rm -rf "$stage"; rm -f "$work"' EXIT
        decrypt_to "$work"
        tar -xzf "$work" -C "$stage"
        if ! find "$stage" -name '*.md' -type f -print -quit 2>/dev/null | grep -q .; then
            echo 'ERROR: no .md files in archive — nothing to restore' >&2
            exit 1
        fi
        excluded=0
        verify_failed=0
        if ! verify_staged_hmac "$stage"; then
            verify_failed=1
            if [[ -z "${RESTORE_ALLOW_UNVERIFIED:-}" ]]; then
                echo 'ERROR: staged backup fails HMAC verification — nothing restored' >&2
                echo '  set RESTORE_ALLOW_UNVERIFIED=1 to restore the verified files and drop the rest' >&2
                exit 1
            fi
            for f in ${UNVERIFIED[@]+"${UNVERIFIED[@]}"}; do
                rm -f -- "$f" "$f.hmac"
                echo "SKIP $f (excluded from the restore)" >&2
                excluded=$((excluded + 1))
            done
        fi
        if [[ -z "${RESTORE_FORCE:-}" ]] && find "$DEST" -name '*.md' -type f -print -quit 2>/dev/null | grep -q .; then
            echo "ERROR: $DEST already contains .md files — set RESTORE_FORCE=1 to overwrite" >&2
            exit 1
        fi
        cp -a "$stage"/. "$DEST"/
        if (( verify_failed )); then
            echo "PARTIAL extracted to $DEST — $excluded unverified file(s) EXCLUDED" >&2
            exit 1
        fi
        echo "OK extracted to $DEST"
        ;;
    test)
        tmp="$(mktemp -d)"
        work="$(mktemp)"
        trap 'rm -rf "$tmp"; rm -f "$work"' EXIT
        decrypt_to "$work"
        tar -xzf "$work" -C "$tmp"
        md_count=$(find "$tmp" -name '*.md' -type f | wc -l | tr -d ' ')
        hmac_count=$(find "$tmp" -name '*.md.hmac' -type f | wc -l | tr -d ' ')
        echo "OK $ARCHIVE -> md=$md_count hmac=$hmac_count"
        if (( md_count == 0 )); then
            echo 'WARN no .md files in archive' >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unknown mode '$MODE'" >&2
        exit 2
        ;;
esac
