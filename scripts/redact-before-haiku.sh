#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:--}"
LOG_DIR="${HOME}/.claude/logs"
LOG="${LOG_DIR}/redact-before-haiku.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true
( umask 077; : >> "$LOG" ) 2>/dev/null || true

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_event() {
    jq -cn --arg ts "$now" --arg input "$INPUT" \
        "{ts:\$ts,event:\"redact-before-haiku\",input:\$input,$1}" >> "$LOG" 2>/dev/null || true
}

if [[ "$INPUT" == '-' ]]; then
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    cat > "$tmp"
    src="$tmp"
else
    if [[ -L "$INPUT" ]]; then
        echo "redact-before-haiku: refusing symlink input (fail closed)" >&2
        exit 1
    fi
    src="$INPUT"
fi

if ! command -v gitleaks >/dev/null 2>&1; then
    log_event 'gitleaks_ran:0,aborted:true,reason:"gitleaks-absent"'
    echo "redact-before-haiku: gitleaks not installed — refusing to emit (fail closed)" >&2
    exit 1
fi
gl_rc=0
gitleaks detect --no-banner --no-git --exit-code 2 -s "$src" >/dev/null 2>&1 || gl_rc=$?
if (( gl_rc == 2 )); then
    log_event "gitleaks_ran:1,gitleaks_findings:1,gitleaks_exit:$gl_rc,aborted:true"
    echo "redact-before-haiku: gitleaks flagged secrets; aborting (fail closed)" >&2
    exit 1
elif (( gl_rc != 0 )); then
    log_event "gitleaks_ran:1,gitleaks_findings:0,gitleaks_error:1,gitleaks_exit:$gl_rc,aborted:true"
    echo "redact-before-haiku: gitleaks execution error (exit ${gl_rc}); aborting (fail closed)" >&2
    exit 1
fi

awk '
    armed { sub(/[^[:space:]].*$/, "[REDACTED:cred]"); armed = 0 }
    {
        low = tolower($0)
        if (low ~ /^[[:space:]]*-?[[:space:]]*"?(api[_-]?key|apikey|secret[_-]?key|private[_-]?key|access[_-]?key|signing[_-]?key|encryption[_-]?key|master[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|client[_-]?secret|app[_-]?secret|secret|token|passwd|password|pwd)"?[[:space:]]*[:=][[:space:]]*$/)
            armed = 1
        print
    }
' "$src" | sed -E \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/{
/-----BEGIN [A-Z ]*PRIVATE KEY-----/!d
s/.*/[REDACTED:private-key]/
}' \
    -e 's/(ghp|gho|ghs|ghr|ghu|github_pat)_[A-Za-z0-9_]{20,}/[REDACTED:gh-token]/g' \
    -e 's/xox[abprse]-[A-Za-z0-9-]{10,}/[REDACTED:slack]/g' \
    -e 's#https://hooks\.slack\.com/services/[A-Za-z0-9/]+#[REDACTED:slack-webhook]#g' \
    -e 's/(AKIA|ASIA)[0-9A-Z]{16}/[REDACTED:aws-akid]/g' \
    -e 's/(aws_secret_access_key|AWS_SECRET_ACCESS_KEY)([[:space:]]*[:=][[:space:]]*)"?[A-Za-z0-9\/+]{40}"?/\1\2[REDACTED:aws-secret]/g' \
    -e 's/AIza[0-9A-Za-z_-]{35}/[REDACTED:gcp-key]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED:jwt]/g' \
    -e 's/([Bb]earer|[Bb]asic)[[:space:]]+[A-Za-z0-9._~+\/=-]{12,}/\1 [REDACTED:auth]/g' \
    -e 's/((api[_-]?key|apikey|secret[_-]?key|private[_-]?key|access[_-]?key|signing[_-]?key|encryption[_-]?key|master[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|client[_-]?secret|app[_-]?secret|client[_-]?id|secret|token|passwd|password|pwd)[[:space:]]*[:=][[:space:]]*)"?[^",;]{6,}"?/\1[REDACTED:cred]/gI' \
    -e 's/((api[_-]?key|apikey|secret[_-]?key|private[_-]?key|access[_-]?key|signing[_-]?key|encryption[_-]?key|master[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|client[_-]?secret|app[_-]?secret)[[:space:]]+)[^[:space:]"'"'"']{6,}/\1[REDACTED:cred]/gI' \
    -e 's#(postgres|postgresql|mysql|mongodb|redis|amqp)://[^[:space:]"'"'"']+#\1://[REDACTED:dburi]#g' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*)://[^/[:space:]"'"'"'@]+@#\1://[REDACTED:uri-cred]@#g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[REDACTED:email]/g' \
    -e 's/(ES|PT|FR|DE|GB|IT|NL)[ ]?[0-9]{2}[ ]?([0-9]{4}[ ]?){4,7}[0-9]{0,4}/[REDACTED:iban]/gI' \
    -e 's/[0-9]{4}[ -]?[0-9]{6}[ -]?[0-9]{5}/[REDACTED:card]/g' \
    -e 's/[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{1,7}/[REDACTED:card]/g' \
    -e 's/[XYZ][0-9]{7}[ -]?[A-HJ-NP-TV-Z]/[REDACTED:nie]/gI' \
    -e 's/[0-9]{8}[ -]?[A-HJ-NP-TV-Z]/[REDACTED:dni]/gI' \
    -e 's/(\+34[ ]?)?[6789][0-9]{2}[ .-]?[0-9]{3}[ .-]?[0-9]{3}/[REDACTED:phone]/g'

log_event 'gitleaks_ran:1,gitleaks_findings:0'
