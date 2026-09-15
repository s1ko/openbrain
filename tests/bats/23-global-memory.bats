#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"; H="$REPO_ROOT/hooks"

setup() {
    setup_fake_home
    make_hmac_key
    export G="$HOME/.claude/projects/_global/memory"; mkdir -p "$G"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        printf -- '---\nname: g%s\ndescription: d\ntype: feedback\n---\n\nGLOBAL-SINTETICA-%s\n' "$i" "$i" > "$G/g$i.md"
    done
    printf '# MEMORY.md\n- [g1](g1.md) - INDICE-SINTETICO\n' > "$G/MEMORY.md"
    bash "$S/verify-memory-hmac.sh" "$G" sign >/dev/null
}

@test "load-global-memory verifica todo el directorio con una sola invocacion de python3" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\necho x >> "%s/py.calls"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$(command -v python3)" > "$BATS_TEST_TMPDIR/bin/python3"
    chmod +x "$BATS_TEST_TMPDIR/bin/python3"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "echo '{}' | bash '$H/load-global-memory.sh'"
    [ "$status" -eq 0 ]
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"GLOBAL-SINTETICA-1"* ]]; [[ "$ac" == *"GLOBAL-SINTETICA-12"* ]]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/py.calls" | tr -d ' ')" = 1 ]
}

@test "load-global-memory excluye lo manipulado o sin firma, avisa y conserva el resto en orden" {
    printf '\nMANIPULADA\n' >> "$G/g5.md"
    rm -f "$G/g7.md.hmac"
    run bash -c "echo '{}' | bash '$H/load-global-memory.sh' 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -eq 0 ]
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" != *"MANIPULADA"* ]]; [[ "$ac" != *"GLOBAL-SINTETICA-5"* ]]; [[ "$ac" != *"GLOBAL-SINTETICA-7"* ]]
    [[ "$ac" == *"GLOBAL-SINTETICA-4"* ]]; [[ "$ac" == *"GLOBAL-SINTETICA-6"* ]]; [[ "$ac" == *"INDICE-SINTETICO"* ]]
    ! grep -qE -- '--- [0-9a-f-]+ g5\.md ---' <<<"$ac"
    ! grep -qE -- '--- [0-9a-f-]+ g7\.md ---' <<<"$ac"
    grep -q 'g5.md has an HMAC but failed verification' "$BATS_TEST_TMPDIR/err"
    grep -q 'g7.md has no usable HMAC sidecar' "$BATS_TEST_TMPDIR/err"
    idx="$(grep -n 'index (_global/memory/MEMORY.md)' <<<"$ac" | cut -d: -f1 | head -1)"
    first="$(grep -nE '^--- [0-9a-f-]+ g[0-9]+\.md ---$' <<<"$ac" | cut -d: -f1 | head -1)"
    [ -n "$idx" ]; [ -n "$first" ]; [ "$idx" -lt "$first" ]
}

@test "load-global-memory inyecta un corpus mayor que el limite de un argumento (128 KiB)" {
    local i
    for i in 1 2 3; do
        { printf -- '---\nname: big%s\ndescription: d\ntype: feedback\n---\n\nBIG-%s ' "$i" "$i"; head -c 70000 /dev/zero | tr '\0' x; printf '\n'; } > "$G/big$i.md"
    done
    bash "$S/verify-memory-hmac.sh" "$G" sign >/dev/null
    run bash -c "echo '{}' | bash '$H/load-global-memory.sh'"
    [ "$status" -eq 0 ]
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"BIG-1 "* ]]; [[ "$ac" == *"BIG-3 "* ]]; [[ "$ac" == *"GLOBAL-SINTETICA-12"* ]]
    [ "${#ac}" -gt 200000 ]
}

@test "sin python3 en PATH, la memoria global se verifica con el shim en bash" {
    local BIN="$BATS_TEST_TMPDIR/bin" t src; mkdir -p "$BIN"
    for t in bash jq openssl xxd od awk sed cat tr stat date readlink dirname basename sort head grep; do
        src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$BIN/$t"
    done
    [ -x "$BIN/xxd" ] || skip "sin xxd en este host"
    printf '\nMANIPULADA\n' >> "$G/g5.md"
    run env PATH="$BIN" bash -c "echo '{}' | bash '$H/load-global-memory.sh' 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -eq 0 ]
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"GLOBAL-SINTETICA-4"* ]]; [[ "$ac" == *"INDICE-SINTETICO"* ]]; [[ "$ac" != *"MANIPULADA"* ]]
    grep -q 'g5.md has an HMAC but failed verification' "$BATS_TEST_TMPDIR/err"
}

@test "un nombre de fichero no-UTF-8 no tumba el resto de la memoria global" {
    require_non_utf8_names
    printf 'g\xffbad.md\n' > "$BATS_TEST_TMPDIR/badname"
    local bad; bad="$G/$(cat "$BATS_TEST_TMPDIR/badname")"
    printf -- '---\nname: bad\ndescription: d\ntype: feedback\n---\n\nNUNCA-VISTO\n' > "$bad"
    run env PYTHONIOENCODING=utf-8:strict bash -c "echo '{}' | bash '$H/load-global-memory.sh' 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"GLOBAL-SINTETICA-1"* ]]; [[ "$ac" == *"GLOBAL-SINTETICA-12"* ]]
    [[ "$ac" != *"NUNCA-VISTO"* ]]
    grep -q 'has no usable HMAC sidecar' "$BATS_TEST_TMPDIR/err"
    ! grep -q 'cannot verify' "$BATS_TEST_TMPDIR/err"
}

@test "sin python3 ni xxd no hay con que verificar: no inyecta, avisa, JSON valido y sin falsos 'failed verification'" {
    local BIN="$BATS_TEST_TMPDIR/bin" t src; mkdir -p "$BIN"
    for t in bash jq openssl od awk sed cat tr stat date readlink dirname basename sort head grep; do
        src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$BIN/$t"
    done
    run env PATH="$BIN" bash -c "echo '{}' | bash '$H/load-global-memory.sh' 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.continue == true' >/dev/null
    [[ "$output" != *"GLOBAL-SINTETICA"* ]]
    grep -q 'nothing injected' "$BATS_TEST_TMPDIR/err"
    ! grep -q 'failed verification' "$BATS_TEST_TMPDIR/err"
}
