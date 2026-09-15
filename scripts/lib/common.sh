#!/usr/bin/env bash

[ -n "${_OPENBRAIN_COMMON_LOADED:-}" ] && return 0
_OPENBRAIN_COMMON_LOADED=1

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

resolve_memdirs() {
    local root="$1" restore
    shopt -q nullglob && restore='shopt -s nullglob' || restore='shopt -u nullglob'
    # shellcheck disable=SC2064
    trap "$restore" RETURN
    shopt -s nullglob
    if [[ "$(basename "$root")" == 'memory' && -d "$root" && ! -L "$root" ]]; then
        printf '%s\n' "$root"
    else
        local p d
        for p in "$root"/*; do
            [[ -d "$p" && ! -L "$p" ]] || continue
            d="$p/memory"
            [[ -d "$d" && ! -L "$d" ]] || continue
            [[ "$d" == *$'\n'* ]] && continue
            printf '%s\n' "$d"
        done
    fi
}

path_to_slug() {
    printf -- '-%s\n' "$(printf '%s' "$1" | sed 's|^/||; s|[/.]|-|g')"
}

_brain_have_python() {
    if [ -z "${_OPENBRAIN_PY:-}" ]; then
        if command -v python3 >/dev/null 2>&1; then _OPENBRAIN_PY=python3; else _OPENBRAIN_PY='-'; fi
    fi
    [ "$_OPENBRAIN_PY" != '-' ]
}

hmac_stdin() {
    local key="$1"
    (( ${#key} >= 16 )) || echo 'hmac: warn: HMAC key shorter than 16 bytes' >&2
    if _brain_have_python; then
        _OPENBRAIN_HMAC_KEY="$key" "$_OPENBRAIN_PY" -c '
import hashlib, hmac, os, sys
k = os.environ["_OPENBRAIN_HMAC_KEY"].encode("utf-8", "surrogateescape")
sys.stdout.write(hmac.new(k, sys.stdin.buffer.read(), hashlib.sha256).hexdigest() + "\n")
'
        return
    fi
    _hmac_stdin_bash "$key"
}

hmac_files() {
    local kf="$1"
    _brain_have_python || return 1
    "$_OPENBRAIN_PY" -c '
import hashlib, hmac, sys
with open(sys.argv[1], "rb") as fh:
    key = fh.read().rstrip(b"\n")
for line in sys.stdin.buffer:
    path = line.rstrip(b"\n")
    if not path:
        continue
    try:
        with open(path, "rb") as fh:
            digest = hmac.new(key, fh.read(), hashlib.sha256).hexdigest()
    except OSError:
        digest = "-"
    sys.stdout.buffer.write(digest.encode("ascii") + b"\t" + path + b"\n")
' "$kf"
}

hmac_verify_json() {
    local kf="$1"
    if ! _brain_have_python; then
        command -v openssl >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1 && command -v od >/dev/null 2>&1 || return 1
        _hmac_verify_json_bash "$kf" | jq -cs .
        return
    fi
    "$_OPENBRAIN_PY" -c '
import hashlib, hmac, json, os, sys
with open(sys.argv[1], "rb") as fh:
    key = fh.read().rstrip(b"\n")
out = []
for line in sys.stdin.buffer:
    path = line.rstrip(b"\n")
    if not path:
        continue
    entry = {"path": path.decode("utf-8", "replace"), "base": os.path.basename(path).decode("utf-8", "replace")}
    sig = path + b".hmac"
    if os.path.islink(path) or not os.path.isfile(path) or os.path.islink(sig) or not os.path.isfile(sig):
        entry["status"] = "nosig"
    else:
        try:
            with open(sig, "rb") as fh:
                expect = fh.read().rstrip(b"\n")
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            entry["status"] = "unreadable"
        else:
            got = hmac.new(key, data, hashlib.sha256).hexdigest().encode()
            if hmac.compare_digest(got, expect):
                entry["status"] = "ok"
                entry["content"] = data.decode("utf-8", "replace")
            else:
                entry["status"] = "mismatch"
    out.append(entry)
json.dump(out, sys.stdout)
' "$kf"
}

_hmac_verify_json_bash() {
    local key path expect got status snap
    key="$(cat "$1")" || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        status=nosig; snap=''
        if [[ ! -L "$path" && -f "$path" && ! -L "$path.hmac" && -f "$path.hmac" ]]; then
            if expect="$(cat "$path.hmac" 2>/dev/null)" && snap="$(cat "$path" 2>/dev/null && printf X)"; then
                snap="${snap%X}"
                got="$(hmac_stdin "$key" < <(printf '%s' "$snap"))"
                if [[ -n "$got" ]] && hmac_equal "$expect" "$got"; then status=ok; else status=mismatch; fi
            else
                status=unreadable
            fi
        fi
        if [[ "$status" = ok ]]; then
            jq -cn --arg p "$path" --arg c "$snap" '{path:$p, base:($p|split("/")|last), status:"ok", content:$c}'
        else
            jq -cn --arg p "$path" --arg s "$status" '{path:$p, base:($p|split("/")|last), status:$s}'
        fi
    done
}

_hmac_pads_bash() {
    local key="$1"
    local -r blocklen=128
    local keyhex ipad_hex='' opad_hex='' i byte

    [[ -n "${_HMAC_IPAD:-}" && "${_HMAC_PAD_KEY-}" == "$key" ]] && return 0

    keyhex="$(printf '%s' "$key" | od -An -v -tx1 | tr -d ' \n')" || return 1
    if (( ${#keyhex} > blocklen )); then
        keyhex="$(printf '%s' "$key" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')"
    fi
    [[ -n "$keyhex" ]] || return 1
    (( ${#keyhex} <= blocklen )) || return 1

    while (( ${#keyhex} < blocklen )); do keyhex+="00"; done

    for (( i = 0; i < blocklen; i += 2 )); do
        byte=$(( 16#${keyhex:i:2} ))
        printf -v ipad_hex '%s%02x' "$ipad_hex" $(( byte ^ 0x36 ))
        printf -v opad_hex '%s%02x' "$opad_hex" $(( byte ^ 0x5c ))
    done
    _HMAC_PAD_KEY="$key"; _HMAC_IPAD="$ipad_hex"; _HMAC_OPAD="$opad_hex"
}

_hmac_stdin_bash() {
    local key="$1"
    local inner_hex out

    command -v xxd >/dev/null 2>&1 || return 1
    _hmac_pads_bash "$key" || return 1

    inner_hex="$( { printf '%s' "$_HMAC_IPAD" | xxd -r -p; cat; } \
        | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')"
    [[ -n "$inner_hex" ]] || return 1

    out="$( { printf '%s' "$_HMAC_OPAD" | xxd -r -p; printf '%s' "$inner_hex" | xxd -r -p; } \
        | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')"
    [[ -n "$out" ]] || return 1

    printf '%s\n' "$out"
}

hmac_file() {
    local key="$1" file="$2"
    [[ -r "$file" ]] || return 1
    hmac_stdin "$key" < "$file"
}

hmac_equal() {
    local a="$1" b="$2" i diff=0
    (( ${#a} == ${#b} )) || return 1
    for (( i = 0; i < ${#a}; i++ )); do
        [[ "${a:i:1}" == "${b:i:1}" ]] || diff=1
    done
    (( diff == 0 ))
}

# shellcheck source=scripts/lib/portable.sh
source "$(dirname "${BASH_SOURCE[0]}")/portable.sh"
# shellcheck source=scripts/lib/config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

hmac_key_ok() {
    local kf="$1" p
    [[ -f "$kf" && ! -L "$kf" && -r "$kf" ]] || return 1
    p="$(p_stat_perms "$kf")" || return 1
    [[ "$p" == "600" || "$p" == "400" ]]
}

hmac_install_sidecar() {
    local sig="$1" f="$2" t
    if [[ -f "$f.hmac" && ! -L "$f.hmac" && "$(cat "$f.hmac" 2>/dev/null)" == "$sig" ]]; then
        return 0
    fi
    if ! t="$(mktemp "$f.hmac.XXXXXX")"; then
        echo "hmac: warn: cannot create temp sidecar for $f" >&2
        return 1
    fi
    if printf '%s\n' "$sig" > "$t" && chmod 600 "$t" && mv "$t" "$f.hmac"; then
        return 0
    fi
    rm -f "$t"
    echo "hmac: warn: cannot install sidecar for $f" >&2
    return 1
}

hmac_write_sidecar() {
    local kf="$1" f="$2" key sig again n=0
    if ! hmac_key_ok "$kf"; then
        echo "hmac: warn: $f changed but HMAC key unusable (missing/loose perms: $kf) — $f.hmac now stale" >&2
        return 1
    fi
    key="$(cat "$kf")"
    if ! sig="$(hmac_file "$key" "$f")" || [[ -z "$sig" ]]; then
        echo "hmac: warn: re-sign failed for $f — prior $f.hmac left untouched" >&2
        return 1
    fi
    while :; do
        hmac_install_sidecar "$sig" "$f" || return 1
        again="$(hmac_file "$key" "$f")" || return 1
        [[ "$again" == "$sig" ]] && return 0
        sig="$again"; n=$(( n + 1 ))
        (( n < 3 )) || { echo "hmac: warn: $f keeps changing while signing — sidecar may be stale" >&2; return 1; }
    done
}

memory_review_epoch() {
    local f="$1" rev ts
    rev="$(awk '
        NR==1 && $0=="---" { c=1; next }
        NR==1 { exit }
        c==1 && /^---$/ { if (rev != "") print rev; exit }
        c==1 && /^reviewed:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$/ {
            rev=$0; sub(/^reviewed:[[:space:]]*/,"",rev); sub(/[[:space:]]*$/,"",rev)
        }
    ' "$f")"
    if [ -n "$rev" ]; then
        ts="$(p_date_to_epoch "$rev")"
        if [ -n "$ts" ] && [ "$ts" -le "$(date +%s)" ]; then printf '%s\n' "$ts"; return 0; fi
    fi
    ts="$(p_stat_mtime "$f")"
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$ts"
}

brain_sid_ok() {
    case "$1" in ''|*[!A-Za-z0-9_.-]*|*..*) return 1 ;; esac
    return 0
}

memory_index_link_target() {
    local re='^- \[[^]]+\]\(([^)]+)\)'
    [[ "$1" =~ $re ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

brain_hook_json() {
    local event="$1" text="$2" esc
    if command -v jq >/dev/null 2>&1 \
       && printf '%s' "$text" | jq -Rs --arg ev "$event" '{continue:true, hookSpecificOutput:{hookEventName:$ev, additionalContext:.}}' 2>/dev/null; then
        return 0
    fi
    esc="$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"
    [ -n "$esc" ] || return 1
    printf '{"continue":true,"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' "$event" "$esc"
}

brain_git_branch_repo() {
    local branch="" repo=""
    { read -r branch; read -r repo; } <<EOF
$(git -C "$1" rev-parse --abbrev-ref HEAD --show-toplevel 2>/dev/null || true)
EOF
    case "$repo" in /*) ;; *) repo=""; branch="" ;; esac
    printf '%s\n%s\n' "$branch" "$repo"
}

hmac_digest_list() {
    local kf="$1" list="$2" out="$3" key f got
    [ -s "$list" ] || { : > "$out"; return 0; }
    if hmac_files "$kf" < "$list" > "$out" 2>/dev/null && [ -s "$out" ]; then
        return 0
    fi
    key="$(cat "$kf")"
    : > "$out"
    while IFS= read -r f; do
        if got="$(hmac_file "$key" "$f")"; then printf '%s\t%s\n' "$got" "$f"
        else printf -- '-\t%s\n' "$f"; fi >> "$out"
    done < "$list"
}

doctrine_journal_blocks() {
    local jdir="$1" ddir="$2" days="${3:-}" f name seen=' '
    local -a args=(-maxdepth 1 \( -name '*.jsonl' -o -name '*.notes.md' \))
    [ -n "$days" ] && args+=(-mtime "-$days")
    while IFS= read -r f; do
        [ -s "$f" ] || continue
        case "$f" in
            *.notes.md) name="${f##*/}"; name="${name%.notes.md}" ;;
            *)          name="${f##*/}"; name="${name%.jsonl}" ;;
        esac
        brain_sid_ok "$name" || continue
        case "$name" in _*) continue ;; esac
        [ -f "$ddir/$name.md" ] || continue
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        printf '%s\n' "$name"
    done < <(find "$jdir" "${args[@]}" 2>/dev/null)
}

doctrine_reviews() {
    local root="$1" rd rf d b state
    for rd in "$root"/*/; do
        [ -d "$rd" ] || continue; d="${rd%/}"; d="${d##*/}"
        for rf in "$rd"*.md; do
            [ -f "$rf" ] || continue; b="${rf##*/}"; b="${b%.md}"
            state=PENDIENTE
            [ -f "$rd.applied.$b" ] && [ ! "$rf" -nt "$rd.applied.$b" ] && state=aplicado
            printf '%s\t%s\t%s\t%s\n' "$d" "$b" "$state" "$rf"
        done
    done
}

capture_purge_expired() {
    local f
    find "$1" -type f -name '*.jsonl' -mtime "+$2" 2>/dev/null \
      | while IFS= read -r f; do p_secure_rm "$f"; done
}

brain_prune_older() {
    local f
    find "$1" -maxdepth 1 -type f -name "$2" -mtime "+$3" 2>/dev/null \
      | while IFS= read -r f; do rm -f "$f"; done
}

brain_prune_lines() {
    local f="$1" max="$2" keep="$3" n d t
    [ -s "$f" ] || return 0
    n="$(wc -l < "$f" 2>/dev/null | tr -dc '0-9')"
    [ -n "$n" ] && [ "$n" -gt "$max" ] || return 0
    case "$f" in */*) d="${f%/*}" ;; *) d=. ;; esac
    t="$(mktemp "$d/.prune.XXXXXX" 2>/dev/null)" || return 0
    if tail -n "$keep" "$f" > "$t" 2>/dev/null; then
        chmod 600 "$t" 2>/dev/null
        mv -f "$t" "$f" 2>/dev/null || rm -f "$t"
    else
        rm -f "$t"
    fi
    return 0
}

brain_ctx_emit() {
    [ "${OPENBRAIN_HOOK_CTX:-}" = 1 ] || return 1
    printf '%s' "$1"
    return 0
}

brain_nonce() {
    local n
    n="$( { command -v openssl >/dev/null 2>&1 && openssl rand -hex 8 2>/dev/null; } || true )"
    [ -n "$n" ] || n="$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    printf '%s\n' "${n:-$$-$RANDOM-$RANDOM}"
}

doctrine_blocks_render() {
    local nonce="$1" name f; shift
    for name in "$@"; do
        f="$OPENBRAIN_DOCTRINE_DIR/$name.md"
        [ -r "$f" ] || continue
        printf -- '--- BEGIN %s doctrine/%s.md ---\n' "$nonce" "$name"
        cat "$f"
        printf -- '\n--- END %s doctrine/%s.md ---\n\n' "$nonce" "$name"
    done
}

brain_state_dir()  { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/openbrain/doctrine"; }
brain_state_file() { printf '%s\n' "$(brain_state_dir)/$1.state"; }
brain_state_write() {
    local d t; d="$(dirname "$1")"
    ( umask 077; mkdir -p "$d" ) 2>/dev/null || return 1
    [ -L "$d" ] && return 1
    t="$(mktemp "$d/.tmp.XXXXXX" 2>/dev/null)" || return 1
    if cat > "$t" 2>/dev/null && [ -s "$t" ] && mv -f "$t" "$1" 2>/dev/null; then return 0; fi
    rm -f "$t"; return 1
}

brain_lock_acquire() {
    local dir="$1" pid_file="$1/pid" pid stale
    if mkdir "$dir" 2>/dev/null; then
        printf '%s' "$$" > "$pid_file"
        return 0
    fi
    if [ ! -d "${dir%/*}" ]; then
        ( umask 077; mkdir -p "${dir%/*}" ) 2>/dev/null
        if mkdir "$dir" 2>/dev/null; then
            printf '%s' "$$" > "$pid_file"
            return 0
        fi
    fi
    stale=0
    if [ ! -f "$pid_file" ]; then
        [ -n "$(find "$dir" -maxdepth 0 -mmin +60 2>/dev/null)" ] && stale=1
    else
        pid="$(cat "$pid_file" 2>/dev/null)"
        case "$pid" in
            ''|*[!0-9]*) stale=1 ;;
            *) kill -0 "$pid" 2>/dev/null || stale=1 ;;
        esac
    fi
    [ "$stale" = 1 ] || [ -n "$(find "$dir" -maxdepth 0 -mmin +360 2>/dev/null)" ] || return 1
    rm -f "$pid_file"
    rmdir "$dir" 2>/dev/null
    mkdir "$dir" 2>/dev/null || return 1
    printf '%s' "$$" > "$pid_file"
    return 0
}

brain_lock_release() {
    rm -f "$1/pid"
    rmdir "$1" 2>/dev/null
    return 0
}
