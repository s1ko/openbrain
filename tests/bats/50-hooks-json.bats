#!/usr/bin/env bats
load helpers

J="$REPO_ROOT/hooks/hooks.json"

@test "hooks.json es JSON valido con los 5 eventos" {
    run jq -r '.hooks | keys[]' "$J"
    [ "$status" -eq 0 ]
    for ev in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do grep -qx "$ev" <<<"$output"; done
}

@test "cada comando referencia un fichero existente y ejecutable bajo el repo" {
    while IFS= read -r cmd; do
        # El comando puede llevar un argumento (openbrain-hook.sh SessionStart): el
        # fichero es el primer token, tras sustituir la variable y quitar comillas.
        path="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$REPO_ROOT}"; path="${path//\"/}"; path="${path%% *}"
        [ -x "$path" ] || { echo "no ejecutable: $path"; false; }
    done < <(jq -r '.hooks[][].hooks[].command' "$J")
}

@test "SessionStart y Stop pasan por el dispatcher; cada uno un solo comando" {
    run jq -r '.hooks.SessionStart[0].hooks[].command' "$J"
    [ "${#lines[@]}" -eq 1 ]; [[ "${lines[0]}" == *"openbrain-hook.sh\" SessionStart" ]]
    run jq -r '.hooks.Stop[0].hooks[].command' "$J"
    [ "${#lines[@]}" -eq 1 ]; [[ "${lines[0]}" == *"openbrain-hook.sh\" Stop" ]]
}

@test "declara exactamente 5 comandos y ninguno es un control del host" {
    [ "$(jq '[.hooks[][].hooks[]] | length' "$J")" = "5" ]
    ! jq -r '.hooks[][].hooks[].command' "$J" | grep -E 'bash-guard|gitleaks-guard|audit-log|session-start\.sh|session-summary'
}

@test "guarda R4: un hook movido fuera del repo avisa y sale 0" {
    cp "$REPO_ROOT/hooks/capture-flush.sh" "$BATS_TEST_TMPDIR/solo.sh"
    run bash "$BATS_TEST_TMPDIR/solo.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook inactivo"* ]]
}

@test "guarda R4: el dispatcher movido fuera del repo avisa y sale 0" {
    cp "$REPO_ROOT/hooks/openbrain-hook.sh" "$BATS_TEST_TMPDIR/solo-disp.sh"
    run bash "$BATS_TEST_TMPDIR/solo-disp.sh" SessionStart
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook inactivo"* ]]
}

@test "todo hook cierra en exit 0; verify-memory conserva su exit 2 de integridad" {
    for f in "$REPO_ROOT"/hooks/*.sh; do
        tail -5 "$f" | grep -qE '^ *exit 0$' || { echo "sin exit 0 final: $f"; false; }
    done
    grep -qE '^ *exit 2$' "$REPO_ROOT/hooks/verify-memory.sh"
}
