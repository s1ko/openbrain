#!/usr/bin/env bats
load helpers

H="$REPO_ROOT/hooks"; S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    make_hmac_key
    export OPENBRAIN_DOCTRINE_DIR="$HOME/.claude/doctrine"; mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_journal" "$OPENBRAIN_DOCTRINE_DIR/_review"
    printf -- '---\nname: alpha\ndescription: d\ntriggers:\n  cwd:\n    - "**/alpha-zone/**"\n---\n# alpha\nCONTENIDO-ALPHA\n' > "$OPENBRAIN_DOCTRINE_DIR/alpha.md"
    export G="$HOME/.claude/projects/_global/memory"; mkdir -p "$G"
    printf -- '---\nname: g1\ndescription: d\ntype: feedback\n---\n\nGLOBAL-SINTETICA-1\n' > "$G/g1.md"
    printf '# MEMORY.md\n- [g1](g1.md) - INDICE-SINTETICO\n' > "$G/MEMORY.md"
    bash "$S/verify-memory-hmac.sh" "$G" sign >/dev/null
    export OPENBRAIN_CAPTURE_DIR="$XDG_STATE_HOME/openbrain/candidates"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/alpha-zone" "$BATS_TEST_TMPDIR/nada"
}

disp() { bash -c "cd '$BATS_TEST_TMPDIR/$1' && printf '%s' '$2' | bash '$H/openbrain-hook.sh' $3"; }

@test "SessionStart: un solo JSON valido con doctrina y memoria global, doctrina primero" {
    run disp alpha-zone '{"session_id":"d1"}' SessionStart
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.continue==true and .hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"DOCTRINA DINÁMICA CARGADA"* ]]; [[ "$ac" == *"CONTENIDO-ALPHA"* ]]
    [[ "$ac" == *"GLOBAL MEMORY"* ]]; [[ "$ac" == *"GLOBAL-SINTETICA-1"* ]]; [[ "$ac" == *"INDICE-SINTETICO"* ]]
    d="$(grep -n 'DOCTRINA DINÁMICA' <<<"$ac" | head -1 | cut -d: -f1)"
    m="$(grep -n '=== GLOBAL MEMORY' <<<"$ac" | head -1 | cut -d: -f1)"
    [ -n "$d" ] && [ -n "$m" ] && [ "$d" -lt "$m" ]
}

@test "SessionStart: escribe el estado para doctrine-watch y el journal propio" {
    run disp alpha-zone '{"session_id":"d2"}' SessionStart
    [ "$status" -eq 0 ]
    [ -f "$XDG_STATE_HOME/openbrain/doctrine/d2.state" ]
    [ "$(jq -r '.active|index("alpha")' "$XDG_STATE_HOME/openbrain/doctrine/d2.state")" != "null" ]
    grep -F '"session_id":"d2"' "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl" | jq -e '.doctrines|index("alpha")' >/dev/null
}

@test "SessionStart: sin doctrina activa ni memoria global, continue:true valido" {
    rm -f "$OPENBRAIN_DOCTRINE_DIR"/*.md; rm -rf "$G"
    run disp nada '{"session_id":"d3"}' SessionStart
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.continue==true' >/dev/null
}

@test "SessionStart: additionalContext del dispatcher == concatenacion de los hooks standalone" {
    run disp alpha-zone '{"session_id":"d4"}' SessionStart
    disp_ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    sd="$(bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && printf '%s' '{\"session_id\":\"d4\"}' | bash '$H/session-doctrine.sh'" | jq -r .hookSpecificOutput.additionalContext)"
    lg="$(bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && printf '%s' '{}' | bash '$H/load-global-memory.sh'" | jq -r .hookSpecificOutput.additionalContext)"
    # Mismo contenido: comparar el conjunto de lineas no vacias (agnostico al
    # separador de union), con el nonce por sesion normalizado.
    norm() { sed -E 's/[0-9a-f]{16}/N/g; /^[[:space:]]*$/d' | sort; }
    diff <(printf '%s\n%s' "$sd" "$lg" | norm) <(printf '%s' "$disp_ac" | norm)
}

@test "Stop: escribe una entrada session por bloque activo y no imprime nada" {
    disp alpha-zone '{"session_id":"d5"}' SessionStart >/dev/null
    run disp alpha-zone '{"session_id":"d5"}' Stop
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ -f "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl" ]
    [ "$(jq -r .event "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl")" = session ]
}

@test "Stop: recomputa .pending de captura" {
    mkdir -p "$OPENBRAIN_CAPTURE_DIR"
    printf '{"a":1}\n{"b":2}\n' > "$OPENBRAIN_CAPTURE_DIR/s1.jsonl"
    run disp alpha-zone '{"session_id":"d6"}' Stop
    [ "$status" -eq 0 ]
    [ "$(cat "$OPENBRAIN_CAPTURE_DIR/.pending")" = 2 ]
}

@test "Stop: el dispatcher dispara la consolidacion (lazy-check corre su cuerpo)" {
    disp alpha-zone '{"session_id":"d7"}' SessionStart >/dev/null
    # el SessionStart pudo tomar el lock via el spawn de session-doctrine: soltarlo
    rm -rf "$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock" "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review".*
    STUB="$BATS_TEST_TMPDIR/cons.sh"; printf '#!/usr/bin/env bash\necho "$1" >> "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && printf '%s' '{\"session_id\":\"d7\"}' | OPENBRAIN_CONSOLIDATE_BIN='$STUB' OPENBRAIN_REVIEW_SKIP=0 bash '$H/openbrain-hook.sh' Stop"
    [ "$status" -eq 0 ]
    i=0; while [ $i -lt 60 ] && [ ! -f "$BATS_TEST_TMPDIR/launched" ]; do sleep 0.1; i=$((i+1)); done
    grep -qx alpha "$BATS_TEST_TMPDIR/launched"
}

@test "Stop: OPENBRAIN_REVIEW_SKIP=1 no dispara consolidacion" {
    disp alpha-zone '{"session_id":"d8"}' SessionStart >/dev/null
    STUB="$BATS_TEST_TMPDIR/cons.sh"; printf '#!/usr/bin/env bash\ntouch "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && printf '%s' '{\"session_id\":\"d8\"}' | OPENBRAIN_CONSOLIDATE_BIN='$STUB' OPENBRAIN_REVIEW_SKIP=1 bash '$H/openbrain-hook.sh' Stop"
    [ "$status" -eq 0 ]; sleep 1
    [ ! -f "$BATS_TEST_TMPDIR/launched" ]
}

@test "SessionStart sin jq: el envoltorio cae a python3 y la doctrina no se pierde" {
    local BIN="$BATS_TEST_TMPDIR/bin" t src; mkdir -p "$BIN"
    for t in bash python3 git awk sed grep cat tr stat date readlink dirname basename sort head tail find wc mkdir chmod mv rm mktemp cksum openssl cut paste uniq env; do
        src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$BIN/$t"
    done
    run bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && printf '%s' '{\"session_id\":\"d9\"}' | PATH='$BIN' bash '$H/openbrain-hook.sh' SessionStart"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.continue==true' >/dev/null
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"CONTENIDO-ALPHA"* ]]
}

@test "SessionStart: refresh-doctrine se autolimita y no agota el presupuesto" {
    command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null || skip "sin python3 con tomllib"
    printf '# g\n\n<!-- AUTO-START -->\n<!-- AUTO-END -->\n' > "$HOME/.claude/CLAUDE.md"
    # dos campos de 8 s: sin presupuesto la herramienta tardaria 16 s y el
    # `timeout 10` del hook la mataria antes de escribir; con 2 s de presupuesto
    # escribe los `default` y devuelve el control mucho antes
    printf '[[field]]\nlabel = "A"\ncommand = "sleep 8"\ndefault = "?"\n[[field]]\nlabel = "B"\ncommand = "sleep 8"\ndefault = "?"\n' > "$HOME/.claude/refresh.toml"
    chmod 644 "$HOME/.claude/CLAUDE.md" "$HOME/.claude/refresh.toml"; chmod 755 "$HOME/.claude"
    export REFRESH_CLAUDE_MD_BUDGET=2
    local t0 t1
    t0="$(date +%s)"
    run disp alpha-zone '{"session_id":"d10"}' SessionStart
    t1="$(date +%s)"
    [ "$status" -eq 0 ]
    [ $(( t1 - t0 )) -lt 8 ]
    grep -q -- '- A: ?' "$HOME/.claude/CLAUDE.md"; grep -q -- '- B: ?' "$HOME/.claude/CLAUDE.md"
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"CONTENIDO-ALPHA"* ]]
}

@test "SessionStart: el dispatcher espera a refresh-doctrine aunque corra en segundo plano" {
    command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null || skip "sin python3 con tomllib"
    printf '# g\n\n<!-- AUTO-START -->\n<!-- AUTO-END -->\n' > "$HOME/.claude/CLAUDE.md"
    printf '[[field]]\nlabel = "A"\ncommand = "sleep 8"\ndefault = "?"\n' > "$HOME/.claude/refresh.toml"
    chmod 644 "$HOME/.claude/CLAUDE.md" "$HOME/.claude/refresh.toml"; chmod 755 "$HOME/.claude"
    export REFRESH_CLAUDE_MD_BUDGET=2
    local t0 t1 elapsed_ms
    t0="$(date +%s%N)"
    run disp alpha-zone '{"session_id":"d11"}' SessionStart
    t1="$(date +%s%N)"
    [ "$status" -eq 0 ]
    elapsed_ms=$(( (t1 - t0) / 1000000 ))
    # session-doctrine y load-global-memory terminan en milisegundos: si el
    # dispatcher no esperase al refresh en segundo plano (2 s de presupuesto),
    # devolveria el control mucho antes de que termine.
    [ "$elapsed_ms" -ge 1500 ]
    grep -q -- '- A: ?' "$HOME/.claude/CLAUDE.md"
}

@test "evento desconocido: rc 0 y aviso a stderr" {
    run bash "$H/openbrain-hook.sh" Frobnicate </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"evento desconocido"* ]]
}

@test "session_id hostil bajo el dispatcher no compone rutas" {
    run disp alpha-zone '{"session_id":"../../evil"}' SessionStart
    [ "$status" -eq 0 ]
    [ ! -e "$XDG_STATE_HOME/evil.state" ]; [ ! -e "$XDG_STATE_HOME/openbrain/evil.state" ]
    [ -z "$(ls -A "$XDG_STATE_HOME/openbrain/sessions" 2>/dev/null)" ]
    printf '%s' "$output" | jq -e '.continue==true' >/dev/null
}

@test "el despachador cablea sign-memory: marca en SessionStart, firma en Stop" {
    run disp alpha-zone '{"session_id":"d9"}' SessionStart
    [ "$status" -eq 0 ]
    [ -f "$XDG_STATE_HOME/openbrain/sessions/d9.start" ]
    printf 'linea escrita con Bash\n' >> "$G/g1.md"
    bash "$S/verify-memory-hmac.sh" "$G" verify 2>/dev/null | grep -q '^FAIL .*g1.md'
    run disp alpha-zone '{"session_id":"d9"}' Stop
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    bash "$S/verify-memory-hmac.sh" "$G" verify 2>/dev/null | grep -q '^OK .*g1.md'
}
