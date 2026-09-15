#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"; H="$REPO_ROOT/hooks"

setup() {
    setup_fake_home
    make_hmac_key
    make_memory proj-a nota-1 project
    make_memory proj-a nota-2 feedback
    make_memory proj-b nota-3 reference
}

@test "lint-memory: arbol valido -> rc 0" {
    run bash "$S/lint-memory.sh" "$HOME/.claude/projects"
    [ "$status" -eq 0 ]
}

@test "lint-memory: type invalido -> FAIL y rc!=0" {
    make_memory proj-c mala bogus
    run bash "$S/lint-memory.sh" "$HOME/.claude/projects/proj-c/memory"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid type 'bogus'"* ]]
}

# R4: no se retira /opt/homebrew/bin del PATH (rompería Linux). En su lugar
# se construye un PATH mínimo con symlinks solo a las herramientas que el
# script necesita, sin gitleaks, y se ejecuta con ese PATH.
build_no_gitleaks_path() {
    local dir="$1" tool t
    mkdir -p "$dir"
    for tool in bash awk sed grep cat dirname basename readlink realpath stat \
                date mktemp wc sort find head tail tr cut printf env od xxd \
                openssl jq; do
        t="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$t" "$dir/$tool"
    done
}

@test "lint-memory: sin gitleaks -> falla cerrado" {
    local pathdir="$BATS_TEST_TMPDIR/no-gitleaks-bin"
    build_no_gitleaks_path "$pathdir"
    run env PATH="$pathdir" bash "$S/lint-memory.sh" "$HOME/.claude/projects"
    [ "$status" -ne 0 ]
    [[ "$output" == *"gitleaks not installed"* ]]
}

@test "verify-memory-hmac: sign luego verify -> todo OK" {
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/projects/proj-a/memory/nota-1.md.hmac" ]
    [ -f "$HOME/.claude/projects/proj-a/memory/MEMORY.md.hmac" ]
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" verify
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAIL"* ]]
    mtime1="$(bash -c "source '$S/lib/common.sh'; p_stat_mtime '$HOME/.claude/projects/proj-a/memory/nota-1.md.hmac'")"
    sleep 1
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign
    [ "$status" -eq 0 ]
    mtime2="$(bash -c "source '$S/lib/common.sh'; p_stat_mtime '$HOME/.claude/projects/proj-a/memory/nota-1.md.hmac'")"
    [ "$mtime1" = "$mtime2" ]
}

@test "hmac_files: una ruta con bytes no UTF-8 no rompe la firma en lote" {
    require_non_utf8_names
    bad="$HOME/.claude/projects/proj-a/memory/$(printf 'nota-\377.md')"
    cp "$HOME/.claude/projects/proj-a/memory/nota-1.md" "$bad"
    run bash -c "source '$S/lib/common.sh'; printf '%s\n' '$HOME/.claude/projects/proj-a/memory/nota-1.md' \"\$1\" | PYTHONIOENCODING=utf-8:strict hmac_files '$HOME/.config/claude/memory.hmac'" _ "$bad"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" = 2 ]
    [[ "$output" != *$'\t-'* ]]
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign
    [ "$status" -eq 0 ]
    [ -f "$bad.hmac" ]
}

@test "verify-memory-hmac: modificar tras firmar -> FAIL" {
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null
    printf 'tampered\n' >> "$HOME/.claude/projects/proj-a/memory/nota-1.md"
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"*"nota-1.md"* ]]
}

@test "verify-memory-hmac: clave con permisos laxos -> rc 2, no firma" {
    chmod 644 "$HOME/.config/claude/memory.hmac"
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign
    [ "$status" -eq 2 ]
    [[ "$output" == *"loose permissions"* ]]
    [ ! -f "$HOME/.claude/projects/proj-a/memory/nota-1.md.hmac" ]
}

@test "mark-reviewed inserta reviewed y update-memory-index lo respeta" {
    f="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    run bash "$S/mark-reviewed.sh" "$f" 2026-01-15
    [ "$status" -eq 0 ]
    grep -q '^reviewed: 2026-01-15$' "$f"
    run env OPENBRAIN_STALE_DAYS=30 bash "$S/update-memory-index.sh" "$HOME/.claude/projects"
    [ "$status" -eq 0 ]
    grep -q 'nota-1' "$HOME/.claude/projects/proj-a/memory/MEMORY.md"
    grep -qi 'stale' "$HOME/.claude/projects/proj-a/memory/MEMORY.md"
}

@test "memory-metrics lista los tres memory/ con bytes" {
    run bash "$S/memory-metrics.sh" "$HOME/.claude/projects"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj-a"* ]]
    [[ "$output" == *"proj-b"* ]]
}

@test "lint-memory: fichero individual valido -> rc 0" {
    run bash "$S/lint-memory.sh" "$HOME/.claude/projects/proj-a/memory/nota-1.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"→ $HOME/.claude/projects/proj-a/memory/nota-1.md"* ]]
}

@test "lint-memory: fichero individual con type invalido -> FAIL rc 2" {
    make_memory proj-c mala bogus
    run bash "$S/lint-memory.sh" "$HOME/.claude/projects/proj-c/memory/mala.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid type 'bogus'"* ]]
}

@test "lint-memory: fichero individual con ruta prohibida -> WARN rc 1" {
    f="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    printf '\n~/.ssh/id_rsa\n' >> "$f"
    run bash "$S/lint-memory.sh" "$f"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARN"* ]]
}

@test "verify-memory-hmac: fichero individual -> firma solo ese fichero" {
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects/proj-a/memory/nota-1.md" sign
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/projects/proj-a/memory/nota-1.md.hmac" ]
    [ ! -f "$HOME/.claude/projects/proj-a/memory/nota-2.md.hmac" ]
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects/proj-a/memory/nota-1.md" verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"*"nota-1.md"* ]]
}

@test "verify-memory hook: solo firma el fichero editado, vecino invalido no bloquea" {
    make_memory proj-h ok project
    make_memory proj-h bad bogus
    f="$HOME/.claude/projects/proj-h/memory/ok.md"
    payload="$(jq -cn --arg p "$f" '{tool_input:{file_path:$p}}')"
    run bash -c "printf '%s' '$payload' | bash '$H/verify-memory.sh'"
    [ "$status" -eq 0 ]
    [ -f "$f.hmac" ]
    [ ! -f "$HOME/.claude/projects/proj-h/memory/bad.md.hmac" ]
}

@test "verify-memory-hmac: clave es symlink -> rc 2, no firma" {
    rm -f "$HOME/.config/claude/memory.hmac"
    real="$BATS_TEST_TMPDIR/real.hmac"
    head -c 32 /dev/urandom | base64 > "$real"
    chmod 600 "$real"
    ln -s "$real" "$HOME/.config/claude/memory.hmac"
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign
    [ "$status" -eq 2 ]
    [[ "$output" == *"is a symlink"* ]]
    [ ! -f "$HOME/.claude/projects/proj-a/memory/nota-1.md.hmac" ]
}

@test "lint-memory: oculto .md con frontmatter invalido -> FAIL" {
    d="$HOME/.claude/projects/proj-a/memory"
    printf 'sin frontmatter\n' > "$d/.hidden.md"
    run bash "$S/lint-memory.sh" "$HOME/.claude/projects/proj-a/memory"
    [ "$status" -ne 0 ]
    [[ "$output" == *".hidden.md"* ]]
}

@test "lint-memory: referencia a .netrc -> WARN rc 1" {
    f="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    printf '\nver ~/.netrc para credenciales\n' >> "$f"
    run bash "$S/lint-memory.sh" "$HOME/.claude/projects/proj-a/memory"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARN"*".netrc"* ]]
}

@test "update-memory-index: invocacion directa sobre un memdir estampa ese indice" {
    make_memory p uno project
    run bash "$S/update-memory-index.sh" "$HOME/.claude/projects/p/memory"
    [ "$status" -eq 0 ]
    grep -q 'uno' "$HOME/.claude/projects/p/memory/MEMORY.md"
    grep -qE '\([0-9]{4}-[0-9]{2}-[0-9]{2}\)' "$HOME/.claude/projects/p/memory/MEMORY.md"
}

@test "update-memory-index: raiz vacia -> rc 2" {
    empty="$BATS_TEST_TMPDIR/empty-root"
    mkdir -p "$empty"
    run bash "$S/update-memory-index.sh" "$empty"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no memory directories found"* ]]
}

@test "update-memory-index: la regex de fecha replica al sed viejo (con y sin sufijo)" {
    # Verifica que la extraccion en bash puro (fix 7c) da el mismo resultado
    # que el sed -E que sustituye, para lineas con y sin sufijo de fecha.
    stale_re='^(.*[^[:space:]])[[:space:]]*\ \(([0-9]{4}-[0-9]{2}-[0-9]{2})(,\ stale)?\)$'
    for line in '- [x](x.md) — t (2026-01-01)' '- [x](x.md) — t (2026-01-01, stale)' '- [x](x.md) — t sin fecha'; do
        old="$(printf '%s' "$line" | sed -E 's/[[:space:]]*\([0-9]{4}-[0-9]{2}-[0-9]{2}(, stale)?\)$//')"
        if [[ "$line" =~ $stale_re ]]; then new="${BASH_REMATCH[1]}"; else new="$line"; fi
        [ "$old" = "$new" ]
    done
}

@test "dedupe-global-memory-index: linea local sin fichero se quita en --apply, firma queda valida" {
    G="$HOME/.claude/projects/_global/memory"; mkdir -p "$G"
    cat > "$G/feedback_x.md" <<'EOF'
---
name: feedback_x
description: memoria global sintetica
type: feedback
---

GLOBAL-X sintetico
EOF
    printf '# MEMORY.md\n- [g](feedback_x.md) — g\n' > "$G/MEMORY.md"

    mkdir -p "$HOME/.claude/projects/proj-z/memory"
    printf '# MEMORY.md\n- [x](feedback_x.md) — t\n' > "$HOME/.claude/projects/proj-z/memory/MEMORY.md"
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects/proj-z/memory" sign >/dev/null
    before="$(cat "$HOME/.claude/projects/proj-z/memory/MEMORY.md")"

    run bash "$S/dedupe-global-memory-index.sh" "$HOME/.claude/projects"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would remove"* ]]
    [ "$(cat "$HOME/.claude/projects/proj-z/memory/MEMORY.md")" = "$before" ]

    run bash "$S/dedupe-global-memory-index.sh" "$HOME/.claude/projects" --apply
    [ "$status" -eq 0 ]
    ! grep -q 'feedback_x' "$HOME/.claude/projects/proj-z/memory/MEMORY.md"

    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects/proj-z/memory" verify
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAIL"* ]]
}

@test "memory-metrics: columna sig Y/- y cwd resuelta via .claude.json" {
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects/proj-a/memory/nota-1.md" sign >/dev/null
    slug="$(bash -c "source '$S/lib/common.sh'; path_to_slug '/synthetic/proj-cwd'")"
    mkdir -p "$HOME/.claude/projects/$slug/memory"
    make_memory "$slug" nota-cwd project
    printf '{"projects":{"/synthetic/proj-cwd":{}}}' > "$HOME/.claude.json"

    run bash "$S/memory-metrics.sh" "$HOME/.claude/projects"
    [ "$status" -eq 0 ]
    signed_line="$(printf '%s\n' "$output" | grep 'nota-1')"
    [[ "$signed_line" =~ [[:space:]]Y[[:space:]] ]]
    unsigned_line="$(printf '%s\n' "$output" | grep 'nota-2')"
    [[ "$unsigned_line" =~ [[:space:]]-[[:space:]] ]]
    [[ "$output" == *"/synthetic/proj-cwd"* ]]
}

@test "memory-metrics: raiz inexistente -> rc 2" {
    run bash "$S/memory-metrics.sh" "$BATS_TEST_TMPDIR/no-existe"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not found"* ]]
}

build_no_python_path() {
    local dir="$1" tool t
    mkdir -p "$dir"
    for tool in bash cat mktemp chmod mv rm openssl xxd od awk tr grep stat date sort head tail printf \
                dirname basename readlink realpath; do
        t="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$t" "$dir/$tool"
    done
}

@test "lint-memory: entrada de indice a fichero inexistente -> WARN, rc 1" {
    d="$HOME/.claude/projects/proj-a/memory"
    printf -- '- [gone](gone.md) — x\n' >> "$d/MEMORY.md"
    run bash "$S/lint-memory.sh" "$d"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARN index entry points to a missing file: gone.md"* ]]
}

@test "lint-memory: entrada de indice existente o con / no genera WARN" {
    d="$HOME/.claude/projects/proj-a/memory"
    grep -q 'nota-1' "$d/MEMORY.md"
    printf -- '- [otro](sub/otro.md) — con slash\n' >> "$d/MEMORY.md"
    run bash "$S/lint-memory.sh" "$d"
    [[ "$output" != *"missing file"* ]]
}

@test "hmac_write_sidecar firma y verify-memory-hmac ve OK; sidecar corrupto se reescribe y verify vuelve a OK" {
    f="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    run bash -c "source '$S/lib/common.sh'; hmac_write_sidecar '$HOME/.config/claude/memory.hmac' '$f'"
    [ "$status" -eq 0 ]
    run bash "$S/verify-memory-hmac.sh" "$f" verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"*"nota-1.md"* ]]

    printf 'garbage-not-a-real-signature\n' > "$f.hmac"
    run bash -c "source '$S/lib/common.sh'; hmac_write_sidecar '$HOME/.config/claude/memory.hmac' '$f'"
    [ "$status" -eq 0 ]
    run bash "$S/verify-memory-hmac.sh" "$f" verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"*"nota-1.md"* ]]
}

@test "verify-memory-hmac: firma sin python3 en PATH, verify normal -> OK" {
    pathdir="$BATS_TEST_TMPDIR/no-python-bin"
    build_no_python_path "$pathdir"
    [ -x "$pathdir/xxd" ] || skip "sin xxd en este host"
    run env PATH="$pathdir" bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/projects/proj-a/memory/nota-1.md.hmac" ]
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" verify
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAIL"* ]]
    [[ "$output" == *"OK"* ]]
}
