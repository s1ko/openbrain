#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"; B="$REPO_ROOT/bin/openbrain"

setup() {
    setup_fake_home
    export OPENBRAIN_DOCTRINE_DIR="$HOME/.claude/doctrine"; mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01"
    cp "$REPO_ROOT/tests/fixtures/doctrine/alpha.md" "$OPENBRAIN_DOCTRINE_DIR/"
    printf '# review\n' > "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/alpha.md"
}

@test "openbrain review: sin marcador es PENDIENTE aunque el cooldown sea posterior al review" {
    date -u +%Y-%m-%dT%H:%M:%SZ > "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review.alpha"
    run bash "$S/openbrain-review.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2026-09-01"*"alpha"*"PENDIENTE"* ]]
}

@test "openbrain review --mark: crea el marcador y el review pasa a aplicado; via bin/openbrain tambien" {
    run bash "$S/openbrain-review.sh" --mark alpha 2026-09-01
    [ "$status" -eq 0 ]; [[ "$output" == *"aplicado: alpha (2026-09-01)"* ]]
    [ -f "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/.applied.alpha" ]
    run bash "$S/openbrain-review.sh"
    [[ "$output" == *"alpha"*"aplicado"* ]]
    rm -f "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/.applied.alpha"
    run bash "$B" review --mark alpha 2026-09-01
    [ "$status" -eq 0 ]; [ -f "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/.applied.alpha" ]
}

@test "openbrain review --mark: rechaza bloque hostil, fecha invalida y review inexistente sin escribir nada" {
    run bash "$S/openbrain-review.sh" --mark '../x' 2026-09-01;  [ "$status" -eq 2 ]
    run bash "$S/openbrain-review.sh" --mark alpha 2026-13-01;   [ "$status" -eq 2 ]
    run bash "$S/openbrain-review.sh" --mark alpha '';           [ "$status" -eq 2 ]
    run bash "$S/openbrain-review.sh" --mark beta 2026-09-01;    [ "$status" -eq 2 ]
    [ -z "$(find "$OPENBRAIN_DOCTRINE_DIR" -name '.applied.*')" ]
}

@test "openbrain review --mark: un symlink plantado en el marcador no se sigue" {
    printf 'intacto\n' > "$BATS_TEST_TMPDIR/victima"
    ln -s "$BATS_TEST_TMPDIR/victima" "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/.applied.alpha"
    run bash "$S/openbrain-review.sh" --mark alpha 2026-09-01; [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/victima")" = intacto ]
    [ ! -L "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/.applied.alpha" ]; [ -f "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/.applied.alpha" ]
}

@test "openbrain review: un review reescrito despues de marcarlo vuelve a PENDIENTE" {
    bash "$S/openbrain-review.sh" --mark alpha 2026-09-01 >/dev/null
    run bash "$S/openbrain-review.sh"; [[ "$output" == *"alpha"*"aplicado"* ]]
    sleep 1.1; printf '# review v2\n' > "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/alpha.md"
    run bash "$S/openbrain-review.sh"; [[ "$output" == *"alpha"*"PENDIENTE"* ]]
}

@test "openbrain review --run sin bloque: uso y rc 2, tambien via bin/openbrain" {
    run bash "$S/openbrain-review.sh" --run
    [ "$status" -eq 2 ]; [[ "$output" == *"uso: openbrain review"* ]]
    run bash "$B" review --run
    [ "$status" -eq 2 ]; [[ "$output" == *"uso: openbrain review"* ]]
}

@test "openbrain review: flag desconocido da uso y rc 2; sin reviews lo dice" {
    run bash "$S/openbrain-review.sh" --frob;  [ "$status" -eq 2 ]; [[ "$output" == *"uso:"* ]]
    rm -rf "$OPENBRAIN_DOCTRINE_DIR/_review"
    run bash "$S/openbrain-review.sh";         [ "$status" -eq 0 ]; [[ "$output" == *"sin directorio de reviews"* ]]
}

@test "openbrain review --run rechaza un bloque hostil sin invocar doctrine-consolidate" {
    run bash "$S/openbrain-review.sh" --run '../x'
    [ "$status" -eq 2 ]
    [[ "$output" == *"bloque no válido"*"'../x'"* ]]
}
