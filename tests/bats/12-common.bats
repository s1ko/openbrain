#!/usr/bin/env bats
load helpers

setup() {
    setup_fake_home
    C="$REPO_ROOT/scripts/lib/common.sh"
    P="$REPO_ROOT/scripts/lib/portable.sh"
}

run_c() { run bash -c "source '$C'; $*"; }

@test "brain_sid_ok acepta el alfabeto de fichero y rechaza rutas y '..'" {
    run_c 'brain_sid_ok "abc-1.2_x" && echo ok'
    [ "$output" = "ok" ]
    run_c 'brain_sid_ok "a/b" || echo bad; brain_sid_ok "a..b" || echo bad; brain_sid_ok "" || echo bad; brain_sid_ok "a b" || echo bad'
    [ "$output" = "$(printf 'bad\nbad\nbad\nbad')" ]
}

@test "memory_index_link_target extrae el enlace y rechaza lineas sangradas o sin enlace" {
    run_c 'memory_index_link_target "- [Titulo x](feedback_a.md) — hook (2026-01-01)"'
    [ "$output" = "feedback_a.md" ]
    run_c 'memory_index_link_target "  - [x](y.md)" || echo none; memory_index_link_target "# MEMORY.md" || echo none'
    [ "$output" = "$(printf 'none\nnone')" ]
}

@test "resolve_memdirs ignora un directorio de proyecto que sea symlink" {
    make_memory proj-real a
    mkdir -p "$BATS_TEST_TMPDIR/outside/memory"
    ln -s "$BATS_TEST_TMPDIR/outside" "$HOME/.claude/projects/proj-link"
    run_c "resolve_memdirs '$HOME/.claude/projects'"
    [[ "$output" == *"proj-real/memory"* ]]
    [[ "$output" != *"proj-link"* ]]
}

@test "hmac_write_sidecar crea el sidecar en 600 y no lo reescribe si no cambia" {
    make_hmac_key
    f="$BATS_TEST_TMPDIR/m.md"; printf 'hola\n' > "$f"
    run_c "hmac_write_sidecar '$HOME/.config/claude/memory.hmac' '$f' && p_stat_perms '$f.hmac'"
    [ "$status" -eq 0 ]
    [ "$output" = "600" ]
    [ -s "$f.hmac" ]
    before="$(stat -c %i "$f.hmac" 2>/dev/null || stat -f %i "$f.hmac")"
    run_c "hmac_write_sidecar '$HOME/.config/claude/memory.hmac' '$f'"
    [ "$status" -eq 0 ]
    after="$(stat -c %i "$f.hmac" 2>/dev/null || stat -f %i "$f.hmac")"
    [ "$before" = "$after" ]
}

@test "hmac_write_sidecar falla con aviso si la clave es inutilizable" {
    f="$BATS_TEST_TMPDIR/m.md"; printf 'hola\n' > "$f"
    run_c "hmac_write_sidecar '$HOME/.config/claude/memory.hmac' '$f'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HMAC key unusable"* ]]
    [ ! -e "$f.hmac" ]
}

@test "brain_nonce sin openssl usa /dev/urandom: 16 hex" {
    bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
    for t in bash dirname head od tr; do ln -s "$(command -v "$t")" "$bin/$t"; done
    run bash -c "PATH='$bin' source '$C'; brain_nonce"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{16}$ ]]
}

@test "portable.sh no sondea al cargar: la deteccion es perezosa por herramienta" {
    run bash -c "source '$P'; printf '%s|%s|%s' \"\${_P_STAT:-}\" \"\${_P_DATE:-}\" \"\${_P_B64:-}\"; p_stat_perms '$P' >/dev/null; printf '|%s|%s' \"\${_P_STAT:-}\" \"\${_P_DATE:-}\""
    [ "$status" -eq 0 ]
    [[ "$output" == "|||"* ]]
    [[ "$output" == *"|stat|" || "$output" == *"|gstat|" ]]
}

@test "OPENBRAIN_PORTABLE_FORCE=bsd fija los binarios BSD sin sondear" {
    run bash -c "OPENBRAIN_PORTABLE_FORCE=bsd source '$P'; _p_stat; _p_date; _p_b64; printf '%s %s %s %s' \"\$_P_STAT\" \"\$_P_DATE\" \"\$_P_B64\" \"\$_P_STAT_GNU\""
    [ "$output" = "/usr/bin/stat /bin/date /usr/bin/base64 0" ]
}

@test "el shim HMAC en bash calcula los pads una vez por clave" {
    command -v xxd >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || skip "sin xxd/openssl"
    run bash -c "source '$C'; od() { echo od >> '$BATS_TEST_TMPDIR/od.log'; command od \"\$@\"; }; _hmac_stdin_bash 'una-clave-de-prueba-larga' < <(printf x) >/dev/null; _hmac_stdin_bash 'una-clave-de-prueba-larga' < <(printf y) >/dev/null; wc -l < '$BATS_TEST_TMPDIR/od.log' | tr -d ' '"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "memory_review_epoch: reviewed pasado usa esa fecha; futuro, ausente o invalido usan mtime" {
    f="$BATS_TEST_TMPDIR/m.md"

    cat > "$f" <<'EOF'
---
name: m
description: x
type: project
reviewed: 2015-01-01
---

x
EOF
    expect="$(bash -c "source '$P'; p_date_to_epoch 2015-01-01")"
    run_c "memory_review_epoch '$f'"
    [ "$output" = "$expect" ]

    cat > "$f" <<'EOF'
---
name: m
description: x
type: project
reviewed: 2099-01-01
---

x
EOF
    mt="$(bash -c "source '$P'; p_stat_mtime '$f'")"
    run_c "memory_review_epoch '$f'"
    [ "$output" = "$mt" ]

    cat > "$f" <<'EOF'
---
name: m
description: x
type: project
---

x
EOF
    mt="$(bash -c "source '$P'; p_stat_mtime '$f'")"
    run_c "memory_review_epoch '$f'"
    [ "$output" = "$mt" ]

    cat > "$f" <<'EOF'
---
name: m
description: x
type: project
reviewed: 2026-02-30
---

x
EOF
    mt="$(bash -c "source '$P'; p_stat_mtime '$f'")"
    run_c "memory_review_epoch '$f'"
    [ "$output" = "$mt" ]
}

@test "el shim HMAC en bash coincide con python3" {
    command -v xxd >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || skip "sin xxd/openssl/python3"
    run bash -c "source '$C'; a=\$(printf 'contenido' | _hmac_stdin_bash 'una-clave-de-prueba-larga'); b=\$(printf 'contenido' | hmac_stdin 'una-clave-de-prueba-larga'); [ \"\$a\" = \"\$b\" ] && echo same"
    [ "$output" = "same" ]
}

@test "toda lib de scripts/lib lleva guarda de doble carga y un source repetido no rompe" {
    for f in "$REPO_ROOT"/scripts/lib/*.sh; do
        grep -qE '^_OPENBRAIN_[A-Z]+_LOADED=1$' "$f" || { echo "sin guarda: $f"; false; }
    done
    run_c "source '$C'; declare -F hmac_stdin >/dev/null && echo ok"
    [ "$output" = "ok" ]
}
