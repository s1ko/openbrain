#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    make_hmac_key
    make_memory proj-a nota-1 project
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null

    # Aislamiento GPG: clave efimera bajo GNUPGHOME propio, nunca ~/.gnupg real.
    export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
    install -d -m 700 "$GNUPGHOME"
    gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key \
        'openbrain-test <openbrain-test@example.invalid>' default default never >/dev/null 2>&1
    FPR="$(gpg --batch --with-colons --list-keys 'openbrain-test@example.invalid' | awk -F: '/^fpr:/{print $10; exit}')"
    [ -n "$FPR" ]
    export OPENBRAIN_BACKUP_GPG="$FPR"
    export OPENBRAIN_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
}

teardown() {
    # R22b: gpg-agent arranca contra el GNUPGHOME efimero de este test y, si
    # no se mata, sigue vivo apuntando a un tmpdir que bats va a borrar.
    gpgconf --kill gpg-agent 2>/dev/null || true
}

@test "backup cifra y restore en modo test valida sin extraer" {
    run bash "$S/backup-memory.sh"
    [ "$status" -eq 0 ]
    archive="$(ls -t "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.gpg | head -1)"
    [ -f "$archive" ]
    run bash "$S/restore-memory.sh" "$archive" "$BATS_TEST_TMPDIR/restore-test" test
    [ "$status" -eq 0 ]
}

@test "restore extract recupera .md y .hmac identicos byte a byte" {
    # R22a: no basta con que el nombre exista -- el contenido restaurado
    # tiene que ser identico al original, no solo homonimo.
    orig_md="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    orig_hmac="$orig_md.hmac"
    keep_md="$BATS_TEST_TMPDIR/orig-nota-1.md"
    keep_hmac="$BATS_TEST_TMPDIR/orig-nota-1.md.hmac"
    cp "$orig_md" "$keep_md"
    cp "$orig_hmac" "$keep_hmac"

    bash "$S/backup-memory.sh" >/dev/null
    archive="$(ls -t "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.gpg | head -1)"
    run bash "$S/restore-memory.sh" "$archive" "$BATS_TEST_TMPDIR/restore" extract
    [ "$status" -eq 0 ]
    restored_md="$(find "$BATS_TEST_TMPDIR/restore" -name 'nota-1.md')"
    restored_hmac="$(find "$BATS_TEST_TMPDIR/restore" -name 'nota-1.md.hmac')"
    [ -n "$restored_md" ]
    [ -n "$restored_hmac" ]
    cmp "$keep_md" "$restored_md"
    cmp "$keep_hmac" "$restored_hmac"
}

@test "backup sin OPENBRAIN_BACKUP_GPG -> falla cerrado" {
    unset OPENBRAIN_BACKUP_GPG
    run bash "$S/backup-memory.sh"
    [ "$status" -ne 0 ]
}

@test "poda de retencion: se queda con las mas nuevas y no toca ficheros ajenos" {
    # R21: la poda no es invocable aislada -- vive pegada, en el mismo
    # script, a la creacion de un backup real (backup-memory.sh no tiene
    # modo "solo podar"). Se ejercita via el punto de entrada normal, lo que
    # SIEMPRE anade un backup real recien creado (el mas nuevo de todos los
    # existentes, por reloj). Por eso KEEP=4 en vez de 3: de los 6 backups
    # falsos preexistentes deben sobrevivir exactamente los 3 mas recientes
    # (mas el real recien creado = 4 supervivientes totales), podando
    # exactamente los 3 mas viejos.
    export OPENBRAIN_BACKUP_KEEP=4
    mkdir -p "$OPENBRAIN_BACKUP_DIR"
    touch "$OPENBRAIN_BACKUP_DIR/README.txt"
    for i in 1 2 3 4 5 6; do
        day="$(printf '%02d' "$i")"
        f="$OPENBRAIN_BACKUP_DIR/memory-202001${day}T000000Z.tar.gz.gpg"
        printf 'fake backup %d\n' "$i" > "$f"
        touch -t "202001${day}0000" "$f"
    done

    run bash "$S/backup-memory.sh"
    [ "$status" -eq 0 ]

    # las 3 mas viejas (01,02,03) podadas
    [ ! -f "$OPENBRAIN_BACKUP_DIR/memory-20200101T000000Z.tar.gz.gpg" ]
    [ ! -f "$OPENBRAIN_BACKUP_DIR/memory-20200102T000000Z.tar.gz.gpg" ]
    [ ! -f "$OPENBRAIN_BACKUP_DIR/memory-20200103T000000Z.tar.gz.gpg" ]
    # las 3 mas nuevas (04,05,06) sobreviven
    [ -f "$OPENBRAIN_BACKUP_DIR/memory-20200104T000000Z.tar.gz.gpg" ]
    [ -f "$OPENBRAIN_BACKUP_DIR/memory-20200105T000000Z.tar.gz.gpg" ]
    [ -f "$OPENBRAIN_BACKUP_DIR/memory-20200106T000000Z.tar.gz.gpg" ]
    # fichero ajeno en el mismo directorio, intacto
    [ -f "$OPENBRAIN_BACKUP_DIR/README.txt" ]
    # exactamente 4 backups tras la poda (los 3 fakes mas nuevos + el real)
    count="$(find "$OPENBRAIN_BACKUP_DIR" -maxdepth 1 -name 'memory-*.tar.gz.gpg' | wc -l | tr -d ' ')"
    [ "$count" -eq 4 ]
}

@test "backup con age y restore extract devuelven bytes identicos (skip sin age)" {
    command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || skip "age no instalado"
    unset OPENBRAIN_BACKUP_GPG
    id="$HOME/.config/claude/memory-backup-key.txt"
    ( umask 077; age-keygen -o "$id" >/dev/null 2>&1 )
    export OPENBRAIN_BACKUP_AGE="$(grep -o 'age1[a-z0-9]*' "$id" | head -1)"
    [ -n "$OPENBRAIN_BACKUP_AGE" ]
    run bash "$S/backup-memory.sh"; [ "$status" -eq 0 ]
    archive="$(ls -t "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.age | head -1)"; [ -f "$archive" ]
    run bash "$S/restore-memory.sh" "$archive" "$BATS_TEST_TMPDIR/restore-age" extract; [ "$status" -eq 0 ]
    cmp "$HOME/.claude/projects/proj-a/memory/nota-1.md" "$(find "$BATS_TEST_TMPDIR/restore-age" -name nota-1.md)"
}

@test "backup con recipient age malformado falla cerrado" {
    unset OPENBRAIN_BACKUP_GPG
    export OPENBRAIN_BACKUP_AGE="/tmp/no-es-una-clave"
    run bash "$S/backup-memory.sh"; [ "$status" -eq 2 ]; [[ "$output" == *"age public key"* ]]
    [ -z "$(ls "$OPENBRAIN_BACKUP_DIR" 2>/dev/null)" ]
}

@test "OPENBRAIN_BACKUP_KEEP=08 no rompe la aritmetica y poda con normalidad" {
    # R23a: "08" pasa el regex ^[0-9]+$ pero bash lo trata como octal invalido
    # en (( )); sin normalizar con 10#$keep la poda se saltaba en silencio
    # dejando "value too great for base" en stderr.
    export OPENBRAIN_BACKUP_KEEP=08
    mkdir -p "$OPENBRAIN_BACKUP_DIR"
    for i in 1 2 3 4 5 6 7 8 9; do
        day="$(printf '%02d' "$i")"
        f="$OPENBRAIN_BACKUP_DIR/memory-202001${day}T000000Z.tar.gz.gpg"
        printf 'fake backup %d\n' "$i" > "$f"
        touch -t "202001${day}0000" "$f"
    done

    run bash "$S/backup-memory.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"value too great for base"* ]]
    [[ "$output" != *"refused"* ]]

    # las 2 mas viejas (01,02) podadas: 9 fakes + 1 real = 10, keep=8 -> poda 2
    [ ! -f "$OPENBRAIN_BACKUP_DIR/memory-20200101T000000Z.tar.gz.gpg" ]
    [ ! -f "$OPENBRAIN_BACKUP_DIR/memory-20200102T000000Z.tar.gz.gpg" ]
    [ -f "$OPENBRAIN_BACKUP_DIR/memory-20200109T000000Z.tar.gz.gpg" ]
    count="$(find "$OPENBRAIN_BACKUP_DIR" -maxdepth 1 -name 'memory-*.tar.gz.gpg' | wc -l | tr -d ' ')"
    [ "$count" -eq 8 ]
}

@test "slug de proyecto con guion inicial: backup y restore extract funcionan igual" {
    make_memory -tmp-synth-proj nota-2 project
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null

    run bash "$S/backup-memory.sh"
    [ "$status" -eq 0 ]
    archive="$(ls -t "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.gpg | head -1)"
    [ -f "$archive" ]
    run bash "$S/restore-memory.sh" "$archive" "$BATS_TEST_TMPDIR/restore-dash" extract
    [ "$status" -eq 0 ]
    [ -n "$(find "$BATS_TEST_TMPDIR/restore-dash" -name 'nota-2.md')" ]
}

@test "OPENBRAIN_MEMORY_ROOT apuntando directo a un memory/ hace backup y restore test ve md>0" {
    # R23b: resolve_memdirs acepta que la raiz sea ya un directorio memory/;
    # el listado de ficheros del backup debe soportar esa forma tambien.
    export OPENBRAIN_MEMORY_ROOT="$HOME/.claude/projects/proj-a/memory"
    run bash "$S/backup-memory.sh"
    [ "$status" -eq 0 ]
    archive="$(ls -t "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.gpg | head -1)"
    [ -f "$archive" ]
    run bash "$S/restore-memory.sh" "$archive" "$BATS_TEST_TMPDIR/restore-singledir" test
    [ "$status" -eq 0 ]
    [[ "$output" =~ md=[1-9] ]]
}

