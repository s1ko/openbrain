#!/usr/bin/env bats
load helpers
S="$REPO_ROOT/scripts"
setup() { setup_fake_home; export PATH="$REPO_ROOT/tests/fixtures/fake-qmd:$PATH"; export FAKE_QMD_LOG="$BATS_TEST_TMPDIR/q.log"; export OPENBRAIN_COLLECTION=c; }

@test "sin coleccion: rc 2, qmd no se invoca" {
    OPENBRAIN_COLLECTION="" run bash "$S/openbrain-recall.sh" hola
    [ "$status" -eq 2 ]; [[ "$output" == *"OPENBRAIN_COLLECTION"* ]]; [ ! -e "$FAKE_QMD_LOG" ]
}
@test "default es search con -c y -n 10" {
    run bash "$S/openbrain-recall.sh" alpha cosa
    [ "$status" -eq 0 ]
    grep -q '^search alpha cosa -c c -n 10$' "$FAKE_QMD_LOG"
}
@test "--hybrid usa query; -n y --json pasan" {
    run bash "$S/openbrain-recall.sh" --hybrid -n 3 --json alpha
    grep -q '^query alpha -c c -n 3 --json$' "$FAKE_QMD_LOG"
}
@test "sin consulta: uso, rc 2" { run bash "$S/openbrain-recall.sh"; [ "$status" -eq 2 ]; }
@test "sin qmd en PATH: rc 1 y aviso" {
    PATH=/usr/bin:/bin run bash "$S/openbrain-recall.sh" hola
    [ "$status" -eq 1 ]
    [[ "$output" == *"qmd no está en PATH"* ]]
}
@test "-- pasa --hybrid literal como consulta; modo sigue en search" {
    run bash "$S/openbrain-recall.sh" -- --hybrid
    [ "$status" -eq 0 ]
    grep -q '^search --hybrid -c c -n 10$' "$FAKE_QMD_LOG"
}
@test "-n sin valor: rc no cero y mensaje" {
    run bash "$S/openbrain-recall.sh" -n
    [ "$status" -ne 0 ]
    [[ "$output" == *"-n necesita"* ]]
}
