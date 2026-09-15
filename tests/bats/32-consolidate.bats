#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    export OPENBRAIN_DOCTRINE_DIR="$HOME/.claude/doctrine"; mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_journal" "$OPENBRAIN_DOCTRINE_DIR/_review"
    cp "$REPO_ROOT/tests/fixtures/doctrine/alpha.md" "$OPENBRAIN_DOCTRINE_DIR/"
    printf '{"ts":"%s","event":"session_close","edit_count":3}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl"
    # claude falso que falla si alguien lo llama
    mkdir -p "$BATS_TEST_TMPDIR/bin"; printf '#!/usr/bin/env bash\necho CLAUDE-LLAMADO >&2; exit 99\n' > "$BATS_TEST_TMPDIR/bin/claude"; chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export OPENBRAIN_OPERATOR_CONTEXT="analista sintetico de pruebas"
}

@test "render_template sustituye placeholders, incluidos valores multilinea" {
    tpl="$BATS_TEST_TMPDIR/t.md"; printf 'Hola {{NAME}}\n---\n{{BODY}}\n---\n' > "$tpl"
    vars="$BATS_TEST_TMPDIR/v.json"; jq -n '{NAME:"alpha",BODY:"línea 1\nlínea 2"}' > "$vars"
    run bash -c "source '$S/lib/render.sh'; render_template '$tpl' '$vars'"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Hola alpha" ]
    [ "${lines[2]}" = "línea 1" ]
    [ "${lines[3]}" = "línea 2" ]
}

@test "render_template no re-expande placeholders que vengan dentro de un valor" {
    tpl="$BATS_TEST_TMPDIR/w.md"; printf 'A={{A}} B={{B}}\n' > "$tpl"
    vars="$BATS_TEST_TMPDIR/wv.json"; jq -n '{A:"{{B}}",B:"{{A}}"}' > "$vars"
    run bash -c "source '$S/lib/render.sh'; render_template '$tpl' '$vars'"
    [ "$status" -eq 0 ]
    [ "$output" = "A={{B}} B={{A}}" ]
    # y un valor con {{HUERFANO}} no dispara el fallo cerrado: no es de la plantilla
    vars2="$BATS_TEST_TMPDIR/wv2.json"; jq -n '{A:"{{HUERFANO}}",B:"b"}' > "$vars2"
    run bash -c "source '$S/lib/render.sh'; render_template '$tpl' '$vars2'"
    [ "$status" -eq 0 ]
}

@test "render_template falla cerrado si sobra un placeholder sin valor" {
    tpl="$BATS_TEST_TMPDIR/u.md"; printf 'Hola {{NAME}}, dato {{MISSING}}\n' > "$tpl"
    vars="$BATS_TEST_TMPDIR/uv.json"; jq -n '{NAME:"alpha"}' > "$vars"
    run bash -c "source '$S/lib/render.sh'; render_template '$tpl' '$vars'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MISSING"* ]]
}

@test "consolidate --dry-run renderiza el prompt y no llama a claude" {
    run bash "$S/doctrine-consolidate.sh" --dry-run alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"bloque de doctrina **alpha**"* ]]
    [[ "$output" == *"analista sintetico de pruebas"* ]]
    [[ "$output" == *"# alpha"* ]]                 # contenido del bloque
    [[ "$output" == *'"edit_count":3'* ]]          # journal
    [[ "$output" != *"CLAUDE-LLAMADO"* ]]
    # la identidad del operador sale solo de la config: con otra, cambia y la anterior desaparece
    run env OPENBRAIN_OPERATOR_CONTEXT="otro contexto sintetico" bash "$S/doctrine-consolidate.sh" --dry-run alpha
    [[ "$output" == *"otro contexto sintetico"* ]]
    [[ "$output" != *"analista sintetico de pruebas"* ]]
    [ ! -f "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review.alpha" ]
    [ -z "$(ls -d "$OPENBRAIN_DOCTRINE_DIR"/_review/*/ 2>/dev/null)" ]   # sin _review/<fecha>/ vacío
}

@test "consolidate <bloque> fija el cooldown por bloque antes de llamar a claude y no deja un .last_review global" {
    run bash "$S/doctrine-consolidate.sh" alpha
    [ -f "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review.alpha" ]
    [ ! -f "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review" ]
}

@test "un review regenerado el mismo dia borra el marcador .applied anterior" {
    TODAY="$(date -u +%Y-%m-%d)"
    printf '#!/usr/bin/env bash\nmkdir -p "%s/_review/%s"; printf "# review nuevo\\n" > "%s/_review/%s/alpha.md"\n' \
        "$OPENBRAIN_DOCTRINE_DIR" "$TODAY" "$OPENBRAIN_DOCTRINE_DIR" "$TODAY" > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY"; : > "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY/.applied.alpha"
    run bash "$S/doctrine-consolidate.sh" alpha
    [ "$status" -eq 0 ]
    [ -f "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY/alpha.md" ]
    [ ! -f "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY/.applied.alpha" ]
    [ ! -d "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock" ]
}

@test "consolidate conserva el review anterior si claude falla sin escribir nada nuevo" {
    TODAY="$(date -u +%Y-%m-%d)"
    mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY"
    printf '# review viejo\n' > "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY/alpha.md"
    : > "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY/.applied.alpha"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    run bash "$S/doctrine-consolidate.sh" alpha
    [ "$status" -eq 0 ]
    [ -f "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY/.applied.alpha" ]
    [[ "$output" == *"Sin review nuevo"* ]]
    [ "$(cat "$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY/alpha.md")" = "# review viejo" ]
}

@test "consolidate omite un bloque con consolidacion en curso (lock por bloque) y sale 1" {
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock"
    run bash "$S/doctrine-consolidate.sh" alpha
    [ "$status" -eq 1 ]
    [[ "$output" == *"en curso"* ]]
    [ ! -f "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review.alpha" ]
    [[ "$output" != *"CLAUDE-LLAMADO"* ]]
}

@test "consolidate reclama un lock por bloque cuyo pid ya murio" {
    ( sleep 0 ) & dead_pid=$!
    wait "$dead_pid" 2>/dev/null
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock"
    echo "$dead_pid" > "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock/pid"
    run bash "$S/doctrine-consolidate.sh" alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE-LLAMADO"* ]]
    [ ! -d "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock" ]
}

@test "consolidate reclama un lock por bloque sin pid con mas de 60 min" {
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock"
    touch -t 202001010000 "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock"
    run bash "$S/doctrine-consolidate.sh" alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE-LLAMADO"* ]]
    [ ! -d "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock" ]
}
@test "consolidate respeta un lock por bloque con pid vivo: se omite y sale 1" {
    sleep 60 & live_pid=$!
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock"
    echo "$live_pid" > "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock/pid"
    run bash "$S/doctrine-consolidate.sh" alpha
    kill "$live_pid" 2>/dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"en curso"* ]]
    [[ "$output" != *"CLAUDE-LLAMADO"* ]]
}

@test "consolidate: un kill de claude no deja el lock por bloque atascado" {
    printf '#!/usr/bin/env bash\nkill -TERM $PPID\nsleep 5\n' > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    run bash "$S/doctrine-consolidate.sh" alpha
    [ ! -d "$XDG_STATE_HOME/openbrain/doctrine/consolidate.alpha.lock" ]
    # ni temporales del prompt o del log de claude en TMPDIR
    [ "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'doctrine-*' -newer "$BATS_TEST_TMPDIR/bin/claude" | wc -l | tr -d ' ')" = 0 ]
}

@test "consolidate sin --dry-run llama a claude, reporta el rc y su salida" {
    run bash "$S/doctrine-consolidate.sh" alpha
    [[ "$output" == *"Sin review utilizable (claude exit 99)"* ]]
    [[ "$output" == *"CLAUDE-LLAMADO"* ]]     # la salida del CLI se conserva, no se tira a /dev/null
}

@test "consolidate acota los turnos del curator" {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/argv"; exit 99\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    run env OPENBRAIN_REVIEW_MAX_TURNS=7 bash "$S/doctrine-consolidate.sh" alpha
    grep -qx -- --max-turns "$BATS_TEST_TMPDIR/argv"
    grep -qx -- 7 "$BATS_TEST_TMPDIR/argv"
}

@test "consolidate: el evento de audit solo lista los bloques con review escrito" {
    cp "$OPENBRAIN_DOCTRINE_DIR/alpha.md" "$OPENBRAIN_DOCTRINE_DIR/beta.md"
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OPENBRAIN_DOCTRINE_DIR/_journal/beta.jsonl"
    mkdir -p "$HOME/.claude/hooks/lib"
    printf 'audit_log_json() { printf "%%s\\n" "$1" >> "$AUDIT_LOG"; }\n' > "$HOME/.claude/hooks/lib/audit.sh"
    export AUDIT_LOG="$BATS_TEST_TMPDIR/audit.log"
    cat > "$BATS_TEST_TMPDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
TODAY="$(date -u +%Y-%m-%d)"
case "$*" in
  *'**beta**'*) exit 1 ;;
  *) mkdir -p "${OPENBRAIN_DOCTRINE_DIR}/_review/${TODAY}"; printf '# review\n' > "${OPENBRAIN_DOCTRINE_DIR}/_review/${TODAY}/alpha.md" ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    run bash "$S/doctrine-consolidate.sh"
    [ "$status" -eq 0 ]
    grep -F '"doctrine_consolidate"' "$AUDIT_LOG" | jq -e '.bloques == ["alpha"]' >/dev/null
}

@test "consolidate: sin ningun bloque con review escrito, no llama al audit" {
    mkdir -p "$HOME/.claude/hooks/lib"
    printf 'audit_log_json() { printf "%%s\\n" "$1" >> "$AUDIT_LOG"; }\n' > "$HOME/.claude/hooks/lib/audit.sh"
    export AUDIT_LOG="$BATS_TEST_TMPDIR/audit.log"
    run bash "$S/doctrine-consolidate.sh" alpha
    [ ! -s "$AUDIT_LOG" ]
}

@test "consolidate crea _review/<fecha> en 700" {
    TODAY="$(date -u +%Y-%m-%d)"
    printf '#!/usr/bin/env bash\nprintf "# review\\n" > "%s/_review/%s/alpha.md"\n' "$OPENBRAIN_DOCTRINE_DIR" "$TODAY" > "$BATS_TEST_TMPDIR/bin/claude"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude"
    run bash "$S/doctrine-consolidate.sh" alpha; [ "$status" -eq 0 ]
    [ "$(bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$OPENBRAIN_DOCTRINE_DIR/_review/$TODAY'")" = 700 ]
}

@test "consolidate rechaza un nombre de bloque hostil y no crea nada fuera de OPENBRAIN_DOCTRINE_DIR" {
    run bash "$S/doctrine-consolidate.sh" '../../evil'
    [ "$status" -eq 1 ]
    [[ "$output" == *"no válido"* ]]
    [[ "$output" != *"CLAUDE-LLAMADO"* ]]
    [ ! -e "$HOME/evil.md" ]
    [ ! -e "$OPENBRAIN_DOCTRINE_DIR/../evil.md" ]
}

@test "consolidate --days sin valor no cuelga y sale 1" {
    run timeout 5 bash "$S/doctrine-consolidate.sh" --days
    [ "$status" -eq 1 ]
    [[ "$output" == *"--days requiere un valor"* ]]
}

@test "consolidate --days con valor no numerico sale 1" {
    run bash "$S/doctrine-consolidate.sh" --days abc alpha
    [ "$status" -eq 1 ]
    [[ "$output" == *"--days requiere un valor num"*"abc"* ]]
}

@test "consolidate --dry-run funciona sin 'claude' en PATH" {
    filtered=""
    old_ifs="$IFS"; IFS=':'
    for d in $PATH; do
        [ -x "$d/claude" ] && continue
        filtered="${filtered:+$filtered:}$d"
    done
    IFS="$old_ifs"
    run env PATH="$filtered" bash "$S/doctrine-consolidate.sh" --dry-run alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"bloque de doctrina **alpha**"* ]]
}

@test "consolidate marca como aplicado un review 'Sin cambios propuestos' y colapsa el journal por sesion" {
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nout="$(printf "%%s" "$2" | grep -o "/[^ ]*_review/[^ ]*alpha.md" | head -1)"\nprintf "%%s" "$2" > "%s/prompt"\nprintf "# Review propuesto: alpha\\n\\n## Sin cambios propuestos\\n\\nEl bloque refleja el uso real del periodo.\\n" > "$out"\n' "$BATS_TEST_TMPDIR" > "$BIN/claude"; chmod +x "$BIN/claude"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","sid":"s1","event":"session","edit_count":1}\n{"ts":"%s","sid":"s2","event":"session","edit_count":1}\n{"ts":"%s","sid":"s1","event":"session","edit_count":7}\n' "$now" "$now" "$now" > "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl"
    run env PATH="$BIN:$PATH" bash "$S/doctrine-consolidate.sh" alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"sin cambios"* ]]
    d="$(date -u +%Y-%m-%d)"
    [ -f "$OPENBRAIN_DOCTRINE_DIR/_review/$d/.applied.alpha" ]
    run bash "$S/openbrain-review.sh"; [[ "$output" == *"aplicado"* ]]
    [ "$(grep -c '"sid":"s1"' "$BATS_TEST_TMPDIR/prompt")" = 1 ]
    grep -q '"edit_count":7' "$BATS_TEST_TMPDIR/prompt"
    grep -q '"sid":"s2"' "$BATS_TEST_TMPDIR/prompt"
}
