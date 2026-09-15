#!/usr/bin/env bash
[ -n "${_OPENBRAIN_TRIGGERS_LOADED:-}" ] && return 0
_OPENBRAIN_TRIGGERS_LOADED=1

TRIG_KIND=(); TRIG_PAT=(); TRIG_BLOCK=(); TRIG_ACTIVE=()

triggers_load() {
    local conf="${1:-$OPENBRAIN_TRIGGERS_CONF}" k p b
    TRIG_KIND=(); TRIG_PAT=(); TRIG_BLOCK=()
    [ -r "$conf" ] || return 0
    while IFS=$'\t' read -r k p b; do
        [ -n "$k" ] && [ -n "$p" ] && [ -n "$b" ] || continue
        TRIG_KIND+=("$k"); TRIG_PAT+=("$p"); TRIG_BLOCK+=("$b")
    done < "$conf"
}

triggers_stale() {
    local dir="${1:-$OPENBRAIN_DOCTRINE_DIR}" out="${2:-$OPENBRAIN_TRIGGERS_CONF}" f
    [ -f "$out" ] || return 0
    for f in "$dir"/*.md; do
        [ "$f" -nt "$out" ] && return 0
    done
    return 1
}

triggers_touched() {
    local dir="${1:-$OPENBRAIN_DOCTRINE_DIR}" out="${2:-$OPENBRAIN_TRIGGERS_CONF}"
    triggers_stale "$dir" "$out" && return 0
    [ "$dir" -nt "$out" ]
}

triggers_compile() {
    local dir="${1:-$OPENBRAIN_DOCTRINE_DIR}" out="${2:-$OPENBRAIN_TRIGGERS_CONF}" f block tmp
    [ -d "$dir" ] || return 1
    case "$out" in */*) mkdir -p "${out%/*}" || return 1 ;; esac
    tmp="$(mktemp "$out.XXXXXX")" || return 1
    for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        block="${f##*/}"; block="${block%.md}"
        awk -v block="$block" '
            NR==1 { fm = ($0 == "---"); next }
            !fm { exit }
            /^---$/ { exit }
            /^triggers:[[:space:]]*$/ { t=1; next }
            t && /^[^[:space:]]/ { t=0 }
            !t { next }
            /^[[:space:]]+[a-z]+:[[:space:]]*$/ { k=$1; sub(/:$/,"",k); kind=k; next }
            /^[[:space:]]+manual:/ { kind=""; next }
            /^[[:space:]]*#/ { next }
            kind != "" && /^[[:space:]]*-[[:space:]]*/ {
                line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line); sub(/[[:space:]]*#.*$/,"",line)
                gsub(/^"|"$/,"",line); gsub(/^\047|\047$/,"",line)
                gsub(/\t/," ",line)
                if (line=="") next
                k = (kind=="files") ? "file" : kind
                printf "%s\t%s\t%s\n", k, line, block
            }
        ' "$f"
    done | sort -u > "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$out"
}

_trig_flat() {
    local g="$1"
    g="${g//\*\*\//*/}"
    while [[ "$g" == *'**'* ]]; do g="${g//\*\*/*}"; done
    printf '%s\n' "$g"
}

# shellcheck disable=SC2254
triggers_active() {
    local mode="$1" cwd="$2" branch="$3" tool="$4" file="${5:-}"
    local base='' i k p b g f z esc hit seen=' '
    TRIG_ACTIVE=()
    [ -n "$file" ] && base="${file##*/}"
    for (( i=0; i<${#TRIG_KIND[@]}; i++ )); do
        b="${TRIG_BLOCK[$i]}"
        case "$seen" in *" $b "*) continue ;; esac
        k="${TRIG_KIND[$i]}"; p="${TRIG_PAT[$i]}"; hit=0
        case "$k" in
            cwd)
                g="$p"
                case "$g" in '~'/*) g="$HOME/${g#\~/}" ;; esac
                g="$(_trig_flat "$g")"
                case "$cwd" in $g) hit=1 ;; esac
                case "$g" in */\*) case "$cwd" in ${g%/\*}) hit=1 ;; esac ;; esac ;;
            branch) case "$branch" in $p) hit=1 ;; esac ;;
            mcp)    case "$tool" in $p) hit=1 ;; esac ;;
            env)
                case "$p" in ''|[0-9]*|*[!A-Z0-9_]*) ;; *) if [ -n "${!p:-}" ]; then hit=1; fi ;; esac ;;
            file|watch)
                if [ "$mode" = watch ]; then
                    [ -n "$file" ] || continue
                    case "$p" in
                        */*)
                            g="$(_trig_flat "$p")"; f="$(_trig_flat "${p//\*\*\//}")"
                            case "$file" in $g|*/$g|$f|*/$f) hit=1 ;; esac ;;
                        *)   case "$base" in $p) hit=1 ;; esac ;;
                    esac
                elif [ "$k" = file ]; then
                    case "$p" in
                        *'**'*)
                            g="$(_trig_flat "$p")"; z="$(_trig_flat "${p//\*\*\//}")"
                            for f in "$cwd"/$z; do [ -e "$f" ] && { hit=1; break; }; done
                            if [ "$hit" = 0 ]; then
                                esc="$(printf '%s' "$cwd" | sed 's/[][*?\\]/\\&/g')"
                                [ -n "$(find "$cwd" -path "$esc/$g" -print 2>/dev/null | head -1)" ] && hit=1
                            fi ;;
                        *) for f in "$cwd"/$p; do [ -e "$f" ] && { hit=1; break; }; done ;;
                    esac
                fi ;;
        esac
        [ "$hit" = 1 ] || continue
        seen="$seen$b "
        [ -f "$OPENBRAIN_DOCTRINE_DIR/$b.md" ] && TRIG_ACTIVE+=("$b")
    done
}
