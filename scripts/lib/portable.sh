#!/usr/bin/env bash

[ -n "${_OPENBRAIN_PORTABLE_LOADED:-}" ] && return 0
_OPENBRAIN_PORTABLE_LOADED=1
_P_FORCE="${OPENBRAIN_PORTABLE_FORCE:-}"

p_os() {
    case "$(uname -s 2>/dev/null)" in
        Darwin) printf 'darwin\n' ;;
        Linux)  printf 'linux\n' ;;
        *)      printf 'other\n' ;;
    esac
}

_p_pick() {
    if command -v "$1" >/dev/null 2>&1; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

_p_stat() {
    [ -n "${_P_STAT:-}" ] && return 0
    if [ "$_P_FORCE" = bsd ]; then _P_STAT=/usr/bin/stat; _P_STAT_GNU=0; return 0; fi
    _P_STAT="$(_p_pick gstat stat)"
    if "$_P_STAT" -c '%s' /dev/null >/dev/null 2>&1; then _P_STAT_GNU=1; else _P_STAT_GNU=0; fi
}

_p_date() {
    [ -n "${_P_DATE:-}" ] && return 0
    if [ "$_P_FORCE" = bsd ]; then _P_DATE=/bin/date; _P_DATE_GNU=0; return 0; fi
    _P_DATE="$(_p_pick gdate date)"
    if "$_P_DATE" -d @0 +%s >/dev/null 2>&1; then _P_DATE_GNU=1; else _P_DATE_GNU=0; fi
}

_p_b64() {
    [ -n "${_P_B64:-}" ] && return 0
    if [ "$_P_FORCE" = bsd ]; then _P_B64=/usr/bin/base64; _P_B64_GNU=0; return 0; fi
    _P_B64="$(_p_pick gbase64 base64)"
    if printf x | "$_P_B64" -w0 >/dev/null 2>&1; then _P_B64_GNU=1; else _P_B64_GNU=0; fi
}


p_stat_size()  { _p_stat; if [ "$_P_STAT_GNU" = 1 ]; then "$_P_STAT" -c '%s'  "$1" 2>/dev/null; else "$_P_STAT" -f '%z'  "$1" 2>/dev/null; fi; }
p_stat_mtime() { _p_stat; if [ "$_P_STAT_GNU" = 1 ]; then "$_P_STAT" -c '%Y'  "$1" 2>/dev/null; else "$_P_STAT" -f '%m'  "$1" 2>/dev/null; fi; }
p_stat_perms() { _p_stat; if [ "$_P_STAT_GNU" = 1 ]; then "$_P_STAT" -c '%a'  "$1" 2>/dev/null; else "$_P_STAT" -f '%Lp' "$1" 2>/dev/null; fi; }

p_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
p_date_iso() {
    [ -n "${1:-}" ] || { p_now_iso; return; }
    _p_date
    if [ "$_P_DATE_GNU" = 1 ]; then "$_P_DATE" -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; else "$_P_DATE" -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; fi
}
p_date_ymd() {
    [ -n "${1:-}" ] || { date -u +%Y-%m-%d; return; }
    _p_date
    if [ "$_P_DATE_GNU" = 1 ]; then "$_P_DATE" -u -d "@$1" +%Y-%m-%d; else "$_P_DATE" -u -r "$1" +%Y-%m-%d; fi
}
p_epoch_to_ymd() { p_date_ymd "$1"; }
p_date_to_epoch() {
    local ep
    _p_date
    if [ "$_P_DATE_GNU" = 1 ]; then
        ep="$("$_P_DATE" -u -d "$1" +%s 2>/dev/null)" || return 0
        [ "$("$_P_DATE" -u -d "@$ep" +%Y-%m-%d 2>/dev/null)" = "$1" ] && printf '%s\n' "$ep"
    else
        ep="$("$_P_DATE" -u -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null)" || return 0
        [ "$("$_P_DATE" -u -r "$ep" +%Y-%m-%d 2>/dev/null)" = "$1" ] && printf '%s\n' "$ep"
    fi
}
p_epoch_ago() {
    local n="$1" u="$2" mult
    case "$u" in s) mult=1 ;; m) mult=60 ;; h) mult=3600 ;; d) mult=86400 ;; *) return 1 ;; esac
    printf '%s\n' $(( $(date +%s) - n * mult ))
}

p_replace_keep_mode() {
    local target="$1" tmp="$2" mode
    mode="$(p_stat_perms "$target")"
    [ -n "$mode" ] && chmod "$mode" "$tmp"
    mv -f "$tmp" "$target"
}

p_base64_oneline() { _p_b64; if [ "$_P_B64_GNU" = 1 ]; then "$_P_B64" -w0; else "$_P_B64" | tr -d '\n'; fi; }

p_abspath() {
    realpath "$1" 2>/dev/null && return 0
    readlink -f "$1" 2>/dev/null && return 0
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

p_secure_rm() {
    local f wipe
    wipe=""
    command -v shred >/dev/null 2>&1 && wipe="shred"
    for f in "$@"; do
        [ -e "$f" ] || continue
        case "$(p_os)" in
            darwin) rm -P -f "$f" 2>/dev/null || rm -f "$f" ;;
            linux)  if [ -n "$wipe" ]; then "$wipe" -u "$f" 2>/dev/null || rm -f "$f"; else rm -f "$f"; fi ;;
            *)      rm -f "$f" ;;
        esac
    done
}
