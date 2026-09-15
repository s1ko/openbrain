#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    make_hmac_key
    make_memory proj-a nota-1 project
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null
    export OPENBRAIN_DOCTRINE_DIR="$HOME/.claude/doctrine"; mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_review" "$OPENBRAIN_DOCTRINE_DIR/_journal"
    cp "$REPO_ROOT/tests/fixtures/doctrine/alpha.md" "$OPENBRAIN_DOCTRINE_DIR/"
    export OPENBRAIN_TRIGGERS_CONF="$XDG_CACHE_HOME/openbrain/triggers.conf"; bash "$S/openbrain-triggers-compile.sh" --force
    export OPENBRAIN_CAPTURE_DIR="$XDG_STATE_HOME/openbrain/candidates"
    export OPENBRAIN_COLLECTION=c; export OPENBRAIN_WIKI_ROOT="$BATS_TEST_TMPDIR/wiki"; mkdir -p "$OPENBRAIN_WIKI_ROOT"
    export OPENBRAIN_CONFIG_FILE="$BATS_TEST_TMPDIR/openbrain.env"
    export PATH="$REPO_ROOT/tests/fixtures/fake-qmd:$PATH"
    touch "$HOME/.claude/refresh.toml"
}

@test "todo sano: rc 0 y cinco secciones" {
    run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 0 ]
    for s in Cerebro Memoria Doctrina Captura Aprendizaje; do [[ "$output" == *"== $s =="* ]]; done
    ! grep -qE '^\[(WARN|FAIL)\]' <<<"$output"
}

@test "HMAC roto: FAIL memoria, rc 1" {
    printf 'x\n' >> "$HOME/.claude/projects/proj-a/memory/nota-1.md"
    run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[FAIL\] memoria: HMAC .*FAIL=1' <<<"$output"
}

@test "coleccion configurada ausente del indice: FAIL cerebro" {
    FAKE_QMD_COLLECTIONS="otra  /x  3 docs" run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -q '^\[FAIL\] cerebro: colección "c" no existe' <<<"$output"
}

@test "qmd doctor con aspa: WARN cerebro" {
    FAKE_QMD_DOCTOR=$'✓ a\n✗ model cache: missing 1/3' run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -q '^\[WARN\] cerebro: qmd doctor: ✗ model cache' <<<"$output"
}

@test "memoria sin reviewed y mas vieja que STALE_DAYS: WARN con recuento" {
    touch -t 202501010000 "$HOME/.claude/projects/proj-a/memory/nota-1.md"
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null
    run env OPENBRAIN_STALE_DAYS=30 bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] memoria: 1 memoria(s) sin revisar desde hace >30 días' <<<"$output"
}

@test "triggers.conf desfasado: WARN doctrina; refresh.toml ausente: WARN" {
    sleep 1; touch "$OPENBRAIN_DOCTRINE_DIR/alpha.md"
    rm -f "$HOME/.claude/refresh.toml"
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] doctrina: triggers.conf desfasado' <<<"$output"
    grep -q '^\[WARN\] doctrina: ~/.claude/refresh.toml ausente' <<<"$output"
}

@test "review sin marcador .applied: WARN doctrina aunque haya cooldown posterior; con marcador, sin WARN" {
    mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01"; printf '# review\n' > "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/alpha.md"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review.alpha"
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] doctrina: review pendiente: alpha (2026-09-01)' <<<"$output"
    : > "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/.applied.alpha"
    run bash "$S/openbrain-doctor.sh"
    ! grep -q 'review pendiente' <<<"$output"
    sleep 1.1; printf '# review v2\n' > "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/alpha.md"
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] doctrina: review pendiente: alpha (2026-09-01)' <<<"$output"
}

@test "candidatos pendientes: WARN captura con recuento" {
    mkdir -p "$OPENBRAIN_CAPTURE_DIR"; printf '4' > "$OPENBRAIN_CAPTURE_DIR/.pending"
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] captura: 4 candidatos pendientes' <<<"$output"
}

@test "clave malformada en openbrain.env: WARN cerebro con numero de linea" {
    printf 'OPENBRAIN_OK=1\nnot a valid key=x\n' > "$OPENBRAIN_CONFIG_FILE"
    run bash "$S/openbrain-doctor.sh"
    grep -qE '^\[WARN\] cerebro: openbrain\.env: l.nea 2 no coincide con \^OPENBRAIN_' <<<"$output"
}

@test "variables del repo predecesor en el entorno: WARN cerebro con el nombre nuevo" {
    run env MEMORY_ROOT=/x STALE_DAYS=15 MEMORY_BACKUP_GPG=AAAA bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] cerebro: MEMORY_ROOT est. en el entorno y ya no se lee: renombrar a OPENBRAIN_MEMORY_ROOT$' <<<"$output"
    grep -qE '^\[WARN\] cerebro: STALE_DAYS .* OPENBRAIN_STALE_DAYS$' <<<"$output"
    grep -qE '^\[WARN\] cerebro: MEMORY_BACKUP_GPG .* OPENBRAIN_BACKUP_GPG$' <<<"$output"
    run bash "$S/openbrain-doctor.sh"
    ! grep -q 'ya no se lee' <<<"$output"
}

@test "doctor no escribe nada" {
    before="$(find "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" -type f -newer "$OPENBRAIN_TRIGGERS_CONF" | sort)"
    sleep 1; bash "$S/openbrain-doctor.sh" >/dev/null || true
    after="$(find "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" -type f -newer "$OPENBRAIN_TRIGGERS_CONF" | sort)"
    [ "$before" = "$after" ]
}

@test "eventos sin ningun bloque no cuentan como sesion con doctrina" {
    # [] de 0.4.0, [""] de 0.3.0, JSON con espacios editado a mano, y una linea rota
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"s1","event":"doctrine_extended","doctrines":[]}\n{"ts":"2026-09-01T10:01:00Z","session_id":"s2","event":"doctrine_extended","doctrines":[""]}\n{"ts": "2026-09-01T10:02:00Z", "session_id": "s3", "event": "doctrine_loaded", "doctrines": [ ]}\nno-es-json\n' \
        > "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl"
    run bash "$S/openbrain-doctor.sh"
    grep -qE '^\[OK\]   aprendizaje: todav.a sin sesiones con doctrina activa' <<<"$output"
    ! grep -qE '^\[WARN\] aprendizaje: .*<bloque>\.jsonl' <<<"$output"
}

@test "sesiones con doctrina y ningun journal de bloque: WARN aprendizaje" {
    # Firma exacta del bucle roto: session-doctrine registra, el Stop no escribe.
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"s1","event":"doctrine_loaded","doctrines":["alpha"]}\n' \
        > "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl"
    run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] aprendizaje: 1 sesi.n\(es\) con doctrina activa y ning.n <bloque>\.jsonl' <<<"$output"
}

@test "sesion solo con doctrine_extended cuenta para el journal, y una vez aunque repita eventos" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"s1","event":"doctrine_extended","doctrines":["alpha"]}\n{"ts":"2026-09-01T10:05:00Z","session_id":"s1","event":"doctrine_extended","doctrines":["alpha"]}\n' \
        > "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl"
    printf '{"ts":"2026-09-01T11:00:00Z","event":"session_close"}\n' > "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl"
    run bash "$S/openbrain-doctor.sh"
    grep -qE '^\[WARN\] aprendizaje: hay journal pero nunca se consolid' <<<"$output"
    grep -qE '^\[OK\]   aprendizaje: journal de 1 bloque\(s\) sobre 1 sesi.n\(es\)' <<<"$output"
}

@test "journal de bloque sin ninguna consolidacion: WARN aprendizaje" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"s1","event":"doctrine_loaded","doctrines":["alpha"]}\n' \
        > "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl"
    printf '{"ts":"2026-09-01T11:00:00Z","event":"session_close"}\n' > "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl"
    run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] aprendizaje: hay journal pero nunca se consolid' <<<"$output"
}

@test "el .last_review global de 0.2.0 no cuenta como consolidacion: WARN aprendizaje" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"s1","event":"doctrine_loaded","doctrines":["alpha"]}\n' \
        > "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl"
    printf '{"ts":"2026-09-01T11:00:00Z","event":"session_close"}\n' > "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review"
    run bash "$S/openbrain-doctor.sh"
    grep -qE '^\[WARN\] aprendizaje: hay journal pero nunca se consolid' <<<"$output"
}

@test "consolidacion ya hecha con journal presente: sin WARN de aprendizaje" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"s1","event":"doctrine_loaded","doctrines":["alpha"]}\n' \
        > "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl"
    printf '{"ts":"2026-09-01T11:00:00Z","event":"session_close"}\n' > "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl"
    mkdir -p "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01"; printf '# review\n' > "$OPENBRAIN_DOCTRINE_DIR/_review/2026-09-01/alpha.md"
    run bash "$S/openbrain-doctor.sh"
    ! grep -qE '^\[WARN\] aprendizaje: hay journal' <<<"$output"
    grep -qE '^\[OK\]   aprendizaje: journal de 1 bloque' <<<"$output"
}

@test "cooldown de .last_review sin revision generada: WARN aprendizaje" {
    printf '{"ts":"2026-09-01T10:00:00Z","session_id":"s1","event":"doctrine_loaded","doctrines":["alpha"]}\n' \
        > "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl"
    printf '{"ts":"2026-09-01T11:00:00Z","event":"session_close"}\n' > "$OPENBRAIN_DOCTRINE_DIR/_journal/alpha.jsonl"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$OPENBRAIN_DOCTRINE_DIR/_review/.last_review.alpha"
    run bash "$S/openbrain-doctor.sh"
    grep -qE '^\[WARN\] aprendizaje: hay journal pero nunca se consolid' <<<"$output"
}

@test "recall sin medir desde hace mas de OPENBRAIN_EVAL_MAX_AGE_DAYS: WARN aprendizaje" {
    export OPENBRAIN_EVAL_GOLDEN="$BATS_TEST_TMPDIR/golden.json"; printf '[]\n' > "$OPENBRAIN_EVAL_GOLDEN"
    export OPENBRAIN_EVAL_METRICS="$BATS_TEST_TMPDIR/metrics.log"; printf 'linea\n' > "$OPENBRAIN_EVAL_METRICS"
    touch -t 202501010000 "$OPENBRAIN_EVAL_METRICS"
    run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] aprendizaje: recall sin medir desde hace [0-9]+ d' <<<"$output"
}

@test "golden set sin metrics.log: WARN aprendizaje" {
    export OPENBRAIN_EVAL_GOLDEN="$BATS_TEST_TMPDIR/golden.json"; printf '[]\n' > "$OPENBRAIN_EVAL_GOLDEN"
    export OPENBRAIN_EVAL_METRICS="$BATS_TEST_TMPDIR/nunca-medido.log"
    run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] aprendizaje: hay golden set pero' <<<"$output"
}

@test "candidatos de captura a punto de caducar: WARN captura" {
    mkdir -p "$OPENBRAIN_CAPTURE_DIR"; printf '{}\n' > "$OPENBRAIN_CAPTURE_DIR/vieja.jsonl"
    touch -t 202501010000 "$OPENBRAIN_CAPTURE_DIR/vieja.jsonl"
    run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] captura: 1 fichero\(s\) de candidatos caducan' <<<"$output"
}

FAKE_AGE_RECIPIENT="age1acdefghjklmnpqrstuvwxyz023456789acdefghjklmnpqrstuvwxyz023"

@test "backup desactivado sin OPENBRAIN_BACKUP_AGE ni OPENBRAIN_BACKUP_GPG: OK sin warn" {
    run bash "$S/openbrain-doctor.sh"
    grep -qE '^\[OK\]   backup: desactivado \(OPENBRAIN_BACKUP_AGE y OPENBRAIN_BACKUP_GPG vacíos\)' <<<"$output"
}

@test "backup: planificador activo y archivo reciente, sin warn" {
    [ "$(uname -s)" = Linux ] || skip "rama systemd: solo Linux"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\ncase "$*" in\n  *"is-enabled openbrain-memory-backup.timer"*) exit 0 ;;\n  *) exit 1 ;;\nesac\n' > "$BIN/systemctl"
    chmod +x "$BIN/systemctl"
    export OPENBRAIN_BACKUP_AGE="$FAKE_AGE_RECIPIENT"
    export OPENBRAIN_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"; mkdir -p "$OPENBRAIN_BACKUP_DIR"
    : > "$OPENBRAIN_BACKUP_DIR/memory-20260101T000000Z.tar.gz.age"
    run env PATH="$BIN:$PATH" bash "$S/openbrain-doctor.sh"
    grep -qE '^\[OK\]   backup: planificador activo \(openbrain-memory-backup.timer\)' <<<"$output"
    grep -qE '^\[OK\]   backup: .ltimo archivo hace 0 d.a\(s\)' <<<"$output"
}

@test "backup: planificador no activo y sin archivos: WARN" {
    [ "$(uname -s)" = Linux ] || skip "rama systemd: solo Linux"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/systemctl"
    chmod +x "$BIN/systemctl"
    export OPENBRAIN_BACKUP_AGE="$FAKE_AGE_RECIPIENT"
    export OPENBRAIN_BACKUP_DIR="$BATS_TEST_TMPDIR/backups-vacio"
    run env PATH="$BIN:$PATH" bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] backup: planificador no activo \(openbrain install --apply\)' <<<"$output"
    grep -qE '^\[WARN\] backup: ning.n archivo en '"$OPENBRAIN_BACKUP_DIR" <<<"$output"
}

@test "backup: rama launchd, planificador cargado, sin warn" {
    [ "$(uname -s)" = Darwin ] || skip "rama launchd: solo macOS"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\ncase "$*" in\n  *"print gui/"*"com.openbrain.memory-backup"*) exit 0 ;;\n  *) exit 1 ;;\nesac\n' > "$BIN/launchctl"
    chmod +x "$BIN/launchctl"
    export OPENBRAIN_BACKUP_AGE="$FAKE_AGE_RECIPIENT"
    export OPENBRAIN_BACKUP_DIR="$BATS_TEST_TMPDIR/backups-mac"; mkdir -p "$OPENBRAIN_BACKUP_DIR"
    : > "$OPENBRAIN_BACKUP_DIR/memory-20260101T000000Z.tar.gz.age"
    run env PATH="$BIN:$PATH" bash "$S/openbrain-doctor.sh"
    grep -qE '^\[OK\]   backup: planificador activo \(com.openbrain.memory-backup\)' <<<"$output"
    grep -qE '^\[OK\]   backup: .ltimo archivo hace 0 d.a\(s\)' <<<"$output"
}

@test "backup: rama launchd, planificador no cargado y sin archivos: WARN" {
    [ "$(uname -s)" = Darwin ] || skip "rama launchd: solo macOS"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/launchctl"
    chmod +x "$BIN/launchctl"
    export OPENBRAIN_BACKUP_AGE="$FAKE_AGE_RECIPIENT"
    export OPENBRAIN_BACKUP_DIR="$BATS_TEST_TMPDIR/backups-mac-vacio"
    run env PATH="$BIN:$PATH" bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] backup: planificador no activo \(openbrain install --apply\)' <<<"$output"
    grep -qE '^\[WARN\] backup: ning.n archivo en '"$OPENBRAIN_BACKUP_DIR" <<<"$output"
}

@test "backup: archivo mas viejo que 2 dias: WARN con dias" {
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/systemctl"
    chmod +x "$BIN/systemctl"
    export OPENBRAIN_BACKUP_AGE="$FAKE_AGE_RECIPIENT"
    export OPENBRAIN_BACKUP_DIR="$BATS_TEST_TMPDIR/backups-viejo"; mkdir -p "$OPENBRAIN_BACKUP_DIR"
    : > "$OPENBRAIN_BACKUP_DIR/memory-vieja.tar.gz.gpg"
    touch -t 202001010000 "$OPENBRAIN_BACKUP_DIR/memory-vieja.tar.gz.gpg"
    run env PATH="$BIN:$PATH" bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -qE '^\[WARN\] backup: .ltimo archivo hace [0-9]+ d.as$' <<<"$output"
}

min_path() { # $1 destino, resto: herramientas a enlazar
    local dir="$1"; shift
    mkdir -p "$dir"
    local t src
    for t in "$@"; do src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$dir/$t"; done
}
BASE_TOOLS="bash env jq openssl find date wc grep sed awk tr basename dirname cat ls mktemp mv rm chmod stat readlink realpath sort head tail cut uname printf"

@test "sin xxd pero con python3: la firma se calcula igual, sin FAIL" {
    BIN="$BATS_TEST_TMPDIR/bin"
    # shellcheck disable=SC2086
    min_path "$BIN" $BASE_TOOLS od python3
    run env PATH="$BIN" bash "$S/openbrain-doctor.sh"
    grep -qE '^\[OK\]   memoria: firma HMAC por python3' <<<"$output"
    ! grep -qE '^\[FAIL\] memoria: sin python3' <<<"$output"
}

@test "sin python3 ni xxd: FAIL memoria, la firma no se puede calcular" {
    BIN="$BATS_TEST_TMPDIR/bin"
    # shellcheck disable=SC2086
    min_path "$BIN" $BASE_TOOLS od
    run env PATH="$BIN" bash "$S/openbrain-doctor.sh"
    grep -qE '^\[FAIL\] memoria: sin python3 y falta\(n\) para el shim en bash: xxd' <<<"$output"
}

@test "qmd doctor con aviso ⚠ (sin aspa): WARN cerebro, rc 1" {
    FAKE_QMD_DOCTOR=$'✓ a\n⚠ embedding freshness: 3 docs' run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -q '^\[WARN\] cerebro: qmd doctor: ⚠ embedding' <<<"$output"
}

@test "instalacion nueva: OPENBRAIN_MEMORY_ROOT existe sin ningun memory/ -> OK, sin FAIL HMAC" {
    export OPENBRAIN_MEMORY_ROOT="$BATS_TEST_TMPDIR/empty-root"
    mkdir -p "$OPENBRAIN_MEMORY_ROOT"
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[OK\]   memoria: todavía sin ningún memory/' <<<"$output"
    ! grep -q '^\[FAIL\] memoria: HMAC' <<<"$output"
}

@test "reviewed en el pasado cuenta como fecha de revision; reviewed de hoy ignora mtime viejo" {
    f="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    cat > "$f" <<'EOF'
---
name: nota-1
description: memoria sintética de test
type: project
reviewed: 2015-01-01
---

Contenido sintético. Ningún dato real.
EOF
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null
    run env OPENBRAIN_STALE_DAYS=30 bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] memoria: 1 memoria(s) sin revisar' <<<"$output"

    today="$(date -u +%Y-%m-%d)"
    cat > "$f" <<EOF
---
name: nota-1
description: memoria sintética de test
type: project
reviewed: $today
---

Contenido sintético. Ningún dato real.
EOF
    touch -t 202501010000 "$f"
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null
    run env OPENBRAIN_STALE_DAYS=30 bash "$S/openbrain-doctor.sh"
    ! grep -q 'memoria(s) sin revisar' <<<"$output"
}

@test "_global/memory por encima de 65536 bytes: WARN memoria" {
    make_memory _global big feedback
    G="$HOME/.claude/projects/_global/memory"
    head -c 70000 /dev/zero | tr '\0' 'x' >> "$G/big.md"
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] memoria: _global/memory inyecta' <<<"$output"
}

@test "OPENBRAIN_OTHER_COLLECTIONS incluye la coleccion configurada: WARN; sin coincidencia: OK" {
    run env OPENBRAIN_OTHER_COLLECTIONS="x, c" bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] cerebro: OPENBRAIN_COLLECTION "c" figura en OPENBRAIN_OTHER_COLLECTIONS' <<<"$output"
    run env OPENBRAIN_OTHER_COLLECTIONS="x y" bash "$S/openbrain-doctor.sh"
    grep -q '^\[OK\]   cerebro: otras colecciones' <<<"$output"
}

@test "triggers: kind desconocido WARN; solo manual sin warn de compilacion; indentacion de 4 compila" {
    cat > "$OPENBRAIN_DOCTRINE_DIR/gamma.md" <<'EOF'
---
name: gamma
description: bloque con kind invalido en triggers
triggers:
  cwds:
    - "**/gamma-zone/**"
  manual: "/doctrine gamma"
version: 1.0
---

# gamma
Contenido sintético.
EOF
    cat > "$OPENBRAIN_DOCTRINE_DIR/delta.md" <<'EOF'
---
name: delta
description: bloque solo con activacion manual
triggers:
  manual: "/doctrine delta"
version: 1.0
---

# delta
Contenido sintético.
EOF
    cat > "$OPENBRAIN_DOCTRINE_DIR/epsilon.md" <<'EOF'
---
name: epsilon
description: bloque con indentacion de 4 espacios
triggers:
    cwd:
        - "**/epsilon-zone/**"
version: 1.0
---

# epsilon
Contenido sintético.
EOF
    bash "$S/openbrain-triggers-compile.sh" --force
    run bash "$S/openbrain-doctor.sh"
    grep -q "^\[WARN\] doctrina: gamma: kind desconocido 'cwds'" <<<"$output"
    ! grep -q 'delta declara triggers' <<<"$output"
    ! grep -q 'epsilon declara triggers' <<<"$output"
}

make_fake_index() {
    local db="$1"; shift
    mkdir -p "$(dirname "$db")"
    python3 - "$db" "$@" <<'PY'
import sqlite3, sys
db = sys.argv[1]
rows = sys.argv[2:]
con = sqlite3.connect(db)
con.execute("create table documents(path TEXT, hash TEXT, collection TEXT, active INTEGER)")
for i in range(0, len(rows), 2):
    con.execute("insert into documents values (?,?,?,?)", (rows[i], rows[i+1], "c", 1))
con.commit(); con.close()
PY
}

@test "indice desfasado: WARN por hash distinto, sin indexar e indexado ausente del disco" {
    printf 'contenido a\n' > "$OPENBRAIN_WIKI_ROOT/a.md"
    printf 'contenido b\n' > "$OPENBRAIN_WIKI_ROOT/b.md"
    make_fake_index "$XDG_CACHE_HOME/qmd/index.sqlite" a.md wronghash gone.md h
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[WARN\] cerebro: aviso — modificados sin reindexar: a.md' <<<"$output"
    grep -q '^\[WARN\] cerebro: aviso — sin indexar: b.md' <<<"$output"
    grep -q '^\[WARN\] cerebro: aviso — indexados pero ausentes del disco: gone.md' <<<"$output"
}

@test "indice al dia: hash correcto y sin ficheros extra -> OK" {
    printf 'contenido a\n' > "$OPENBRAIN_WIKI_ROOT/a.md"
    h="$(sha256sum "$OPENBRAIN_WIKI_ROOT/a.md" | cut -d' ' -f1)"
    make_fake_index "$XDG_CACHE_HOME/qmd/index.sqlite" a.md "$h"
    run bash "$S/openbrain-doctor.sh"
    grep -q '^\[OK\]   cerebro: índice al día con la wiki' <<<"$output"
    ! grep -q 'aviso — ' <<<"$output"
}

@test "python3 sin tomllib (<3.11): WARN doctrina, refresh-doctrine no corre" {
    STUB="$BATS_TEST_TMPDIR/py-bin"; mkdir -p "$STUB"
    cat > "$STUB/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in *tomllib*) echo "ModuleNotFoundError: No module named 'tomllib'" >&2; exit 1 ;; esac
exec "$(command -v python3)" "\$@"
EOF
    chmod +x "$STUB/python3"
    PATH="$STUB:$PATH" run bash "$S/openbrain-doctor.sh"
    [ "$status" -eq 1 ]
    grep -q '^\[WARN\] doctrina: python3 sin tomllib' <<<"$output"
    run bash "$S/openbrain-doctor.sh"
    ! grep -q 'sin tomllib' <<<"$output"
}
