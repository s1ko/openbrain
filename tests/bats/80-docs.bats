#!/usr/bin/env bats
load helpers

@test "README documenta cada comando y cada op de memoria" {
    for c in doctor recall ingest eval review capture memory install; do grep -q "openbrain:$c\|openbrain $c" "$REPO_ROOT/README.md"; done
}
@test "toda OPENBRAIN_* de config.sh aparece en openbrain.env.example" {
    while IFS= read -r v; do grep -q "^$v=" "$REPO_ROOT/install/env/openbrain.env.example" || { echo "falta $v en el ejemplo"; false; }; done \
      < <(grep -oE '\$\{OPENBRAIN_[A-Z0-9_]+:=' "$REPO_ROOT/scripts/lib/config.sh" | sed 's/[${:=]//g' | grep -vE 'OPENBRAIN_(TRIGGERS_CONF|REVIEW_SKIP|CAPTURE_DIR|GLOBAL_MEMORY)' | sort -u)
    # OPENBRAIN_COLLECTION usa '=' (vacio explicito = sin scope) y el grep de arriba no la ve.
    grep -q '^OPENBRAIN_COLLECTION=' "$REPO_ROOT/install/env/openbrain.env.example"
}
@test "plantillas con frontmatter" { for t in memory wiki-article doctrine-block; do head -1 "$REPO_ROOT/templates/$t.md" | grep -qx -- '---'; done; }
@test "docs vivos sin rutas del host ni del repo antiguo (docs/history queda fuera)" { ! grep -rnE --exclude-dir=history '/Users/[A-Za-z0-9_-]{2,}|/home/[A-Za-z0-9_-]{2,}/|claude-memory-docs' "$REPO_ROOT/README.md" "$REPO_ROOT/INSTALL.md" "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/templates" "$REPO_ROOT/docs" "$REPO_ROOT/commands" "$REPO_ROOT/skills" | grep -v 'continuación de'; }
@test "no queda arqueologia privada: docs/history fuera y sin enlaces" {
    [ ! -e "$REPO_ROOT/docs/history" ]
    ! grep -rnE 'docs/(0[1-6]-|08-|ACCEPTANCE|superpowers|history)|\bbench/' "$REPO_ROOT/README.md" "$REPO_ROOT/INSTALL.md" "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/docs"
}
@test "cada plantilla de install/ la cita INSTALL.md o openbrain-install.sh" {
    while IFS= read -r f; do
        grep -qF "${f##*/}" "$REPO_ROOT/INSTALL.md" "$REPO_ROOT/scripts/openbrain-install.sh" || { echo "sin referencia: $f"; false; }
    done < <(find "$REPO_ROOT/install" -type f)
}
