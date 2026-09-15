#!/usr/bin/env bats
load helpers

H="$REPO_ROOT/hooks"
S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    make_hmac_key
    make_memory proj-a nota-1 project
    make_memory proj-a nota-2 feedback
    MEM="$HOME/.claude/projects"
    SESSIONS="$XDG_STATE_HOME/openbrain/sessions"
    SIGNLOG="$XDG_STATE_HOME/openbrain/sign-memory.log"
    bash "$S/verify-memory-hmac.sh" "$MEM" sign >/dev/null
}

# El hueco real: una memoria escrita con Bash no pasa por PostToolUse.
break_via_bash() {
    printf 'linea escrita con Bash\n' >> "$1"
}

mark_session() {
    bash "$H/sign-memory.sh" SessionStart <<< "$(hook_json SessionStart "$1")"
}

stop_hook() {
    bash "$H/sign-memory.sh" Stop <<< "$(hook_json Stop "$1")"
}

verify_line() {
    bash "$S/verify-memory-hmac.sh" "$MEM" verify 2>/dev/null | grep -F "$1"
}

@test "sign-memory: SessionStart deja marca 0600 y con mtime retrasado" {
    mark_session s1
    [ -f "$SESSIONS/s1.start" ]
    run bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$SESSIONS/s1.start'"
    [ "$output" = 600 ]
    # El retraso de 2 s es lo que salva la carrera de segundos de `-nt`.
    local ahora="$BATS_TEST_TMPDIR/ahora"
    touch "$ahora"
    [ "$ahora" -nt "$SESSIONS/s1.start" ]
}

@test "sign-memory: un SessionStart repetido (compact/resume) no mueve la marca" {
    mark_session s1b
    local hace1h hace30m
    hace1h="$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)"
    hace30m="$(date -v-30M +%Y%m%d%H%M.%S 2>/dev/null || date -d '30 minutes ago' +%Y%m%d%H%M.%S)"
    touch -t "$hace1h" "$SESSIONS/s1b.start"
    mark_session s1b
    local ref="$BATS_TEST_TMPDIR/ref"; touch -t "$hace30m" "$ref"
    # Si la marca se hubiera recreado seria de ahora y mas nueva que ref.
    [ ! "$SESSIONS/s1b.start" -nt "$ref" ]
}

@test "sign-memory: sin marca de sesion no firma nada" {
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    run stop_hook sin-marca
    [ "$status" -eq 0 ]
    run verify_line "nota-1.md"
    [[ "$output" == FAIL* ]]
    grep -q '"action":"skipped"' "$SIGNLOG"
}

@test "sign-memory: firma lo editado dentro de la ventana" {
    mark_session s2
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    run stop_hook s2
    [ "$status" -eq 0 ]
    run verify_line "nota-1.md"
    [[ "$output" == OK* ]]
    grep -q '"action":"signed"' "$SIGNLOG"
}

@test "sign-memory: firma una memoria sin sidecar" {
    rm -f "$MEM/proj-a/memory/nota-2.md.hmac"
    mark_session s3
    touch "$MEM/proj-a/memory/nota-2.md"
    run stop_hook s3
    [ "$status" -eq 0 ]
    run verify_line "nota-2.md"
    [[ "$output" == OK* ]]
}

@test "sign-memory: deja fallando lo tocado fuera de la ventana" {
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    touch -t 202001010900 "$MEM/proj-a/memory/nota-1.md"
    mark_session s4
    run stop_hook s4
    [ "$status" -eq 0 ]
    run verify_line "nota-1.md"
    [[ "$output" == FAIL* ]]
    grep -q '"action":"out_of_band"' "$SIGNLOG"
    ! grep -q '"action":"signed"' "$SIGNLOG"
}

@test "sign-memory: no mezcla ventanas de sesiones distintas" {
    mark_session s5
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    run stop_hook otra-sesion
    [ "$status" -eq 0 ]
    run verify_line "nota-1.md"
    [[ "$output" == FAIL* ]]
}

@test "sign-memory: fallo masivo por encima del tope no firma nada" {
    local i
    for i in 1 2 3 4 5 6; do make_memory proj-m "m$i" project; done
    bash "$S/verify-memory-hmac.sh" "$MEM" sign >/dev/null
    for i in 1 2 3 4 5 6; do break_via_bash "$MEM/proj-m/memory/m$i.md"; done
    mark_session s6
    run env OPENBRAIN_SIGN_ON_STOP_MAX=3 bash "$H/sign-memory.sh" Stop <<< "$(hook_json Stop s6)"
    [ "$status" -eq 0 ]
    [ "$(bash "$S/verify-memory-hmac.sh" "$MEM" verify 2>/dev/null | grep -c '^FAIL')" -eq 6 ]
    grep -q '"action":"refused"' "$SIGNLOG"
}

@test "sign-memory: OPENBRAIN_SIGN_ON_STOP=0 lo desactiva entero" {
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    run env OPENBRAIN_SIGN_ON_STOP=0 bash "$H/sign-memory.sh" SessionStart <<< "$(hook_json SessionStart s7)"
    [ ! -f "$SESSIONS/s7.start" ]
    run env OPENBRAIN_SIGN_ON_STOP=0 bash "$H/sign-memory.sh" Stop <<< "$(hook_json Stop s7)"
    [ "$status" -eq 0 ]
    run verify_line "nota-1.md"
    [[ "$output" == FAIL* ]]
    [ ! -f "$SIGNLOG" ]
}

@test "sign-memory: el lint bloquea la firma de una memoria invalida" {
    make_memory proj-a mala bogus
    mark_session s8
    run stop_hook s8
    [ "$status" -eq 0 ]
    run verify_line "mala.md"
    [[ "$output" == MISS* ]]
    grep -q '"action":"lint_blocked"' "$SIGNLOG"
}

@test "sign-memory: cada linea del log es JSON con session_id" {
    mark_session s9
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    stop_hook s9
    run jq -r -e 'select(.event == "sign_memory") | .session_id' "$SIGNLOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *s9* ]]
}

@test "verify-memory-hmac: alcance por fichero no toca al vecino" {
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    break_via_bash "$MEM/proj-a/memory/nota-2.md"
    run bash "$S/verify-memory-hmac.sh" "$MEM/proj-a/memory/nota-1.md" sign
    [ "$status" -eq 0 ]
    [[ "$output" == *"nota-1.md"* ]]
    run verify_line "nota-1.md"
    [[ "$output" == OK* ]]
    run verify_line "nota-2.md"
    [[ "$output" == FAIL* ]]
}

@test "verify-memory-hmac: verify de un solo fichero no barre huerfanos" {
    : > "$MEM/proj-a/memory/fantasma.md.hmac"
    run bash "$S/verify-memory-hmac.sh" "$MEM/proj-a/memory/nota-1.md" verify
    [ "$status" -eq 0 ]
    [[ "$output" != *ORPHAN* ]]
    run bash "$S/verify-memory-hmac.sh" "$MEM" verify
    [[ "$output" == *ORPHAN* ]]
}

@test "verify-memory-hmac: un fichero fuera de un dir memory se rechaza" {
    printf 'x\n' > "$BATS_TEST_TMPDIR/suelta.md"
    run bash "$S/verify-memory-hmac.sh" "$BATS_TEST_TMPDIR/suelta.md" sign
    [ "$status" -eq 2 ]
    [ ! -f "$BATS_TEST_TMPDIR/suelta.md.hmac" ]
}

@test "verify-memory-hmac: un memory/ fuera de OPENBRAIN_MEMORY_ROOT se rechaza" {
    mkdir -p "$BATS_TEST_TMPDIR/ajeno/memory"
    printf 'x\n' > "$BATS_TEST_TMPDIR/ajeno/memory/n.md"
    run bash "$S/verify-memory-hmac.sh" "$BATS_TEST_TMPDIR/ajeno/memory/n.md" sign
    [ "$status" -eq 2 ]
    [ ! -f "$BATS_TEST_TMPDIR/ajeno/memory/n.md.hmac" ]
}

@test "verify-memory-hmac: ruta relativa dentro de memory/ se acepta" {
    run bash -c "cd '$MEM/proj-a/memory' && bash '$S/verify-memory-hmac.sh' nota-1.md verify"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK   nota-1.md"* ]]
}

@test "sign-memory: un aviso de estilo del lint (rc 1) sigue firmando" {
    make_memory proj-a estilo project
    bash "$S/verify-memory-hmac.sh" "$MEM" sign >/dev/null
    mark_session s10
    printf 'ver ~/.ssh/config\n' >> "$MEM/proj-a/memory/estilo.md"
    run bash "$S/lint-memory.sh" "$MEM/proj-a/memory/estilo.md"
    [ "$status" -eq 1 ]
    run stop_hook s10
    [ "$status" -eq 0 ]
    run verify_line "estilo.md"
    [[ "$output" == OK* ]]
}

@test "sign-memory: FAIL con motivo entre parentesis (sidecar symlink) se firma igual" {
    rm -f "$MEM/proj-a/memory/nota-2.md.hmac"
    ln -s "$BATS_TEST_TMPDIR/ajena" "$MEM/proj-a/memory/nota-2.md.hmac"
    run verify_line "nota-2.md"
    [[ "$output" == *"(signature is a symlink)"* ]]
    mark_session s11
    touch "$MEM/proj-a/memory/nota-2.md"
    run stop_hook s11
    [ "$status" -eq 0 ]
    [ ! -L "$MEM/proj-a/memory/nota-2.md.hmac" ]
    run verify_line "nota-2.md"
    [[ "$output" == OK* ]]
}

@test "sign-memory: payload sin session_id no crea marca y Stop lo registra" {
    run bash "$H/sign-memory.sh" SessionStart <<< '{}'
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$SESSIONS" 2>/dev/null)" ]
    run bash "$H/sign-memory.sh" Stop <<< '{}'
    [ "$status" -eq 0 ]
    grep -q 'session_id ausente o invalido' "$SIGNLOG"
}

@test "sign-memory: session_id hostil no compone rutas ni deja marca" {
    run bash "$H/sign-memory.sh" SessionStart <<< '{"session_id":"../../evil"}'
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$SESSIONS" 2>/dev/null)" ]
    [ ! -e "$XDG_STATE_HOME/openbrain/evil.start" ]; [ ! -e "$XDG_STATE_HOME/evil.start" ]
}

@test "sign-memory: un vecino invalido fuera de ventana no bloquea la firma del bueno" {
    make_memory proj-a mala bogus
    touch -t 202001010900 "$MEM/proj-a/memory/mala.md"
    mark_session s12
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    run stop_hook s12
    [ "$status" -eq 0 ]
    run verify_line "nota-1.md"
    [[ "$output" == OK* ]]
    run verify_line "mala.md"
    [[ "$output" == MISS* ]]
    ! grep -q '"action":"lint_blocked"' "$SIGNLOG"
}

@test "sign-memory: OPENBRAIN_SIGN_ON_STOP_MAX no numerico vuelve al tope por defecto" {
    local i
    for i in $(seq 1 26); do make_memory proj-x "x$i" project; done
    bash "$S/verify-memory-hmac.sh" "$MEM" sign >/dev/null
    for i in $(seq 1 26); do break_via_bash "$MEM/proj-x/memory/x$i.md"; done
    mark_session s13
    run env OPENBRAIN_SIGN_ON_STOP_MAX=abc bash "$H/sign-memory.sh" Stop <<< "$(hook_json Stop s13)"
    [ "$status" -eq 0 ]
    [ "$(bash "$S/verify-memory-hmac.sh" "$MEM" verify 2>/dev/null | grep -c '^FAIL')" -eq 26 ]
    grep -q '"action":"refused"' "$SIGNLOG"
}

@test "sign-memory: SessionStart purga marcas de mas de 7 dias" {
    mkdir -p "$SESSIONS"
    touch -t 202001010900 "$SESSIONS/vieja.start"
    mark_session s14
    [ ! -e "$SESSIONS/vieja.start" ]
    [ -f "$SESSIONS/s14.start" ]
}

@test "sign-memory: un symlink plantado en la marca se retira antes de escribir" {
    mkdir -p "$SESSIONS"
    printf 'victima\n' > "$BATS_TEST_TMPDIR/victima"
    ln -s "$BATS_TEST_TMPDIR/victima" "$SESSIONS/s15.start"
    mark_session s15
    [ ! -L "$SESSIONS/s15.start" ]
    [ -f "$SESSIONS/s15.start" ]
    [ "$(cat "$BATS_TEST_TMPDIR/victima")" = victima ]
}

@test "sign-memory: rutas con espacios en slug y nombre se firman" {
    make_memory 'proj con espacio' 'nota con espacio' project
    bash "$S/verify-memory-hmac.sh" "$MEM" sign >/dev/null
    mark_session s16
    break_via_bash "$MEM/proj con espacio/memory/nota con espacio.md"
    run stop_hook s16
    [ "$status" -eq 0 ]
    run verify_line "nota con espacio.md"
    [[ "$output" == OK* ]]
}

@test "sign-memory: verify con rc 2 (clave laxa) se registra como skipped y no firma" {
    mark_session s17
    break_via_bash "$MEM/proj-a/memory/nota-1.md"
    chmod 644 "$HOME/.config/claude/memory.hmac"
    run stop_hook s17
    [ "$status" -eq 0 ]
    grep -q 'verify rc=2' "$SIGNLOG"
    ! grep -q '"action":"signed"' "$SIGNLOG"
    chmod 600 "$HOME/.config/claude/memory.hmac"
    run verify_line "nota-1.md"
    [[ "$output" == FAIL* ]]
}

@test "sign-memory.log se recorta a 2000 lineas al pasar de 4000 y conserva la ultima" {
    mkdir -p "$(dirname "$SIGNLOG")"
    awk 'BEGIN { for (i = 1; i <= 4001; i++) printf "{\"n\":%d}\n", i }' > "$SIGNLOG"
    chmod 600 "$SIGNLOG"
    stop_hook sid-rot
    [ "$(wc -l < "$SIGNLOG" | tr -d ' ')" -eq 2000 ]
    tail -1 "$SIGNLOG" | grep -q '"session_id":"sid-rot"'
    [ "$(bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$SIGNLOG'")" = 600 ]
    [ -z "$(find "$(dirname "$SIGNLOG")" -name '.prune.*' 2>/dev/null)" ]
}
