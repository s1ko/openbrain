#!/usr/bin/env bats
load helpers

B="$REPO_ROOT/bin/openbrain"

setup() { setup_fake_home; }

@test "openbrain sin args / help: uso, rc 2 / 0" {
    run bash "$B"
    [ "$status" -eq 2 ]
    [[ "$output" == *"uso: openbrain"* ]]
    run bash "$B" help
    [ "$status" -eq 0 ]
}

@test "openbrain help documenta --json y --lex de recall" {
    run bash "$B" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--json"* ]]
    [[ "$output" == *"--lex"* ]]
}

@test "openbrain version lee plugin.json" {
    run bash "$B" version
    [ "$output" = "openbrain $(jq -r .version "$REPO_ROOT/.claude-plugin/plugin.json")" ]
}

@test "openbrain comando desconocido: rc 2" {
    run bash "$B" nope
    [ "$status" -eq 2 ]
}

@test "cada subcomando mapea a un script existente y ejecutable" {
    for c in doctor recall capture eval review install triggers; do
        run bash "$B" --which "$c"
        [ "$status" -eq 0 ]
        [ -x "$output" ]
    done
    for op in lint verify sign index metrics mark-reviewed backup restore dedupe redact; do
        run bash "$B" --which "memory:$op"
        [ "$status" -eq 0 ]
        [ -x "$output" ]
    done
}

@test "openbrain funciona via symlink (resuelve su raiz real)" {
    ln -s "$B" "$BATS_TEST_TMPDIR/openbrain"
    run bash "$BATS_TEST_TMPDIR/openbrain" version
    [ "$status" -eq 0 ]
    [[ "$output" == openbrain* ]]
}

@test "openbrain memory sign pide confirmacion salvo --yes" {
    run bash -c "echo n | bash '$B' memory sign"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cancelado"* ]]
}

@test "openbrain memory sign con stdin cerrado se cancela con mensaje" {
    run bash -c "bash '$B' memory sign </dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cancelado"* ]]
}

@test "openbrain memory op desconocida: rc 2" {
    run bash "$B" memory nope
    [ "$status" -eq 2 ]
    [[ "$output" == *"desconocida"* ]]
}

@test "--which sin argumento o con comando desconocido: rc 2 y mensaje" {
    run bash "$B" --which;         [ "$status" -eq 2 ]; [[ "$output" == *"uso: openbrain --which"* ]]
    run bash "$B" --which nada;    [ "$status" -eq 2 ]; [[ "$output" == *"desconocido"* ]]
}

@test "bin/openbrain resuelve su raiz a traves de un symlink RELATIVO" {
    mkdir -p "$HOME/l"
    rel="$(python3 -c "import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))" "$REPO_ROOT/bin/openbrain" "$HOME/l")"
    ln -s "$rel" "$HOME/l/openbrain"
    run bash "$HOME/l/openbrain" --which doctor
    [ "$status" -eq 0 ]; [ "$output" = "$REPO_ROOT/scripts/openbrain-doctor.sh" ]
}

@test "memory dedupe sin --apply no pide confirmacion; con --apply y stdin EOF cancela" {
    run bash "$B" memory dedupe </dev/null
    [[ "$output" != *"continuar"* ]]
    run bash "$B" memory dedupe --apply </dev/null
    [ "$status" -eq 1 ]; [[ "$output" == *"cancelado"* ]]
}

@test "memory dedupe con DEDUPE_APPLY=1 en el entorno tambien pide confirmacion" {
    export DEDUPE_APPLY=1
    run bash "$B" memory dedupe </dev/null
    [ "$status" -eq 1 ]; [[ "$output" == *"cancelado"* ]]
    run bash "$B" memory dedupe --yes </dev/null
    [[ "$output" != *"cancelado"* ]]
    export DEDUPE_APPLY=0
    run bash "$B" memory dedupe </dev/null
    [[ "$output" != *"continuar"* ]]
    unset DEDUPE_APPLY
}


@test "openbrain config imprime las OPENBRAIN_* efectivas" {
    run env OPENBRAIN_STALE_DAYS=7 bash "$B" config
    [ "$status" -eq 0 ]
    grep -q '^OPENBRAIN_STALE_DAYS=7$' <<<"$output"
    grep -q '^OPENBRAIN_COLLECTION=' <<<"$output"
    ! grep -q '^OPENBRAIN_CONFIG_FILE=' <<<"$output"
}
