#!/usr/bin/env bats
load helpers

H="$REPO_ROOT/hooks"; S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    export OPENBRAIN_CAPTURE_DIR="$XDG_STATE_HOME/openbrain/candidates"
    CAP="$OPENBRAIN_CAPTURE_DIR/sid-c1.jsonl"
}
cand() { printf '%s' "$(hook_json UserPromptSubmit sid-c1 "prompt=$1")" | bash "$H/capture-candidate.sh"; }

@test "correccion en espanol se captura con kind=correction" {
    run cand "No, en realidad el hook corre antes."
    [ "$status" -eq 0 ]; [ -f "$CAP" ]
    [ "$(jq -r .kind "$CAP")" = "correction" ]
    [ "$(jq -r .text "$CAP")" = "No, en realidad el hook corre antes." ]
}

@test "confirmacion se captura con kind=confirmation; 'incorrecto' NO es confirmacion" {
    run cand "Exacto, así es."
    [ "$(jq -r .kind "$CAP")" = "confirmation" ]
    rm -f "$CAP"
    run cand "eso es incorrecto"
    [ "$(jq -r .kind "$CAP")" = "correction" ]
}

@test "prompt neutro o slash command no escribe nada" {
    run cand "lista los ficheros del directorio"; [ "$status" -eq 0 ]; [ ! -e "$CAP" ]
    run cand "/openbrain:capture";                    [ "$status" -eq 0 ]; [ ! -e "$CAP" ]
}

@test "notificacion de tarea con senal de correccion no escribe nada" {
    run cand "$(printf '<task-notification>\n<status>completed</status>\nthe report was actually resolved\n</task-notification>')"
    [ "$status" -eq 0 ]; [ ! -e "$CAP" ]
}

@test "OPENBRAIN_CAPTURE_ENABLED=0 desactiva" {
    OPENBRAIN_CAPTURE_ENABLED=0 run cand "no, está mal"
    [ "$status" -eq 0 ]; [ ! -e "$CAP" ]
}

@test "permisos: dir 0700, fichero 0600" {
    cand "corrige eso" >/dev/null
    run bash -c "source '$S/lib/portable.sh'; p_stat_perms '$OPENBRAIN_CAPTURE_DIR'; p_stat_perms '$CAP'"
    [ "${lines[0]}" = "700" ]; [ "${lines[1]}" = "600" ]
}

@test "redaccion: un secreto detectable hace descartar el candidato, rc 0" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    # Generados, no literales: gitleaks tiene en allowlist la clave de ejemplo
    # de la doc de AWS, y filtra por entropia los tokens secuenciales. La regla
    # aws-access-token exige base32 ([A-Z2-7]) tras el prefijo.
    k="AKIA$(LC_ALL=C tr -dc 'A-Z2-7' < /dev/urandom | head -c 16)"
    t="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"
    run cand "no, la clave es $k y el token $t"
    [ "$status" -eq 0 ]
    [ ! -e "$CAP" ]
}

@test "senal de correccion mas alla de 1500 bytes se conserva en el texto capturado" {
    filler="$(head -c 3000 /dev/zero | tr '\0' 'x')"
    run cand "${filler} en realidad la regla es X"
    [ "$status" -eq 0 ]; [ -f "$CAP" ]
    [ "$(jq -r .kind "$CAP")" = "correction" ]
    [[ "$(jq -r .text "$CAP")" == *"la regla es X"* ]]
}

@test "redaccion: PII se enmascara, el candidato se guarda" {
    run cand "recuerda que el correo es persona@example.com"
    [ -f "$CAP" ]
    grep -q 'REDACTED:email' "$CAP"; ! grep -q 'persona@' "$CAP"
}

@test "tope por sesion: la linea 41 no entra; texto truncado a 2000 bytes" {
    for i in $(seq 1 41); do cand "no, intento $i" >/dev/null; done
    [ "$(wc -l < "$CAP" | tr -d ' ')" = "40" ]
    rm -f "$CAP"
    long="$(head -c 5000 /dev/zero | tr '\0' 'a')"
    cand "corrige $long" >/dev/null
    [ "$(jq -r .text "$CAP" | wc -c | tr -d ' ')" -le 2001 ]
}

@test "capture-flush purga > TTL, actualiza .pending" {
    cand "no, uno" >/dev/null; cand "no, dos" >/dev/null
    printf '{"ts":"x"}\n' > "$OPENBRAIN_CAPTURE_DIR/viejo.jsonl"; touch -t 200001010000 "$OPENBRAIN_CAPTURE_DIR/viejo.jsonl"
    run bash -c "echo '{\"session_id\":\"sid-c1\"}' | bash '$H/capture-flush.sh'"
    [ "$status" -eq 0 ]
    [ ! -e "$OPENBRAIN_CAPTURE_DIR/viejo.jsonl" ]
    [ "$(cat "$OPENBRAIN_CAPTURE_DIR/.pending")" = "2" ]
}

@test "load-global-memory anuncia candidatos pendientes" {
    mkdir -p "$OPENBRAIN_CAPTURE_DIR"; printf '3' > "$OPENBRAIN_CAPTURE_DIR/.pending"
    mkdir -p "$HOME/.claude/projects/_global/memory"
    run bash -c "echo '{}' | bash '$H/load-global-memory.sh'"
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"3 candidatos"*"/openbrain:capture"* ]]
}

@test "openbrain-capture list/show/purge" {
    cand "no, uno" >/dev/null
    run bash "$S/openbrain-capture.sh" list;  [ "$status" -eq 0 ]; [[ "$output" == *"sid-c1"*"1"* ]]
    run bash "$S/openbrain-capture.sh" show sid-c1; [[ "$output" == *"no, uno"* ]]
    run bash "$S/openbrain-capture.sh" purge --all; [ ! -e "$CAP" ]
}

@test "redact-before-haiku: email se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'contacto: ana.sintetica@ejemplo-test.com' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:email]"* ]]
    [[ "$output" != *"ana.sintetica@ejemplo-test.com"* ]]
}

@test "redact-before-haiku: telefono espanol se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'telefono: +34 612 345 678' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:phone]"* ]]
    [[ "$output" != *"612 345 678"* ]]
}

@test "redact-before-haiku: iban se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'iban: ES91 2100 0418 4502 0005 1332' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:iban]"* ]]
    [[ "$output" != *"2100 0418"* ]]
}

@test "redact-before-haiku: dni se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'dni: 12345678Z' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:dni]"* ]]
    [[ "$output" != *"12345678Z"* ]]
}

@test "redact-before-haiku: nie se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'nie: X1234567L' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:nie]"* ]]
    [[ "$output" != *"X1234567L"* ]]
}

@test "redact-before-haiku: numero de tarjeta se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'tarjeta: 4111 1111 1111 1111' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:card]"* ]]
    [[ "$output" != *"4111 1111 1111 1111"* ]]
}

@test "redact-before-haiku: URI de base de datos se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'db: postgres://user:pw@db.example/x' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:dburi]"* ]]
    [[ "$output" != *"user:pw@db.example"* ]]
}

@test "mas frases de correccion, en espanol e ingles" {
    run cand "no es correcto lo que dices"
    [ "$(jq -r .kind "$CAP")" = "correction" ]
    rm -f "$CAP"
    run cand "el resultado no es exacto, revísalo"
    [ "$(jq -r .kind "$CAP")" = "correction" ]
    rm -f "$CAP"
    run cand "that's not right"
    [ "$(jq -r .kind "$CAP")" = "correction" ]
}

@test "'exacto' sin puntuacion delante no es señal; confirmaciones sueltas si lo son" {
    run cand "necesito el numero exacto de usuarios"
    [ "$status" -eq 0 ]; [ ! -e "$CAP" ]
    run cand "quiero ser exacto en esto"
    [ "$status" -eq 0 ]; [ ! -e "$CAP" ]
    run cand "Correcto."
    [ "$(jq -r .kind "$CAP")" = "confirmation" ]
    rm -f "$CAP"
    run cand "sí, exacto"
    [ "$(jq -r .kind "$CAP")" = "confirmation" ]
}

@test "tope de sesion se comprueba antes de redactar: un secreto no fuerza una linea 41" {
    for i in $(seq 1 40); do cand "no, intento $i" >/dev/null; done
    [ "$(wc -l < "$CAP" | tr -d ' ')" = "40" ]
    k="AKIAIOSFODNN7EX"; k="${k}AMPLE"
    run cand "no, la clave es $k"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$CAP" | tr -d ' ')" = "40" ]
}

@test "openbrain-capture.sh show con session_id invalido: rc 2" {
    run bash "$S/openbrain-capture.sh" show "../x"
    [ "$status" -eq 2 ]
    [[ "$output" == *"session_id no valido"* ]]
}

@test "redact-before-haiku: linea password se enmascara" {
    command -v gitleaks >/dev/null || skip "sin gitleaks"
    run bash -c "printf '%s' 'password: hunter2secret' | bash '$S/redact-before-haiku.sh' -"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REDACTED:"* ]]
    [[ "$output" != *"hunter2secret"* ]]
}
