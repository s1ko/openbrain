#!/usr/bin/env bats
load helpers
S="$REPO_ROOT/scripts"

setup() {
    setup_fake_home
    mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/scripts/memory" "$HOME/.local/bin" "$HOME/old-cmd/scripts" "$HOME/old-cmd/hooks"
    sed "s#/HOME#$HOME#g" "$REPO_ROOT/tests/fixtures/settings.sample.json" > "$HOME/.claude/settings.json"
    # legacy: symlinks al repo antiguo + nativos duplicados
    for h in load-global-memory refresh-doctrine verify-memory; do touch "$HOME/old-cmd/hooks/$h.sh"; ln -s "$HOME/old-cmd/hooks/$h.sh" "$HOME/.claude/hooks/$h.sh"; done
    ln -s "$HOME/old-cmd/scripts/lint-memory.sh" "$HOME/.claude/scripts/memory/lint-memory.sh"
    for h in session-doctrine doctrine-watch doctrine-journal; do printf '#!/bin/bash\n' > "$HOME/.claude/hooks/$h.sh"; done
    for s in doctrine-lazy-check doctrine-consolidate; do printf '#!/bin/bash\n' > "$HOME/.claude/scripts/$s.sh"; done
    printf '#!/bin/bash\n' > "$HOME/.claude/hooks/bash-guard.sh"
    ln -s "$HOME/old-cmd/hooks/otro-hook-del-host.sh" "$HOME/.claude/hooks/otro-hook-del-host.sh"   # ajeno: no es legacy
    export PATH="$REPO_ROOT/tests/fixtures/fake-qmd:$PATH"
    SHA0="$(shasum -a 256 "$HOME/.claude/settings.json" 2>/dev/null || sha256sum "$HOME/.claude/settings.json")"
}

@test "--check en host vacio: rc 1, lista lo que falta, no escribe" {
    run bash "$S/openbrain-install.sh" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"FALTA]"*"openbrain.env"* ]]; [[ "$output" == *"FALTA]"*"memory.hmac"* ]]
    [ ! -e "$OPENBRAIN_CONFIG_FILE" ]; [ ! -e "$HOME/.local/bin/openbrain" ]
}

@test "--apply crea env (600), clave (600), symlinks; settings.json intacto" {
    run bash -c "echo n | bash '$S/openbrain-install.sh' --apply"
    [ -f "$OPENBRAIN_CONFIG_FILE" ]; [ "$(bash -c "source '$S/lib/portable.sh'; p_stat_perms '$OPENBRAIN_CONFIG_FILE'")" = 600 ]
    [ -f "$HOME/.config/claude/memory.hmac" ]; [ "$(bash -c "source '$S/lib/portable.sh'; p_stat_perms '$HOME/.config/claude/memory.hmac'")" = 600 ]
    [ "$(readlink "$HOME/.local/bin/openbrain")" = "$REPO_ROOT/bin/openbrain" ]
    [ ! -e "$HOME/.local/bin/refresh-claude-md" ]
    [ "$(shasum -a 256 "$HOME/.claude/settings.json" 2>/dev/null || sha256sum "$HOME/.claude/settings.json")" = "$SHA0" ]
}

@test "imprime diff que quita exactamente los 7 migrados y conserva los 5 del host" {
    run bash "$S/openbrain-install.sh" --check
    for h in session-doctrine load-global-memory refresh-doctrine doctrine-watch verify-memory doctrine-journal doctrine-lazy-check; do grep -qE "^-.*$h\.sh" <<<"$output"; done
    for h in session-start gitleaks-guard bash-guard audit-log session-summary; do ! grep -qE "^-.*$h\.sh" <<<"$output"; done
    [[ "$output" == *"jq "* ]]
    [[ "$output" == *"no lo aplico"* ]]
    # Un evento que se queda sin hooks se va entero: nada de "SessionStart": [].
    ! grep -qE '^\+.*: \[\]' <<<"$output"
}

@test "el filtro de settings.json no deja eventos vacios" {
    printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$HOME"'/.claude/hooks/load-global-memory.sh"}]}],"PostToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"'"$HOME"'/.claude/hooks/verify-memory.sh"}]}]}}' > "$HOME/.claude/settings.json"
    run bash "$S/openbrain-install.sh" --check
    [[ "$output" != *'"SessionStart": []'* ]]; [[ "$output" != *'"PostToolUse": []'* ]]
    # Y el resultado que propone es JSON valido con .hooks ya vacio.
    grep -qE '^\+ *"hooks": \{\}' <<<"$output"
}

@test "detecta legacy y --remove-legacy los retira solo con confirmacion" {
    run bash "$S/openbrain-install.sh" --check
    [[ "$output" == *"symlink legacy"*"load-global-memory.sh"* ]]; [[ "$output" == *"duplicado nativo"*"session-doctrine.sh"* ]]
    run bash -c "echo n | bash '$S/openbrain-install.sh' --remove-legacy"; [ -L "$HOME/.claude/hooks/load-global-memory.sh" ]
    run bash -c "echo y | bash '$S/openbrain-install.sh' --remove-legacy"
    [ ! -e "$HOME/.claude/hooks/load-global-memory.sh" ]; [ ! -e "$HOME/.claude/scripts/memory/lint-memory.sh" ]
    [ ! -e "$HOME/.claude/hooks/session-doctrine.sh" ]; [ -n "$(ls -d "$HOME"/.claude/hooks/_retired_*/session-doctrine.sh)" ]
    [ -f "$HOME/.claude/hooks/bash-guard.sh" ]   # control del host: intacto
    [ -L "$HOME/.claude/hooks/otro-hook-del-host.sh" ]   # symlink ajeno al plugin: intacto
    [[ "$output" != *"otro-hook-del-host"* ]]
}

@test "planificador: sin OPENBRAIN_BACKUP_GPG no instala; con el pide confirmacion" {
    run bash -c "echo y | bash '$S/openbrain-install.sh' --apply"; [[ "$output" == *"backup desactivado"* ]]
    # Se edita la línea existente (el ejemplo ya trae OPENBRAIN_BACKUP_GPG= vacío y
    # el loader respeta la primera aparición), no se añade al final.
    sed 's/^OPENBRAIN_BACKUP_GPG=.*/OPENBRAIN_BACKUP_GPG=0123456789ABCDEF0123456789ABCDEF01234567/' "$OPENBRAIN_CONFIG_FILE" > "$OPENBRAIN_CONFIG_FILE.tmp" && mv "$OPENBRAIN_CONFIG_FILE.tmp" "$OPENBRAIN_CONFIG_FILE"
    run bash -c "echo n | bash '$S/openbrain-install.sh' --apply"; [[ "$output" == *"planificador"*"omitido"* ]]
}

@test "todo informe lleva el aviso de privacidad de la captura" {
    run bash "$S/openbrain-install.sh" --check; [[ "$output" == *"Privacidad"*"prompts"* ]]
}

@test "planificador con OPENBRAIN_BACKUP_AGE: backend age, pide confirmacion, n = omitido" {
    run bash -c "echo n | bash '$S/openbrain-install.sh' --apply"; [[ "$output" == *"backup desactivado"* ]]
    sed 's/^OPENBRAIN_BACKUP_AGE=.*/OPENBRAIN_BACKUP_AGE=age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq/' "$OPENBRAIN_CONFIG_FILE" > "$OPENBRAIN_CONFIG_FILE.tmp" && mv "$OPENBRAIN_CONFIG_FILE.tmp" "$OPENBRAIN_CONFIG_FILE"
    run bash -c "echo n | bash '$S/openbrain-install.sh' --apply"
    [[ "$output" != *"backup desactivado"* ]]
    [[ "$output" == *"backend age"* ]]; [[ "$output" == *"planificador"*"omitido"* ]]
    [ ! -e "$HOME/Library/LaunchAgents/com.openbrain.memory-backup.plist" ]; [ ! -e "$HOME/.config/systemd/user/openbrain-memory-backup.timer" ]
}

@test "planificador --apply renderiza el unit systemd con OPENBRAIN_BACKUP_DIR y OPENBRAIN_CONFIG_FILE personalizados, sin placeholders" {
    [ "$(uname -s)" = Linux ] || skip "rama systemd: solo Linux"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/systemctl"; chmod +x "$BIN/systemctl"
    custom_cfg="$HOME/.config/claude/custom-openbrain.env"
    custom_dir="$HOME/custom-backups/memory"
    run env PATH="$BIN:$PATH" OPENBRAIN_CONFIG_FILE="$custom_cfg" OPENBRAIN_BACKUP_DIR="$custom_dir" \
        OPENBRAIN_BACKUP_GPG=0123456789ABCDEF0123456789ABCDEF01234567 \
        bash -c "echo y | bash '$S/openbrain-install.sh' --apply"
    [[ "$output" == *"[OK]    systemd: openbrain-memory-backup.timer"* ]]
    unit="$HOME/.config/systemd/user/openbrain-memory-backup.service"
    [ -f "$unit" ]
    grep -qF "ConditionPathExists=$custom_cfg" "$unit"
    grep -qF "ReadWritePaths=$custom_dir" "$unit"
    ! grep -q '__' "$unit"
    [ "$(bash -c "source '$S/lib/portable.sh'; p_stat_perms '$unit'")" = 644 ]
}

@test "planificador --apply renderiza el plist launchd con OPENBRAIN_BACKUP_DIR y OPENBRAIN_CONFIG_FILE personalizados, sin placeholders" {
    [ "$(uname -s)" = Darwin ] || skip "rama launchd: solo macOS"
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/launchctl"; chmod +x "$BIN/launchctl"
    custom_cfg="$HOME/.config/claude/custom-openbrain.env"
    custom_dir="$HOME/custom-backups/memory"
    run env PATH="$BIN:$PATH" OPENBRAIN_CONFIG_FILE="$custom_cfg" OPENBRAIN_BACKUP_DIR="$custom_dir" \
        OPENBRAIN_BACKUP_GPG=0123456789ABCDEF0123456789ABCDEF01234567 \
        bash -c "echo y | bash '$S/openbrain-install.sh' --apply"
    plist="$HOME/Library/LaunchAgents/com.openbrain.memory-backup.plist"
    [[ "$output" == *"[OK]    launchd: $plist"* ]]
    [ -f "$plist" ]
    grep -qF "$custom_dir/launchd.out.log" "$plist"
    grep -qF "$custom_dir/launchd.err.log" "$plist"
    grep -qF "$HOME/.local/bin/openbrain memory backup --yes" "$plist"
    ! grep -q '__' "$plist"
    [ "$(bash -c "source '$S/lib/portable.sh'; p_stat_perms '$custom_dir'")" = 700 ]
}

@test "planificador --apply rechaza OPENBRAIN_BACKUP_DIR con '#': falta y no renderiza nada" {
    BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/systemctl"; chmod +x "$BIN/systemctl"
    run env PATH="$BIN:$PATH" OPENBRAIN_BACKUP_DIR="$HOME/ev#il" \
        OPENBRAIN_BACKUP_GPG=0123456789ABCDEF0123456789ABCDEF01234567 \
        bash -c "echo y | bash '$S/openbrain-install.sh' --apply"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FALTA]"*"contiene '#'"* ]]
    [ ! -e "$HOME/.config/systemd/user/openbrain-memory-backup.service" ]
}

@test "el symlink refresh-claude-md de versiones anteriores es legacy: se lista y --remove-legacy lo borra" {
    ln -s "$HOME/old-cmd/tools/refresh_claude_md.py" "$HOME/.local/bin/refresh-claude-md"
    run bash "$S/openbrain-install.sh" --check
    [[ "$output" == *"symlink legacy: $HOME/.local/bin/refresh-claude-md"* ]]
    run bash -c "echo y | bash '$S/openbrain-install.sh' --remove-legacy"
    [ ! -e "$HOME/.local/bin/refresh-claude-md" ]; [ ! -L "$HOME/.local/bin/refresh-claude-md" ]
}

@test "python3 sin tomllib (<3.11): FALTA python3 >= 3.11" {
    STUB="$BATS_TEST_TMPDIR/py-bin"; mkdir -p "$STUB"
    cat > "$STUB/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in *tomllib*) exit 1 ;; esac
exec "$(command -v python3)" "\$@"
EOF
    chmod +x "$STUB/python3"
    PATH="$STUB:$PATH" run bash "$S/openbrain-install.sh" --check
    [[ "$output" == *"FALTA]"*"python3 >= 3.11"* ]]
    run bash "$S/openbrain-install.sh" --check
    [[ "$output" != *"python3 >= 3.11"* ]]
}
