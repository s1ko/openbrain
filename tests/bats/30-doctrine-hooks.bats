#!/usr/bin/env bats
load helpers

H="$REPO_ROOT/hooks"

setup() {
    setup_fake_home
    export DOC="$HOME/.claude/doctrine"; mkdir -p "$DOC/_journal" "$DOC/_review"
    printf -- '---\nname: alpha\ndescription: d\ntriggers:\n  cwd:\n    - "**/alpha-zone/**"\n---\n# alpha\n' > "$DOC/alpha.md"
    export AUDIT_LOG="$BATS_TEST_TMPDIR/audit.log"
}

@test "doctrine-journal: una linea por bloque activo con las metricas del transcript" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"sid-t1","event":"doctrine_loaded","doctrines":["alpha"]}\n' > "$DOC/_journal/_sessions.jsonl"
    make_transcript "$BATS_TEST_TMPDIR/t.jsonl"
    run bash -c "printf '%s' '$(hook_json Stop sid-t1 "transcript_path=$BATS_TEST_TMPDIR/t.jsonl")' | bash '$H/doctrine-journal.sh'"
    [ "$status" -eq 0 ]
    [ -f "$DOC/_journal/alpha.jsonl" ]
    [ "$(jq -r .event "$DOC/_journal/alpha.jsonl")" = "session" ]
    [ "$(jq -r .edit_count "$DOC/_journal/alpha.jsonl")" = "3" ]
    # el ultimo editado primero, sin repetir
    [ "$(jq -c .edited_paths "$DOC/_journal/alpha.jsonl")" = '["/p/a.md","/p/b.md"]' ]
    [ "$(jq -c '.tools_used|map(.tool+"="+(.count|tostring))' "$DOC/_journal/alpha.jsonl")" = '["Write=2","Bash=1","Edit=1"]' ]
    [ "$(jq -c .blocked_actions "$DOC/_journal/alpha.jsonl")" = '[{"tool":"Bash","count":1}]' ]
    [ ! -f "$DOC/_journal/beta.jsonl" ]
    [ "$(bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$DOC/_journal/alpha.jsonl'")" = 600 ]
}

@test "doctrine-journal: un segundo Stop de la misma sesion sustituye su linea y conserva el ts inicial" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"sid-t2","event":"doctrine_loaded","doctrines":["alpha"]}\n' > "$DOC/_journal/_sessions.jsonl"
    printf '{"ts":"2026-09-01T10:05:00Z","ts_end":"2026-09-01T10:05:00Z","sid":"sid-t2","doctrine":"alpha","event":"session","edit_count":0}\n{"ts":"2026-09-01T09:00:00Z","sid":"otra","doctrine":"alpha","event":"session","edit_count":1}\n' > "$DOC/_journal/alpha.jsonl"
    make_transcript "$BATS_TEST_TMPDIR/t.jsonl"
    run bash -c "printf '%s' '$(hook_json Stop sid-t2 "transcript_path=$BATS_TEST_TMPDIR/t.jsonl")' | bash '$H/doctrine-journal.sh'"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$DOC/_journal/alpha.jsonl" | tr -d ' ')" = 2 ]
    [ "$(grep -c '"sid":"sid-t2"' "$DOC/_journal/alpha.jsonl")" = 1 ]
    [ "$(grep '"sid":"sid-t2"' "$DOC/_journal/alpha.jsonl" | jq -r '.ts + " " + (.edit_count|tostring)')" = "2026-09-01T10:05:00Z 3" ]
    [ "$(grep '"sid":"sid-t2"' "$DOC/_journal/alpha.jsonl" | jq -r .ts_end)" != "2026-09-01T10:05:00Z" ]
    grep -q '"sid":"otra"' "$DOC/_journal/alpha.jsonl"
    [ -z "$(find "$DOC/_journal" -name '.upsert.*' 2>/dev/null)" ]
}

@test "doctrine-journal: sin transcript_path (o ruta relativa) escribe metricas a cero" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"sid-t3","event":"doctrine_loaded","doctrines":["alpha"]}\n' > "$DOC/_journal/_sessions.jsonl"
    run bash -c "printf '%s' '$(hook_json Stop sid-t3 "transcript_path=relativa.jsonl")' | bash '$H/doctrine-journal.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.edit_count, (.edited_paths|length), (.tools_used|length), (.blocked_actions|length)]' "$DOC/_journal/alpha.jsonl")" = '[0,0,0,0]' ]
}

@test "doctrine-journal sin session_id no escribe, rc 0" {
    run bash -c "echo '{}' | bash '$H/doctrine-journal.sh'"
    [ "$status" -eq 0 ]
    [ ! -f "$DOC/_journal/alpha.jsonl" ]
}

@test "doctrine-lazy-check: journal nuevo sin review marca .last_review y lanza consolidate" {
    rm -rf "$DOC/_review"
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.jsonl"
    STUB="$BATS_TEST_TMPDIR/consolidate-stub.sh"
    printf '#!/usr/bin/env bash\necho "$1" >> "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    [ -f "$DOC/_review/.last_review.alpha" ]
    [ "$(bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$DOC/_review'")" = 700 ]
    # consolidate se lanza con nohup en segundo plano: esperar hasta 5 s
    # (un sleep fijo de 1 s fallaba bajo carga con la suite completa)
    i=0; while [ $i -lt 50 ] && [ ! -f "$BATS_TEST_TMPDIR/launched" ]; do sleep 0.1; i=$((i+1)); done
    grep -qx alpha "$BATS_TEST_TMPDIR/launched"
}

@test "doctrine-lazy-check: review hace 10 min hace cooldown, no lanza" {
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.jsonl"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$DOC/_review/.last_review.alpha"
    STUB="$BATS_TEST_TMPDIR/stub.sh"; printf '#!/usr/bin/env bash\ntouch "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    sleep 1
    [ ! -f "$BATS_TEST_TMPDIR/launched" ]
}

@test "doctrine-lazy-check: nota con APLICADA en la tercera linea del cuerpo no se encola" {
    printf '## %s\nPrimera linea de contexto.\nSegunda linea de contexto.\n> APLICADA\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.notes.md"
    STUB="$BATS_TEST_TMPDIR/stub.sh"; printf '#!/usr/bin/env bash\necho "$1" >> "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$DOC/_review/.last_review.alpha" ]
    sleep 1
    [ ! -f "$BATS_TEST_TMPDIR/launched" ]
}

@test "doctrine-lazy-check respeta OPENBRAIN_REVIEW_SKIP=1" {
    printf '{"ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.jsonl"
    run env OPENBRAIN_REVIEW_SKIP=1 bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$DOC/_review/.last_review.alpha" ]
}

@test "session-doctrine escribe el estado bajo XDG_STATE_HOME (0700), nunca en TMPDIR" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    run bash -c "cd '$BATS_TEST_TMPDIR' && echo '{\"session_id\":\"sid-s1\"}' | CLAUDE_SESSION_ID=sid-s1 bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ -f "$XDG_STATE_HOME/openbrain/doctrine/sid-s1.state" ]
    [ "$(bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$XDG_STATE_HOME/openbrain/doctrine'")" = 700 ]
    [ -z "$(ls "$TMPDIR" 2>/dev/null)" ]
    printf '%s' "$output" | jq -e .hookSpecificOutput.hookEventName >/dev/null
    jq -e 'has("repo") and .repo == ""' "$XDG_STATE_HOME/openbrain/doctrine/sid-s1.state" >/dev/null
}

@test "un hook ejecutado a traves de un symlink RELATIVO encuentra common.sh" {
    # capture-candidate solo escribe si llego a common.sh (redaccion, config):
    # con la raiz mal resuelta sale 0 en silencio y no hay candidato.
    mkdir -p "$HOME/l"; export OPENBRAIN_CAPTURE_DIR="$HOME/cap"
    rel="$(python3 -c "import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))" "$H/capture-candidate.sh" "$HOME/l")"
    ln -s "$rel" "$HOME/l/capture-candidate.sh"
    run bash -c "printf '%s' '$(hook_json UserPromptSubmit sid-rl "prompt=No, en realidad el hook corre antes.")' | bash '$HOME/l/capture-candidate.sh'"
    [ "$status" -eq 0 ]
    [ -n "$(ls "$HOME/cap" 2>/dev/null)" ]
}

@test "session_id hostil (../) no compone rutas: id sintetico y nada fuera del dir de estado" {
    run bash -c "cd '$BATS_TEST_TMPDIR' && echo '{\"session_id\":\"../../evil\"}' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ ! -e "$XDG_STATE_HOME/evil.state" ]; [ ! -e "$XDG_STATE_HOME/openbrain/evil.state" ]
    printf '%s' "$output" | jq -e .hookSpecificOutput.hookEventName >/dev/null
    payload="$(jq -cn '{session_id:"../../evil",tool_name:"Read",tool_input:{file_path:"/z/x"}}')"
    run bash -c "printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "un symlink plantado en la ruta del estado se sustituye, nunca se sigue" {
    victim="$BATS_TEST_TMPDIR/victima.txt"; printf 'intacto\n' > "$victim"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; ln -s "$victim" "$XDG_STATE_HOME/openbrain/doctrine/sid-l.state"
    run bash -c "cd '$BATS_TEST_TMPDIR' && echo '{\"session_id\":\"sid-l\"}' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ "$(cat "$victim")" = intacto ]
    [ ! -L "$XDG_STATE_HOME/openbrain/doctrine/sid-l.state" ]; [ -f "$XDG_STATE_HOME/openbrain/doctrine/sid-l.state" ]
}

@test "un nombre de doctrina con comillas no rompe el evento doctrine_loaded del audit.log" {
    # audit_log_json la aporta el host (el hook la usa solo si existe): stub exportado.
    cp "$DOC/alpha.md" "$DOC/ra\"ro.md"; mkdir -p "$BATS_TEST_TMPDIR/alpha-zone"
    run bash -c "audit_log_json() { printf '%s\\n' \"\$1\" >> \"\$AUDIT_LOG\"; }; export -f audit_log_json; cd '$BATS_TEST_TMPDIR/alpha-zone' && echo '{\"session_id\":\"sid-q\"}' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    grep -F '"event":"doctrine_loaded"' "$AUDIT_LOG" | grep -F '"session_id":"sid-q"' | jq -e '.doctrines|length>=1' >/dev/null
}


@test "refresh-doctrine: la herramienta del plugin regenera el bloque; el allowlist acepta ~ y deja fuera lo que no lista" {
    command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null || skip "sin python3 con tomllib"
    # la herramienta exige objetivo y manifiesto sin escritura de grupo/otros,
    # tambien en su directorio: la umask del host no lo garantiza.
    mk() { printf '# %s\n\n<!-- AUTO-START -->\n<!-- AUTO-END -->\n' "$1" > "$2"; chmod 644 "$2"; chmod 755 "$(dirname "$2")"; }
    manifest() { printf '[[field]]\nlabel = "T"\ncommand = "echo %s"\ndefault = "?"\n' "$1" > "$2"; chmod 644 "$2"; chmod 755 "$(dirname "$2")"; }
    mk global "$HOME/.claude/CLAUDE.md";  manifest GLOBAL-OK "$HOME/.claude/refresh.toml"
    mkdir -p "$HOME/repo/.claude"; mk local "$HOME/repo/CLAUDE.md"; manifest LOCAL-OK "$HOME/repo/.claude/refresh.toml"

    printf '~/repo\n' > "$HOME/.claude/refresh-allowlist"
    run bash -c "cd '$HOME/repo' && bash '$H/refresh-doctrine.sh'"
    [ "$status" -eq 0 ]
    grep -q 'GLOBAL-OK' "$HOME/.claude/CLAUDE.md"
    grep -q 'LOCAL-OK'  "$HOME/repo/CLAUDE.md"

    rm -rf "$XDG_CACHE_HOME/claude"
    mkdir -p "$HOME/otro/.claude"; mk otro "$HOME/otro/CLAUDE.md"; manifest OTRO-OK "$HOME/otro/.claude/refresh.toml"
    run bash -c "cd '$HOME/otro' && bash '$H/refresh-doctrine.sh'"
    [ "$status" -eq 0 ]
    ! grep -q 'OTRO-OK' "$HOME/otro/CLAUDE.md"
    [ ! -e "$HOME/.local/bin/refresh-claude-md" ]
}

@test "refresh-doctrine: si la herramienta falla no deja marcador ni toca el objetivo" {
    command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null || skip "sin python3 con tomllib"
    printf '# g\n\n<!-- AUTO-START -->\nold\n<!-- AUTO-END -->\n' > "$HOME/.claude/CLAUDE.md"
    printf 'esto no es toml valido\n[[\n' > "$HOME/.claude/refresh.toml"
    chmod 644 "$HOME/.claude/CLAUDE.md" "$HOME/.claude/refresh.toml"; chmod 755 "$HOME/.claude"
    run bash -c "cd '$HOME' && bash '$H/refresh-doctrine.sh'"
    [ "$status" -eq 0 ]
    grep -q '^old$' "$HOME/.claude/CLAUDE.md"
    [ ! -e "$XDG_CACHE_HOME/claude/refresh-global.marker" ]
}

@test "session-doctrine registra la sesion en el journal propio del plugin" {
    mkdir -p "$BATS_TEST_TMPDIR/alpha-zone"
    run bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && echo '{\"session_id\":\"sid-j3\"}' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ -f "$DOC/_journal/_sessions.jsonl" ]
    grep -F '"session_id":"sid-j3"' "$DOC/_journal/_sessions.jsonl" | jq -e '.doctrines|index("alpha")' >/dev/null
    [ "$(bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$DOC/_journal/_sessions.jsonl'")" = 600 ]
}

@test "doctrine-journal no necesita el audit.log del host: lee el journal propio" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"sid-j2","event":"doctrine_loaded","cwd":"/x","branch":"main","doctrines":["alpha"]}\n' \
        > "$DOC/_journal/_sessions.jsonl"
    run bash -c "echo '{\"session_id\":\"sid-j2\"}' | bash '$H/doctrine-journal.sh'"
    [ "$status" -eq 0 ]
    [ -f "$DOC/_journal/alpha.jsonl" ]
    [ "$(jq -r .event "$DOC/_journal/alpha.jsonl")" = session ]
    [ "$(jq -r .edit_count "$DOC/_journal/alpha.jsonl")" = 0 ]
}

@test "doctrine-lazy-check ignora _sessions.jsonl: no es un bloque de doctrina" {
    printf '{"ts":"%s","event":"doctrine_loaded"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/_sessions.jsonl"
    cp "$DOC/alpha.md" "$DOC/_sessions.md"
    STUB="$BATS_TEST_TMPDIR/stub.sh"; printf '#!/usr/bin/env bash\necho "$1" >> "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$DOC/_review/.last_review._sessions" ]
    sleep 1
    [ ! -f "$BATS_TEST_TMPDIR/launched" ] || ! grep -qx _sessions "$BATS_TEST_TMPDIR/launched"
}

@test "el journal de sesiones se poda y conserva modo 600" {
    J="$DOC/_journal/_sessions.jsonl"
    for i in $(seq 2100); do
        printf '{"ts":"2026-09-01T10:00:00Z","session_id":"sid-p","event":"doctrine_loaded","doctrines":["alpha"]}\n'
    done > "$J"
    run bash -c "echo '{\"session_id\":\"sid-p\"}' | bash '$H/doctrine-journal.sh'"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$J" | tr -d ' ')" = 1000 ]
    [ "$(bash -c "source '$REPO_ROOT/scripts/lib/portable.sh'; p_stat_perms '$J'")" = 600 ]
    # sin temporales huerfanos en el journal
    [ -z "$(find "$DOC/_journal" -name '.prune.*' 2>/dev/null)" ]
}

@test "lazy-check: solo un consolidador a la vez y en serie" {
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.jsonl"
    cp "$DOC/alpha.md" "$DOC/beta.md"
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/beta.jsonl"
    STUB="$BATS_TEST_TMPDIR/stub.sh"
    printf '#!/usr/bin/env bash\nprintf "inicio %%s\\n" "$1" >> "%s/orden"\nsleep 1\nprintf "fin %%s\\n" "$1" >> "%s/orden"\n' \
        "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"

    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    [ -d "$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock" ]

    # segunda pasada mientras la primera corre: el lock la descarta
    rm -f "$DOC/_review/.last_review.alpha" "$DOC/_review/.last_review.beta"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]

    i=0; while [ $i -lt 100 ] && [ -d "$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock" ]; do sleep 0.1; i=$((i+1)); done
    [ ! -d "$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock" ]
    # dos bloques, uno detrás de otro y una sola vez cada uno
    [ "$(grep -c '^inicio ' "$BATS_TEST_TMPDIR/orden")" = 2 ]
    [ "$(sed -n '2p' "$BATS_TEST_TMPDIR/orden")" = "fin $(sed -n '1p' "$BATS_TEST_TMPDIR/orden" | cut -d' ' -f2)" ]
}

@test "doctrine-lazy-check: con el lock global tomado no marca .last_review (no cuenta como revisado)" {
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.jsonl"
    sleep 60 & live_pid=$!
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock"
    echo "$live_pid" > "$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock/pid"
    STUB="$BATS_TEST_TMPDIR/stub.sh"; printf '#!/usr/bin/env bash\ntouch "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    kill "$live_pid" 2>/dev/null
    [ "$status" -eq 0 ]
    [ ! -f "$DOC/_review/.last_review.alpha" ]
    [ ! -f "$BATS_TEST_TMPDIR/launched" ]
}

@test "lazy-check: el lock global guarda vivo el pid del consolidador en segundo plano" {
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.jsonl"
    STUB="$BATS_TEST_TMPDIR/stub.sh"
    printf '#!/usr/bin/env bash\ntouch "%s/launched"\nsleep 2\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    LOCK="$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock"
    [ -d "$LOCK" ]
    i=0; while [ $i -lt 50 ] && [ ! -f "$BATS_TEST_TMPDIR/launched" ]; do sleep 0.1; i=$((i+1)); done
    pid="$(cat "$LOCK/pid" 2>/dev/null)"
    [ -n "$pid" ]
    kill -0 "$pid"
    i=0; while [ $i -lt 50 ] && [ -d "$LOCK" ]; do sleep 0.1; i=$((i+1)); done
    [ ! -d "$LOCK" ]
}

@test "un bloque activado a mitad de sesion por doctrine-watch entra en el journal junto a los de SessionStart" {
    printf -- '---\nname: beta\ndescription: d\ntriggers:\n  files:\n    - "*.beta"\n---\n# beta\n' > "$DOC/beta.md"
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"sid-w1","event":"doctrine_loaded","doctrines":["alpha"]}\n' > "$DOC/_journal/_sessions.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/nada"
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && echo '{\"session_id\":\"sid-w1\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$BATS_TEST_TMPDIR/x.beta\"}}' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [[ "$output" == *"DOCTRINA AMPLIADA"* ]]
    grep -F '"session_id":"sid-w1"' "$DOC/_journal/_sessions.jsonl" | jq -e 'select(.event=="doctrine_extended") | .doctrines|index("beta")' >/dev/null
    run bash -c "echo '{\"session_id\":\"sid-w1\"}' | bash '$H/doctrine-journal.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -r .event "$DOC/_journal/beta.jsonl")" = session ]
    [ "$(jq -r .event "$DOC/_journal/alpha.jsonl")" = session ]
    # una segunda Read del mismo fichero no cambia el estado: sin evento nuevo
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && echo '{\"session_id\":\"sid-w1\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$BATS_TEST_TMPDIR/x.beta\"}}' | bash '$H/doctrine-watch.sh'"
    [ "$(grep -c '"event":"doctrine_extended"' "$DOC/_journal/_sessions.jsonl")" = 1 ]
}

@test "session-doctrine en resume/compact conserva los bloques pegajosos del estado; clear los resetea" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    printf -- '---\nname: wdoc\ndescription: d\ntriggers:\n  watch:\n    - "secret.cfg"\n---\n# wdoc\n' > "$DOC/wdoc.md"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"","repo":"","active":["wdoc"]}' > "$XDG_STATE_HOME/openbrain/doctrine/sc1.state"
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$(hook_json SessionStart sc1 source=compact)' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -c .active "$XDG_STATE_HOME/openbrain/doctrine/sc1.state")" = '["wdoc"]' ]
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"doctrine/wdoc.md"* ]]
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$(hook_json SessionStart sc1 source=clear)' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -c .active "$XDG_STATE_HOME/openbrain/doctrine/sc1.state")" = '[]' ]
    [ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" = "" ]
}

@test "session-doctrine en compact: bloque pegajoso mas bloque de cwd, sin duplicar" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/alpha-zone"
    cp "$DOC/alpha.md" "$DOC/wdoc.md"; sed -i.bak 's/name: alpha/name: wdoc/' "$DOC/wdoc.md" 2>/dev/null || true; rm -f "$DOC/wdoc.md.bak"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"","repo":"","active":["alpha"]}' > "$XDG_STATE_HOME/openbrain/doctrine/sc2.state"
    run bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && printf '%s' '$(hook_json SessionStart sc2 source=resume)' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -c .active "$XDG_STATE_HOME/openbrain/doctrine/sc2.state")" = '["alpha","wdoc"]' ]
    [ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext | grep -c 'BEGIN .* doctrine/alpha.md')" = 1 ]
}

@test "doctrine-watch: un checkout fallido no produce un cambio de rama fantasma en la siguiente llamada" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    REPO="$BATS_TEST_TMPDIR/repo-ph"; mkdir -p "$REPO"
    git -C "$REPO" -c init.defaultBranch=main init -q
    printf 'x' > "$REPO/f"; git -C "$REPO" -c user.email=t@t -c user.name=t add f; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m i
    git -C "$REPO" branch other
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"
    jq -cn --arg repo "$(cd "$REPO" && pwd -P)" '{branch:"main",repo:$repo,active:[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s30.state"
    payload="$(jq -cn '{session_id:"s30",tool_name:"Bash",tool_input:{command:"git checkout -b other"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [[ "$output" == *"DOCTRINA ACTUALIZADA"* ]]
    [ "$(jq -r '.branch + "|" + .prev' "$XDG_STATE_HOME/openbrain/doctrine/s30.state")" = "other|main" ]
    ! git -C "$REPO" checkout -q -b other 2>/dev/null
    payload="$(jq -cn '{session_id:"s30",tool_name:"Bash",tool_input:{command:"ls"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(jq -r '.branch + "|" + .prev' "$XDG_STATE_HOME/openbrain/doctrine/s30.state")" = "main|" ]
    git -C "$REPO" checkout -q other
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [[ "$output" == *"DOCTRINA ACTUALIZADA"* ]]
    [ "$(jq -r .branch "$XDG_STATE_HOME/openbrain/doctrine/s30.state")" = other ]
}

@test "doctrine-watch: un cambio de rama solo re-inyecta los bloques nuevos, no todo lo pegajoso" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    REPO="$BATS_TEST_TMPDIR/repo-rb"; mkdir -p "$REPO"
    git -C "$REPO" -c init.defaultBranch=main init -q
    printf 'x' > "$REPO/f"; git -C "$REPO" -c user.email=t@t -c user.name=t add f; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m i
    git -C "$REPO" branch alpha/feat
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"
    printf -- '---\nname: sticky\ndescription: d\ntriggers:\n  cwd:\n    - "**/nunca/**"\n---\n# sticky\nCUERPO-STICKY\n' > "$DOC/sticky.md"
    printf -- '---\nname: brdoc\ndescription: d\ntriggers:\n  branch:\n    - "alpha/*"\n---\n# brdoc\n' > "$DOC/brdoc.md"
    jq -cn --arg repo "$(cd "$REPO" && pwd -P)" '{branch:"main",repo:$repo,active:["sticky"]}' > "$XDG_STATE_HOME/openbrain/doctrine/s31.state"
    payload="$(jq -cn '{session_id:"s31",tool_name:"Bash",tool_input:{command:"git switch alpha/feat"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"Nuevos bloques: brdoc"* ]]
    [[ "$ac" == *"doctrine/brdoc.md"* ]]
    [[ "$ac" != *"CUERPO-STICKY"* ]]
    [[ "$ac" == *"Bloques activos ahora: sticky brdoc"* ]]
    git -C "$REPO" checkout -q alpha/feat
    payload="$(jq -cn '{session_id:"s31",tool_name:"Bash",tool_input:{command:"git switch main"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"Sin bloques nuevos"* ]]
    [[ "$ac" != *"BEGIN "* ]]
}

@test "doctrine-lazy-check: varias lineas de la misma sesion cuentan una vez; una nota con titulo libre no cuenta" {
    STUB="$BATS_TEST_TMPDIR/stub.sh"; printf '#!/usr/bin/env bash\necho "$1" >> "%s/launched"\n' "$BATS_TEST_TMPDIR" > "$STUB"; chmod +x "$STUB"
    ago() { date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"H +%Y-%m-%dT%H:%M:%SZ; }
    printf '{"ts":"%s","sid":"s1","event":"session"}\n{"ts":"%s","sid":"s1","event":"session"}\n' "$(ago 3)" "$(ago 3)" > "$DOC/_journal/alpha.jsonl"
    printf '## Nota del %s sobre alpha\ntexto libre\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.notes.md"
    printf '%s' "$(ago 2)" > "$DOC/_review/.last_review.alpha"
    # cooldown vencido; las lineas s1 son anteriores al review y la nota libre no parsea: nada nuevo
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]; sleep 1
    [ ! -f "$BATS_TEST_TMPDIR/launched" ]
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","sid":"s2","event":"session"}\n{"ts":"%s","sid":"s2","event":"session"}\n' "$now" "$now" >> "$DOC/_journal/alpha.jsonl"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    i=0; while [ $i -lt 50 ] && [ ! -f "$BATS_TEST_TMPDIR/launched" ]; do sleep 0.1; i=$((i+1)); done
    grep -qx alpha "$BATS_TEST_TMPDIR/launched"
}

@test "doctrine-lazy-check: al lanzar poda los logs de consolidacion de mas de 30 dias, nada mas" {
    rm -rf "$DOC/_review"
    printf '{"ts":"%s","event":"session_close"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DOC/_journal/alpha.jsonl"
    L="$HOME/.claude/logs"; mkdir -p "$L"
    : > "$L/doctrine-consolidate-alpha-20200101T000000Z.log"; touch -t 202001010000 "$L/doctrine-consolidate-alpha-20200101T000000Z.log"
    : > "$L/doctrine-consolidate-alpha-fresh.log"
    : > "$L/otro.log"; touch -t 202001010000 "$L/otro.log"
    STUB="$BATS_TEST_TMPDIR/stub.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB"; chmod +x "$STUB"
    run env OPENBRAIN_CONSOLIDATE_BIN="$STUB" bash "$H/doctrine-lazy-check.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$L/doctrine-consolidate-alpha-20200101T000000Z.log" ]
    [ -e "$L/doctrine-consolidate-alpha-fresh.log" ]
    [ -e "$L/otro.log" ]
}
