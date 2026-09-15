#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    make_hmac_key
}

@test "mark-reviewed sobre memoria sin firmar avisa en stderr y sale 0" {
    make_memory proj-a nota-1 project
    f="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    [ ! -f "$f.hmac" ]
    run bash "$S/mark-reviewed.sh" "$f" 2026-01-15
    [ "$status" -eq 0 ]
    [[ "$output" == *"no HMAC sidecar"* ]]
    grep -q '^reviewed: 2026-01-15$' "$f"
    [ ! -f "$f.hmac" ]
}

@test "mark-reviewed sobre memoria firmada re-firma y verify-memory-hmac la ve OK" {
    make_memory proj-a nota-2 project
    f="$HOME/.claude/projects/proj-a/memory/nota-2.md"
    bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" sign >/dev/null
    [ -f "$f.hmac" ]
    run bash "$S/mark-reviewed.sh" "$f" 2026-01-16
    [ "$status" -eq 0 ]
    grep -q '^reviewed: 2026-01-16$' "$f"
    run bash "$S/verify-memory-hmac.sh" "$HOME/.claude/projects" verify
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAIL"* ]]
}
