#!/usr/bin/env bash
set +e
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
PLUGIN_ROOT="$(cd "$(dirname "$_self")/.." 2>/dev/null && pwd -P)"
if [ -z "$PLUGIN_ROOT" ] || [ ! -r "$PLUGIN_ROOT/scripts/lib/common.sh" ]; then
    echo "openbrain/$(basename "$_self"): no resuelvo PLUGIN_ROOT desde $_self — hook inactivo" >&2
    exit 0
fi
# shellcheck source=../scripts/lib/common.sh
source "$PLUGIN_ROOT/scripts/lib/common.sh"

[ "$OPENBRAIN_CAPTURE_ENABLED" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=""; [ -t 0 ] || PAYLOAD="$(cat 2>/dev/null)"
SID=""; PROMPT=""; CWD=""
{ IFS= read -r -d '' SID; IFS= read -r -d '' PROMPT; IFS= read -r -d '' CWD; } < <(
  printf '%s' "$PAYLOAD" | jq -j '(.session_id // ""), "\u0000", (.prompt // ""), "\u0000", (.cwd // ""), "\u0000"' 2>/dev/null
)
[ -n "$SID" ] || exit 0
[ -n "$PROMPT" ] || exit 0
case "$PROMPT" in /*) exit 0 ;; esac
case "$PROMPT" in '<task-notification>'*) exit 0 ;; esac
brain_sid_ok "$SID" || exit 0

B='(^|[^[:alnum:]_])'; E='([^[:alnum:]_]|$)'
RX_CORR="${B}(no,|en realidad|te equivocas|est[áa] mal|no (es|est[áa]) (as[íi]|correcto|exacto|bien)|corrige|recuerda que|nunca (hagas|uses|pongas)|siempre (usa|haz)|prefiero|no vuelvas a|actually|that'?s wrong|(isn'?t|not) (right|correct)|incorrect[oa]?s?|remember that|never (do|use)|always use|i prefer)${E}"
RX_CONF="${B}(eso es|as[íi] s[íi]|perfecto, as[íi]|that'?s right)${E}|(^|[[:punct:]])[[:space:]]*(exacto|correcto|exactly)${E}"

kind=""; signal=""; RX_MATCHED=""
if   signal="$(printf '%s' "$PROMPT" | grep -Eio "$RX_CORR" | head -1)" && [ -n "$signal" ]; then kind=correction; RX_MATCHED="$RX_CORR"
elif signal="$(printf '%s' "$PROMPT" | grep -Eio "$RX_CONF" | head -1)" && [ -n "$signal" ]; then kind=confirmation; RX_MATCHED="$RX_CONF"
fi
[ -n "$kind" ] || exit 0

OUT="$OPENBRAIN_CAPTURE_DIR/$SID.jsonl"
if [ -f "$OUT" ] && [ "$(wc -l < "$OUT" | tr -d ' ')" -ge "$OPENBRAIN_CAPTURE_MAX_PER_SESSION" ]; then exit 0; fi

off="$(printf '%s' "$PROMPT" | grep -Eiob "$RX_MATCHED" | head -1 | cut -d: -f1)"
case "$off" in ''|*[!0-9]*) off="" ;; esac

if [ -n "$off" ] && [ "$off" -gt 1500 ]; then
    REDACTED="$(printf '%s' "$PROMPT" | tail -c +"$((off - 500 + 1))" | head -c 2000 | bash "$PLUGIN_ROOT/scripts/redact-before-haiku.sh" - 2>/dev/null)"
else
    REDACTED="$(printf '%s' "$PROMPT" | head -c 2000 | bash "$PLUGIN_ROOT/scripts/redact-before-haiku.sh" - 2>/dev/null)"
fi
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "openbrain/capture: candidato descartado (redaccion fallo o encontro secretos)" >&2
    exit 0
fi
[ -n "$REDACTED" ] || exit 0

( umask 077; mkdir -p "$OPENBRAIN_CAPTURE_DIR" ) || exit 0
chmod 700 "$OPENBRAIN_CAPTURE_DIR" 2>/dev/null

signal="$(printf '%s' "$signal" | sed -E 's/^[^[:alnum:]]+//; s/[^[:alnum:]]+$//')"
( umask 077
  jq -cn --arg ts "$(p_now_iso)" --arg cwd "$CWD" --arg kind "$kind" --arg signal "$signal" --arg text "$REDACTED" \
     '{ts:$ts,cwd:$cwd,kind:$kind,signal:$signal,text:$text}' >> "$OUT" ) 2>/dev/null
chmod 600 "$OUT" 2>/dev/null
exit 0
