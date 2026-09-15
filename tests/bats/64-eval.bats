#!/usr/bin/env bats
load helpers

E="$REPO_ROOT/eval"

setup() {
    setup_fake_home
    export PATH="$REPO_ROOT/tests/fixtures/fake-qmd:$PATH"
    export OPENBRAIN_COLLECTION=c
    export OPENBRAIN_WIKI_ROOT="$BATS_TEST_TMPDIR/wiki"; mkdir -p "$OPENBRAIN_WIKI_ROOT"
    export OPENBRAIN_EVAL_GOLDEN="$BATS_TEST_TMPDIR/golden.json"
    export OPENBRAIN_EVAL_METRICS="$BATS_TEST_TMPDIR/metrics.log"
    cp "$REPO_ROOT/eval/golden.example.json" "$OPENBRAIN_EVAL_GOLDEN"
    jq '.collection = "c" | .queries = [
            {query:"alpha cosa", expected_files:["alpha-uno.md"], expected_in_top_k:10},
            {query:"nada de nada", expected_files:["nunca.md"], expected_in_top_k:10}
        ]' "$OPENBRAIN_EVAL_GOLDEN" > "$OPENBRAIN_EVAL_GOLDEN.tmp" && mv "$OPENBRAIN_EVAL_GOLDEN.tmp" "$OPENBRAIN_EVAL_GOLDEN"
    export FAKE_QMD_LOG="$BATS_TEST_TMPDIR/qmd.log"
}

@test "eval/run.sh registra una linea bm25 en metrics.log y avisa 'registrado'" {
    run bash "$E/run.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registrado"* ]]
    [ "$(wc -l < "$OPENBRAIN_EVAL_METRICS" | tr -d ' ')" = "1" ]
    line="$(cat "$OPENBRAIN_EVAL_METRICS")"
    ts="${line%% *}"; json="${line#* }"
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
    [ "$(printf '%s' "$json" | jq -r .backend)" = "bm25" ]
}

@test "eval/run.sh --hybrid usa backend hybrid e invoca qmd query" {
    run bash "$E/run.sh" --hybrid
    [ "$status" -eq 0 ]
    line="$(cat "$OPENBRAIN_EVAL_METRICS")"
    json="${line#* }"
    [ "$(printf '%s' "$json" | jq -r .backend)" = "hybrid" ]
    grep -q '^query ' "$FAKE_QMD_LOG"
}

@test "eval/run.sh --verbose imprime MISS en stderr" {
    run bash -c "bash '$E/run.sh' --verbose 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -eq 0 ]
    grep -q '^MISS ' "$BATS_TEST_TMPDIR/err"
}

@test "eval/run.sh --hybrid --verbose imprime MISS en stderr" {
    run bash -c "bash '$E/run.sh' --hybrid --verbose 2>'$BATS_TEST_TMPDIR/err2'"
    [ "$status" -eq 0 ]
    grep -q '^MISS ' "$BATS_TEST_TMPDIR/err2"
}

@test "eval/run.sh se niega si el golden mide otra coleccion; metrics.log queda intacto" {
    jq '.collection = "otra"' "$OPENBRAIN_EVAL_GOLDEN" > "$OPENBRAIN_EVAL_GOLDEN.tmp" && mv "$OPENBRAIN_EVAL_GOLDEN.tmp" "$OPENBRAIN_EVAL_GOLDEN"
    run bash -c "bash '$E/run.sh' 2>'$BATS_TEST_TMPDIR/err3'"
    [ "$status" -eq 1 ]
    grep -q 'otra' "$BATS_TEST_TMPDIR/err3"
    [ ! -s "$OPENBRAIN_EVAL_METRICS" ]
}

@test "eval/run.sh con OPENBRAIN_COLLECTION vacio no exige coincidencia de coleccion" {
    jq '.collection = "otra"' "$OPENBRAIN_EVAL_GOLDEN" > "$OPENBRAIN_EVAL_GOLDEN.tmp" && mv "$OPENBRAIN_EVAL_GOLDEN.tmp" "$OPENBRAIN_EVAL_GOLDEN"
    export OPENBRAIN_COLLECTION=
    run bash "$E/run.sh"
    [ "$status" -eq 0 ]
}

@test "recall-eval.py sin argumentos: rc distinto de 0, uso en stderr" {
    run bash -c "python3 '$E/recall-eval.py' 2>&1 1>/dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" == usage:* ]]
}

@test "eval/run.sh: aviso de index-freshness llega a stderr" {
    mkdir -p "$XDG_CACHE_HOME/qmd"
    printf 'contenido a\n' > "$OPENBRAIN_WIKI_ROOT/a.md"
    python3 - "$XDG_CACHE_HOME/qmd/index.sqlite" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table documents(path TEXT, hash TEXT, collection TEXT, active INTEGER)")
con.execute("insert into documents values (?,?,?,?)", ("a.md", "wronghash", "c", 1))
con.commit(); con.close()
PY
    run bash -c "bash '$E/run.sh' 2>'$BATS_TEST_TMPDIR/err4'"
    [ "$status" -eq 0 ]
    grep -q 'index-freshness: aviso — modificados sin reindexar' "$BATS_TEST_TMPDIR/err4"
}
