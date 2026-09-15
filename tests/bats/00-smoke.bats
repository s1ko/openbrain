#!/usr/bin/env bats
load helpers

setup() { setup_fake_home; }

@test "helpers: HOME apunta al tmpdir, no al real" {
    [[ "$HOME" == "$BATS_TEST_TMPDIR"/* ]]
    [ -d "$HOME/.claude/projects" ]
}

@test "helpers: make_memory crea frontmatter valido" {
    make_memory proj-a nota-1 feedback
    run head -1 "$HOME/.claude/projects/proj-a/memory/nota-1.md"
    [ "$status" -eq 0 ]
    [ "$output" = "---" ]
    grep -q '^type: feedback$' "$HOME/.claude/projects/proj-a/memory/nota-1.md"
}

@test "helpers: hook_json produce JSON con los campos pedidos" {
    run hook_json UserPromptSubmit sid-1 prompt="hola"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .prompt)" = "hola" ]
    [ "$(printf '%s' "$output" | jq -r .session_id)" = "sid-1" ]
}
