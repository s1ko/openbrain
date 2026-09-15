#!/usr/bin/env bats
load helpers

setup() { setup_fake_home; }

@test "config: sin openbrain.env, defaults razonables" {
    run bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && brain_config_dump"
    [ "$status" -eq 0 ]
    grep -q "^OPENBRAIN_COLLECTION=openbrain$" <<<"$output"
    grep -q "^OPENBRAIN_MEMORY_ROOT=$HOME/.claude/projects$" <<<"$output"
    grep -q "^OPENBRAIN_HMAC_KEY=$HOME/.config/claude/memory.hmac$" <<<"$output"
    grep -q "^OPENBRAIN_STALE_DAYS=60$" <<<"$output"
    grep -q "^OPENBRAIN_CAPTURE_ENABLED=1$" <<<"$output"
    grep -q "^OPENBRAIN_CAPTURE_DIR=$XDG_STATE_HOME/openbrain/candidates$" <<<"$output"
}

@test "config: el fichero sobreescribe defaults y expande ~ y \$HOME" {
    cat > "$OPENBRAIN_CONFIG_FILE" <<'EOF'
# comentario
OPENBRAIN_COLLECTION="mi-wiki"
OPENBRAIN_WIKI_ROOT=~/kb/wiki
OPENBRAIN_REPO_ROOT="$HOME/kb"
OPENBRAIN_STALE_DAYS=90
EOF
    run bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && brain_config_dump"
    [ "$status" -eq 0 ]
    grep -q "^OPENBRAIN_COLLECTION=mi-wiki$" <<<"$output"
    grep -q "^OPENBRAIN_WIKI_ROOT=$HOME/kb/wiki$" <<<"$output"
    grep -q "^OPENBRAIN_REPO_ROOT=$HOME/kb$" <<<"$output"
    grep -q "^OPENBRAIN_STALE_DAYS=90$" <<<"$output"
}

@test "config: la variable de entorno gana al fichero" {
    printf 'OPENBRAIN_STALE_DAYS=90\n' > "$OPENBRAIN_CONFIG_FILE"
    # env OPENBRAIN_STALE_DAYS=7 (no como prefijo de `source` dentro del propio
    # bash -c): en bash 3.2 no-POSIX, un prefijo de asignación delante de un
    # builtin especial como `source`/`.` se revierte en cuanto ese comando
    # termina y no sobrevive al `&&` siguiente (verificado empíricamente en
    # este host). `env VAR=val bash -c '...'` sí deja VAR como variable de
    # entorno real durante toda la vida del proceso bash, que es el caso que
    # este test quiere ejercitar.
    run env OPENBRAIN_STALE_DAYS=7 bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && brain_config_dump"
    grep -q "^OPENBRAIN_STALE_DAYS=7$" <<<"$output"
}

@test "config: ignora claves que no empiezan por OPENBRAIN_ y no ejecuta nada" {
    cat > "$OPENBRAIN_CONFIG_FILE" <<'EOF'
PATH=/tmp/evil
OPENBRAIN_COLLECTION=$(touch /tmp/pwned)
EOF
    run bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && echo \"PATH=\$PATH\" && brain_config_dump"
    [ "$status" -eq 0 ]
    ! grep -q '^PATH=/tmp/evil$' <<<"$output"
    grep -q '^OPENBRAIN_COLLECTION=\$(touch /tmp/pwned)$' <<<"$output"
    [ ! -e /tmp/pwned ]
}

@test "config: no exporta nombres legacy; los knobs de backup tienen default" {
    run bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && env | grep -E '^(MEMORY_|STALE_DAYS=|REFRESH_DOCTRINE_)'"
    [ -z "$output" ]
    run bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && echo \"\$OPENBRAIN_BACKUP_KEEP|\$OPENBRAIN_BACKUP_SIGN_KEY|\$OPENBRAIN_BACKUP_AGE_IDENTITY\""
    [ "$output" = "30||$HOME/.config/claude/memory-backup-key.txt" ]
}

@test "config: clave malformada con separador de comando se ignora sin ensuciar stderr" {
    printf 'OPENBRAIN_FOO;touch %s/pwned=1\n' "$BATS_TEST_TMPDIR" > "$OPENBRAIN_CONFIG_FILE"
    run bash -c "source '$REPO_ROOT/scripts/lib/config.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "config: OPENBRAIN_BACKUP_AGE del fichero llega exportada y el env explicito gana" {
    printf 'OPENBRAIN_BACKUP_AGE=age1testrecipient\n' > "$OPENBRAIN_CONFIG_FILE"
    run bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && env | grep '^OPENBRAIN_BACKUP_AGE='"
    [ "$output" = "OPENBRAIN_BACKUP_AGE=age1testrecipient" ]
    run env OPENBRAIN_BACKUP_AGE=age1env bash -c "source '$REPO_ROOT/scripts/lib/config.sh' && echo \"\$OPENBRAIN_BACKUP_AGE\""
    [ "$output" = "age1env" ]
}

