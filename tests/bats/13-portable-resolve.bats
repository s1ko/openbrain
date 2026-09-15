#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"; H="$REPO_ROOT/hooks"

# readlink sin -f, como macOS anterior a 12.3 y los BSD sin coreutils.
# Solo se sustituye readlink: realpath y python3 siguen en el PATH, que es
# la cadena de p_abspath.
setup() {
    setup_fake_home
    make_hmac_key
    make_memory proj-a nota-1 project
    STUB="$BATS_TEST_TMPDIR/stub-bin"; mkdir -p "$STUB"
    cat > "$STUB/readlink" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in -*f*) echo "readlink: illegal option -- f" >&2; exit 1 ;; esac; done
exec "$(command -v readlink)" "\$@"
EOF
    chmod +x "$STUB/readlink"
    export PATH="$STUB:$PATH"
}

@test "el stub rechaza -f y acepta la forma llana" {
    run readlink -f "$HOME"
    [ "$status" -ne 0 ]
    ln -s "$HOME/.config" "$BATS_TEST_TMPDIR/l"
    run readlink "$BATS_TEST_TMPDIR/l"
    [ "$status" -eq 0 ]; [ "$output" = "$HOME/.config" ]
}

@test "sin readlink -f: los scripts resuelven su raiz desde otro cwd" {
    for s in lint-memory verify-memory-hmac update-memory-index memory-metrics dedupe-global-memory-index; do
        run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$S/$s.sh' '$HOME/.claude/projects'"
        [[ "$output" != *"lib/common.sh"* ]] || { echo "$s: $output"; false; }
    done
    run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$S/lint-memory.sh' '$HOME/.claude/projects'"
    [ "$status" -eq 0 ]
}

@test "sin readlink -f: los scripts resuelven su raiz a traves de un symlink" {
    mkdir -p "$HOME/l"; ln -s "$S/lint-memory.sh" "$HOME/l/lint-memory.sh"
    run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$HOME/l/lint-memory.sh' '$HOME/.claude/projects'"
    [ "$status" -eq 0 ]
}

@test "sin readlink -f: el hook verify-memory sigue firmando" {
    f="$HOME/.claude/projects/proj-a/memory/nota-1.md"
    payload="$(jq -cn --arg p "$f" '{tool_input:{file_path:$p}}')"
    run bash -c "printf '%s' '$payload' | bash '$H/verify-memory.sh'"
    [ "$status" -eq 0 ]
    [ -f "$f.hmac" ]
}

@test "readlink -f solo vive en p_abspath" {
    run grep -rl 'readlink -f' "$S" "$H" "$REPO_ROOT/bin" "$REPO_ROOT/eval"
    [ "$output" = "$S/lib/portable.sh" ]
}

@test "por symlink, los scripts de bin/openbrain no cargan una lib plantada al lado" {
    mkdir -p "$HOME/l/lib"
    printf 'brain_config_dump() { echo impostora; }\n' > "$HOME/l/lib/common.sh"
    ln -sf "$S/openbrain-config.sh" "$HOME/l/openbrain-config.sh"
    run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$HOME/l/openbrain-config.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" != *impostora* ]]
    grep -q '^OPENBRAIN_MEMORY_ROOT=' <<<"$output"
}

@test "ningun ejecutable compone su raiz desde BASH_SOURCE sin resolver symlinks" {
    run grep -rl --exclude-dir=lib 'dirname "${BASH_SOURCE\[0\]}"' "$S" "$H" "$REPO_ROOT/bin" "$REPO_ROOT/eval"
    [ -z "$output" ] || { echo "sin resolver: $output"; false; }
}
