#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"; H="$REPO_ROOT/hooks"

setup() {
    setup_fake_home
    make_hmac_key
    # Memoria en una raiz NO estandar, declarada por openbrain.env
    export ALT="$BATS_TEST_TMPDIR/alt-projects"
    printf 'OPENBRAIN_MEMORY_ROOT=%s\n' "$ALT" > "$OPENBRAIN_CONFIG_FILE"
    mkdir -p "$ALT/proj-x/memory"
    cat > "$ALT/proj-x/memory/m.md" <<'EOF'
---
name: m
description: d
type: project
---
x
EOF
    printf '# MEMORY.md\n- [m](m.md) - x\n' > "$ALT/proj-x/memory/MEMORY.md"
}

@test "lint-memory sin \$1 usa OPENBRAIN_MEMORY_ROOT" {
    run bash "$S/lint-memory.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj-x"* ]] || [[ "$output" == *"$ALT"* ]]
}

@test "verify-memory-hmac sin \$1 firma bajo OPENBRAIN_MEMORY_ROOT" {
    run bash "$S/verify-memory-hmac.sh" "" sign
    [ "$status" -eq 0 ]
    [ -f "$ALT/proj-x/memory/m.md.hmac" ]
}

@test "update-memory-index y memory-metrics sin \$1 usan OPENBRAIN_MEMORY_ROOT" {
    run bash "$S/update-memory-index.sh"; [ "$status" -eq 0 ]
    run bash "$S/memory-metrics.sh";     [ "$status" -eq 0 ]; [[ "$output" == *"proj-x"* ]]
}

@test "load-global-memory lee OPENBRAIN_GLOBAL_MEMORY" {
    # basename debe ser "memory": resolve_memdirs (common.sh) solo trata la
    # raiz como memdir directo cuando se llama asi; si no, busca */memory.
    G="$BATS_TEST_TMPDIR/global-mem/memory"; mkdir -p "$G"
    printf 'OPENBRAIN_GLOBAL_MEMORY=%s\n' "$G" >> "$OPENBRAIN_CONFIG_FILE"
    cat > "$G/regla.md" <<'EOF'
---
name: regla
description: d
type: feedback
---
REGLA-SINTETICA-42
EOF
    printf '# MEMORY.md\n- [regla](regla.md) - x\n' > "$G/MEMORY.md"
    bash "$S/verify-memory-hmac.sh" "$G" sign >/dev/null
    run bash -c "echo '{}' | bash '$H/load-global-memory.sh'"
    [ "$status" -eq 0 ]
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"REGLA-SINTETICA-42"* ]]
}

@test "verify-memory (hook) firma un memory/ bajo OPENBRAIN_MEMORY_ROOT" {
    payload="$(jq -cn --arg p "$ALT/proj-x/memory/m.md" '{tool_name:"Write",tool_input:{file_path:$p}}')"
    run bash -c "printf '%s' '$payload' | bash '$H/verify-memory.sh'"
    [ "$status" -eq 0 ]
    [ -f "$ALT/proj-x/memory/m.md.hmac" ]
}

@test "load-global-memory falla abierto si falta common.sh" {
    # R20: el hook nunca debe bloquear la sesion. Se copia SOLO el hook (sin
    # scripts/lib/ al lado) a un arbol nuevo bajo hooks/, para que
    # PLUGIN_ROOT/scripts/lib/common.sh no exista y se ejercite el guard.
    local d="$BATS_TEST_TMPDIR/no-lib-hook"
    mkdir -p "$d/hooks"
    cp "$H/load-global-memory.sh" "$d/hooks/"
    run bash -c "bash '$d/hooks/load-global-memory.sh' </dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook inactivo"* ]]
    [[ "$output" != *"{"* ]]
}
