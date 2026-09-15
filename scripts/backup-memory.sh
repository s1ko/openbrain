#!/usr/bin/env bash
set -euo pipefail
umask 077

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="$OPENBRAIN_MEMORY_ROOT"
DEST="$OPENBRAIN_BACKUP_DIR"
AGE_RECIPIENT="$OPENBRAIN_BACKUP_AGE"
GPG_RECIPIENT="$OPENBRAIN_BACKUP_GPG"
SIGNER="$OPENBRAIN_BACKUP_SIGN_KEY"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

if [[ -n "$AGE_RECIPIENT" ]]; then
    BACKEND=age
    EXT=age
    if [[ ! "$AGE_RECIPIENT" =~ ^age1[ac-hj-np-z02-9]{58}$ ]]; then
        echo 'ERROR: OPENBRAIN_BACKUP_AGE must be an age public key (age1...)' >&2
        exit 2
    fi
elif [[ -n "$GPG_RECIPIENT" ]]; then
    BACKEND=gpg
    EXT=gpg
    if [[ ! "$GPG_RECIPIENT" =~ ^(0x)?[0-9A-Fa-f]{40}$ ]]; then
        echo 'ERROR: OPENBRAIN_BACKUP_GPG must be a full 40-char key fingerprint, not a short id/email' >&2
        exit 2
    fi
else
    echo 'ERROR: set OPENBRAIN_BACKUP_AGE (age1...) or OPENBRAIN_BACKUP_GPG (full 40-char gpg fingerprint)' >&2
    exit 2
fi

if ! command -v "$BACKEND" >/dev/null 2>&1; then
    echo "ERROR: $BACKEND not in PATH" >&2
    exit 2
fi

if [[ ! -d "$ROOT" ]]; then
    echo "ERROR: $ROOT does not exist" >&2
    exit 2
fi

while [[ "$DEST" == */ && ${#DEST} -gt 1 ]]; do DEST="${DEST%/}"; done
if [[ -L "$DEST" ]]; then
    echo "ERROR: $DEST is a symlink" >&2
    exit 2
fi
install -d -m 700 "$DEST"

archive="$DEST/memory-$TS.tar.gz.$EXT"
partial="$archive.partial"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; rm -f "$partial" "${prune_list:-}"' EXIT

: > "$tmp/files.lst"
while IFS= read -r d; do
    rel="./${d#"$ROOT"/}"
    [[ "$d" == "$ROOT" ]] && rel=.
    ( cd "$ROOT" && find "$rel" -maxdepth 1 -type f \( -name '*.md' -o -name '*.md.hmac' \) -print0 >> "$tmp/files.lst" )
done < <(resolve_memdirs "$ROOT")

if [[ ! -s "$tmp/files.lst" ]]; then
    echo "ERROR: no memory files found under $ROOT" >&2
    exit 1
fi

case "$BACKEND" in
    age)
        enc=( age -r "$AGE_RECIPIENT" -o "$partial" )
        ;;
    gpg)
        enc=( gpg --quiet --batch --yes --no-symkey-cache --trust-model always
              --recipient "$GPG_RECIPIENT" --output "$partial" )
        if [[ -n "$SIGNER" ]]; then
            enc+=( --local-user "$SIGNER" --sign --encrypt )
        else
            enc+=( --encrypt )
        fi
        ;;
esac

( cd "$ROOT" && tar --null -T "$tmp/files.lst" -czf - ) | "${enc[@]}"

chmod 600 "$partial"
mv -f "$partial" "$archive"
echo "OK $archive"

keep="$OPENBRAIN_BACKUP_KEEP"
if [[ ! "$keep" =~ ^[0-9]+$ ]] || (( 10#$keep == 0 )); then
    echo "WARN: OPENBRAIN_BACKUP_KEEP=$keep refused (would delete all backups); skipping retention prune" >&2
else
    keep=$((10#$keep))
    shopt -s nullglob
    backups=( "$DEST"/memory-*.tar.gz."$EXT" )
    if (( ${#backups[@]} > keep )); then
        prune_list="$(mktemp)"
        for f in "${backups[@]}"; do
            m="$(p_stat_mtime "$f")"; [[ -n "$m" ]] || m=0
            printf '%s\t%s\n' "$m" "$f" >> "$prune_list"
        done
        sort -t "$(printf '\t')" -k1,1rn "$prune_list" | tail -n +"$((keep + 1))" | cut -f2- \
            | while IFS= read -r old; do
                [[ -f "$old" ]] && rm -v "$old"
            done
    fi
fi
