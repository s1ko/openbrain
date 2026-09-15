# Cargado por cada .bats con `load helpers`.
# Todo test corre con HOME redirigido: jamás toca ~/.claude ni ~/knowledge reales.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export REPO_ROOT

setup_fake_home() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_STATE_HOME="$HOME/.local/state"
    export XDG_CONFIG_HOME="$HOME/.config"
    export GIT_CEILING_DIRECTORIES="${BATS_TEST_TMPDIR%/*}"
    mkdir -p "$HOME/.claude/projects" "$HOME/.config/claude" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
    # Sin openbrain.env: los tests parten de defaults salvo que creen uno.
    export OPENBRAIN_CONFIG_FILE="$HOME/.config/claude/openbrain.env"
}

# Crea una clave HMAC válida (600) en la ruta por defecto.
make_hmac_key() {
    install -m 600 /dev/null "$HOME/.config/claude/memory.hmac"
    head -c 32 /dev/urandom | base64 > "$HOME/.config/claude/memory.hmac"
}

# Memoria sintética: <slug>/memory/<name>.md con frontmatter válido.
make_memory() {
    local slug="$1" name="$2" type="${3:-project}"
    local d="$HOME/.claude/projects/$slug/memory"
    mkdir -p "$d"
    cat > "$d/$name.md" <<EOF
---
name: $name
description: memoria sintética de test
type: $type
---

Contenido sintético. Ningún dato real.
EOF
    [ -f "$d/MEMORY.md" ] || printf '# MEMORY.md\n\n' > "$d/MEMORY.md"
    printf -- '- [%s](%s.md) — test\n' "$name" "$name" >> "$d/MEMORY.md"
}

# JSON de entrada de hook, como lo envía Claude Code por stdin.
hook_json() {
    # $1 event, $2 session_id, resto pares clave=valor (string)
    local ev="$1" sid="$2"; shift 2
    local args=(--arg hook_event_name "$ev" --arg session_id "$sid" --arg cwd "$PWD")
    local kv
    for kv in "$@"; do args+=(--arg "${kv%%=*}" "${kv#*=}"); done
    jq -cn "${args[@]}" '$ARGS.named'
}

# Skip si el filesystem rechaza nombres con bytes no UTF-8 (APFS/HFS+ dan EILSEQ).
require_non_utf8_names() {
    local probe="$BATS_TEST_TMPDIR/$(printf 'probe-\377')"
    : > "$probe" 2>/dev/null || skip "el filesystem rechaza nombres no UTF-8"
    rm -f "$probe"
}

# Transcript sintético de Claude Code (JSONL): 2 Write, 1 Bash con error.
make_transcript() {
    local f="$1"
    cat > "$f" <<'JSONL'
{"type":"summary","summary":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/p/a.md"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"boom"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Write","input":{"file_path":"/p/b.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Edit","input":{"file_path":"/p/a.md"}}]}}
no-es-json
JSONL
}
