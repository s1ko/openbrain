#!/usr/bin/env bash

[ -n "${_OPENBRAIN_CONFIG_LOADED:-}" ] && return 0
_OPENBRAIN_CONFIG_LOADED=1

OPENBRAIN_CONFIG_FILE="${OPENBRAIN_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/claude/openbrain.env}"

_brain_expand_home() {
    local v="$1"
    case "$v" in
        '~'/*) v="$HOME/${v#\~/}" ;;
        '~')   v="$HOME" ;;
        \$HOME/*) v="$HOME/${v#\$HOME/}" ;;
        \$HOME)   v="$HOME" ;;
    esac
    printf '%s' "$v"
}

_brain_load_file() {
    local f="$1" line k v
    [ -r "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|\#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
        case "$k" in
            OPENBRAIN_[A-Z0-9_]*) ;;
            *) continue ;;
        esac
        case "$k" in *[!A-Z0-9_]*) continue ;; esac
        if declare -p "$k" >/dev/null 2>&1; then continue; fi
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        case "$v" in
            \"*\") v="${v#\"}"; v="${v%\"}" ;;
            \'*\') v="${v#\'}"; v="${v%\'}" ;;
        esac
        v="$(_brain_expand_home "$v")"
        printf -v "$k" '%s' "$v"
        export "${k?}"
    done < "$f"
}

_brain_load_file "$OPENBRAIN_CONFIG_FILE"

: "${XDG_CACHE_HOME:=$HOME/.cache}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"

: "${OPENBRAIN_REPO_ROOT:=$HOME/knowledge}"
: "${OPENBRAIN_WIKI_ROOT:=$OPENBRAIN_REPO_ROOT/wiki}"
: "${OPENBRAIN_COLLECTION=openbrain}"
: "${OPENBRAIN_OTHER_COLLECTIONS:=}"
: "${OPENBRAIN_EVAL_GOLDEN:=$OPENBRAIN_REPO_ROOT/.eval/golden.json}"
: "${OPENBRAIN_EVAL_METRICS:=$OPENBRAIN_REPO_ROOT/.eval/metrics.log}"
: "${OPENBRAIN_EVAL_MAX_AGE_DAYS:=30}"

: "${OPENBRAIN_MEMORY_ROOT:=$HOME/.claude/projects}"
: "${OPENBRAIN_GLOBAL_MEMORY:=$OPENBRAIN_MEMORY_ROOT/_global/memory}"
: "${OPENBRAIN_HMAC_KEY:=${XDG_CONFIG_HOME:-$HOME/.config}/claude/memory.hmac}"
: "${OPENBRAIN_STALE_DAYS:=60}"
: "${OPENBRAIN_MEMORY_INDEX_MAX:=165}"

: "${OPENBRAIN_DOCTRINE_DIR:=$HOME/.claude/doctrine}"
: "${OPENBRAIN_DOCTRINE_TTL:=43200}"
: "${OPENBRAIN_REFRESH_ALLOWLIST:=$HOME/.claude/refresh-allowlist}"
: "${OPENBRAIN_TRIGGERS_CONF:=$XDG_CACHE_HOME/openbrain/triggers.conf}"
: "${OPENBRAIN_REVIEW_SKIP:=0}"
: "${OPENBRAIN_REVIEW_MAX_TURNS:=30}"
: "${OPENBRAIN_OPERATOR_CONTEXT:=operador técnico}"
: "${OPENBRAIN_CODE_REPO:=}"

: "${OPENBRAIN_CAPTURE_ENABLED:=1}"
: "${OPENBRAIN_CAPTURE_DIR:=$XDG_STATE_HOME/openbrain/candidates}"
: "${OPENBRAIN_CAPTURE_TTL_DAYS:=14}"
: "${OPENBRAIN_CAPTURE_MAX_PER_SESSION:=40}"

: "${OPENBRAIN_SIGN_ON_STOP:=1}"
: "${OPENBRAIN_SIGN_ON_STOP_MAX:=25}"

: "${OPENBRAIN_BACKUP_AGE:=}"
: "${OPENBRAIN_BACKUP_GPG:=}"
: "${OPENBRAIN_BACKUP_DIR:=$HOME/.claude/backups/memory}"
: "${OPENBRAIN_BACKUP_KEEP:=30}"
: "${OPENBRAIN_BACKUP_SIGN_KEY:=}"
: "${OPENBRAIN_BACKUP_AGE_IDENTITY:=${XDG_CONFIG_HOME:-$HOME/.config}/claude/memory-backup-key.txt}"

export OPENBRAIN_REPO_ROOT OPENBRAIN_WIKI_ROOT OPENBRAIN_COLLECTION OPENBRAIN_OTHER_COLLECTIONS \
       OPENBRAIN_EVAL_GOLDEN OPENBRAIN_EVAL_METRICS OPENBRAIN_EVAL_MAX_AGE_DAYS \
       OPENBRAIN_MEMORY_ROOT OPENBRAIN_GLOBAL_MEMORY OPENBRAIN_HMAC_KEY OPENBRAIN_STALE_DAYS OPENBRAIN_MEMORY_INDEX_MAX \
       OPENBRAIN_DOCTRINE_DIR OPENBRAIN_DOCTRINE_TTL OPENBRAIN_TRIGGERS_CONF OPENBRAIN_REVIEW_SKIP OPENBRAIN_REVIEW_MAX_TURNS OPENBRAIN_REFRESH_ALLOWLIST \
       OPENBRAIN_OPERATOR_CONTEXT OPENBRAIN_CODE_REPO \
       OPENBRAIN_CAPTURE_ENABLED OPENBRAIN_CAPTURE_DIR OPENBRAIN_CAPTURE_TTL_DAYS OPENBRAIN_CAPTURE_MAX_PER_SESSION \
       OPENBRAIN_SIGN_ON_STOP OPENBRAIN_SIGN_ON_STOP_MAX \
       OPENBRAIN_BACKUP_AGE OPENBRAIN_BACKUP_GPG OPENBRAIN_BACKUP_DIR OPENBRAIN_BACKUP_KEEP OPENBRAIN_BACKUP_SIGN_KEY OPENBRAIN_BACKUP_AGE_IDENTITY

brain_config_dump() {
    local k
    for k in $(compgen -v OPENBRAIN_ | sort); do
        case "$k" in OPENBRAIN_CONFIG_FILE) continue ;; esac
        printf '%s=%s\n' "$k" "${!k}"
    done
}
