#!/usr/bin/env bats
load helpers

@test "cada skill tiene SKILL.md con name y description" {
    for d in "$REPO_ROOT"/skills/*/; do
        f="$d/SKILL.md"; [ -f "$f" ] || { echo "falta $f"; false; }
        head -1 "$f" | grep -qx -- '---'
        grep -q '^name: ' "$f"; grep -q '^description: ' "$f"
        [ "$(grep -c '^name: ' "$f")" = 1 ]
    done
}

@test "ningun skill/command/agent referencia rutas del repo antiguo ni del host" {
    ! grep -rnE 'claude-memory-docs|/Users/|/home/[a-z]+/' "$REPO_ROOT/skills" "$REPO_ROOT/commands" "$REPO_ROOT/agents"
}

@test "el agente tiene frontmatter name/description/tools" {
    f="$REPO_ROOT/agents/librarian.md"; grep -q '^name: librarian' "$f"; grep -q '^description: ' "$f"; grep -q '^tools: ' "$f"
}

@test "no queda skill.md en minuscula" {
    [ -z "$(find "$REPO_ROOT/skills" -name 'skill.md')" ]
}
