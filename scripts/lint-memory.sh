#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT="${1:-$OPENBRAIN_MEMORY_ROOT}"
SEC_FAIL=0
STYLE_FAIL=0

check_frontmatter() {
    local f="$1"
    local lines=()
    while IFS= read -r _l; do lines+=( "$_l" ); done < <(awk '
        NR==1 { open = ($0 == "---") ? 1 : 0 }
        /^---$/ { c++; if (c == 2) { closed = 1; exit }; next }
        c == 1 && /^name:/ { name = 1 }
        c == 1 && /^description:/ { desc = 1 }
        c == 1 && /^metadata:[[:space:]]*$/ { meta = 1; next }
        c == 1 && /^[^[:space:]]/ { meta = 0 }
        c == 1 && (/^type:/ || (meta && /^[[:space:]]+type:/)) {
            t = $0
            sub(/^[[:space:]]*type:[[:space:]]*/, "", t)
            gsub(/["\047]/, "", t)
            sub(/[[:space:]].*$/, "", t)
            type = t
        }
        c == 1 && $0 !~ /^[[:space:]]*$/ && \
                  $0 !~ /^[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*:/ && \
                  $0 !~ /^(name|description|type|metadata|originSessionId|modified|reviewed):/ { malformed = 1 }
        END {
            print (open ? 1 : 0)
            print (closed ? 1 : 0)
            print (malformed ? 1 : 0)
            print (name ? 1 : 0)
            print (desc ? 1 : 0)
            print type
        }
    ' "$f")
    if [[ "${lines[0]:-0}" != 1 ]]; then
        red "  FAIL frontmatter: $f does not start with ---"
        SEC_FAIL=1
        return
    fi
    if [[ "${lines[1]:-0}" != 1 ]]; then
        red "  FAIL frontmatter: $f has no closing ---"
        SEC_FAIL=1
        return
    fi
    if [[ "${lines[2]:-0}" == 1 ]]; then
        red "  FAIL frontmatter: $f has non-frontmatter content before the closing ---"
        SEC_FAIL=1
        return
    fi
    [[ "${lines[3]:-0}" == 1 ]] || { red "  FAIL frontmatter: $f missing field 'name'"; SEC_FAIL=1; }
    [[ "${lines[4]:-0}" == 1 ]] || { red "  FAIL frontmatter: $f missing field 'description'"; SEC_FAIL=1; }
    case "${lines[5]:-}" in
        user|feedback|project|reference) ;;
        *) red "  FAIL frontmatter: $f has invalid type '${lines[5]:-}'"; SEC_FAIL=1 ;;
    esac
}

check_secrets_dir() {
    local d="$1"
    if ! command -v gitleaks >/dev/null 2>&1; then
        red "  FAIL gitleaks not installed: cannot verify secrets under $d"
        SEC_FAIL=1
        return 0
    fi
    local out gl_rc=0
    out="$(gitleaks detect --no-banner --no-git --exit-code 2 -v -s "$d" --redact 2>&1)" || gl_rc=$?
    if (( gl_rc == 0 )); then
        return 0
    fi
    if (( gl_rc == 2 )); then
        red "  FAIL gitleaks under $d"
        printf '%s\n' "$out" | grep -E '^[[:space:]]*(Finding|File|Line):' | sed 's/^/    /' || true
    else
        red "  FAIL gitleaks execution error under $d (exit $gl_rc)"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
    SEC_FAIL=1
}

# shellcheck disable=SC2088
FORBIDDEN_PATTERNS=(
    '~/\.ssh' '/\.ssh/' 'id_rsa' 'id_ed25519'
    '~/\.gnupg' '/\.gnupg/' '~/\.aws' '/\.aws/' '~/\.kube' '/\.kube/' '~/\.docker' '/\.docker/'
    'password-store' 'gopass' 'keepassxc'
    '\.zsh_history' '\.bash_history' '\.python_history'
    'SSH_AUTH_SOCK' 'GPG_AGENT_INFO'
    'credentials\.json' 'settings\.local\.json' 'audit\.log'
    '\.netrc' '\.pgpass' '\.npmrc'
)
FORBIDDEN_ALT="$(IFS='|'; echo "${FORBIDDEN_PATTERNS[*]}")"

check_forbidden_paths() {
    local f="$1"
    grep -qE "$FORBIDDEN_ALT" "$f" || return 0
    local p
    for p in "${FORBIDDEN_PATTERNS[@]}"; do
        if grep -qE "$p" "$f"; then
            yellow "  WARN forbidden path pattern '$p' in $f"
            STYLE_FAIL=1
        fi
    done
}

check_index_lines() {
    local f="$1"
    local max="$OPENBRAIN_MEMORY_INDEX_MAX"
    LC_ALL=C awk -v max="$max" '{ s=$0; cont=gsub(/[\200-\277]/,"",s); if (length($0)-cont > max) { printf "  STYLE %s:%d line > %d chars\n", FILENAME, NR, max; rc=1 } } END{exit rc+0}' "$f" || STYLE_FAIL=1
}

check_dangling() {
    local f="$1"
    [[ -e "$f" ]] && return 0
    printf '  STYLE %s dangling symlink → %s\n' "$f" "$(readlink "$f")"
    STYLE_FAIL=1
}

check_index_targets() {
    local f="$1" d line target
    d="$(dirname "$f")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        target="$(memory_index_link_target "$line")" || continue
        case "$target" in */*|'') continue ;; esac
        [[ -e "$d/$target" ]] && continue
        yellow "  WARN index entry points to a missing file: $target in $f"
        STYLE_FAIL=1
    done < "$f"
}

lint_one() {
    local f="$1"
    case "${f##*/}" in
        MEMORY.md) check_index_lines "$f"; check_index_targets "$f" ;;
        *)         check_frontmatter "$f" ;;
    esac
    check_forbidden_paths "$f"
}

lint_dir() {
    local memdir="$1"
    [[ -d "$memdir" ]] || return 0
    echo
    echo "→ $memdir"
    shopt -s nullglob dotglob
    for f in "$memdir"/*.md "$memdir"/*.md.hmac; do
        [[ -L "$f" ]] && check_dangling "$f"
    done
    for f in "$memdir"/*.md; do
        [[ -L "$f" ]] && continue
        lint_one "$f"
    done
    check_secrets_dir "$memdir"
}

lint_file() {
    local f="$1"
    echo
    echo "→ $f"
    lint_one "$f"
    check_secrets_dir "$f"
}

green "Linting memory files under $ROOT"
if [[ -f "$ROOT" && ! -L "$ROOT" && "$ROOT" == *.md ]]; then
    lint_file "$ROOT"
else
    memdirs=()
    while IFS= read -r _d; do memdirs+=( "$_d" ); done < <(resolve_memdirs "$ROOT")
    if [[ ${#memdirs[@]} -eq 0 ]]; then
        red "lint-memory: no memory directories found under $ROOT"
        exit 2
    fi
    for memdir in "${memdirs[@]}"; do
        lint_dir "$memdir"
    done
fi

if [[ "$SEC_FAIL" -ne 0 ]]; then
    red "lint-memory: SECURITY FAIL (signing blocked)"
    exit 2
fi
if [[ "$STYLE_FAIL" -ne 0 ]]; then
    yellow "lint-memory: STYLE FAIL (signing allowed)"
    exit 1
fi
green "lint-memory: OK"
