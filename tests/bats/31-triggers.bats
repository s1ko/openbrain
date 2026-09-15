#!/usr/bin/env bats
load helpers

S="$REPO_ROOT/scripts"; H="$REPO_ROOT/hooks"

setup() {
    setup_fake_home
    export OPENBRAIN_DOCTRINE_DIR="$HOME/.claude/doctrine"; mkdir -p "$OPENBRAIN_DOCTRINE_DIR"
    cp "$REPO_ROOT"/tests/fixtures/doctrine/*.md "$OPENBRAIN_DOCTRINE_DIR/"
    export OPENBRAIN_TRIGGERS_CONF="$XDG_CACHE_HOME/openbrain/triggers.conf"
}

@test "compile genera TSV con todos los kinds y salta manual/comentarios" {
    run bash "$S/openbrain-triggers-compile.sh" --force
    [ "$status" -eq 0 ]
    [ -f "$OPENBRAIN_TRIGGERS_CONF" ]
    grep -qP '^cwd\t\*\*/alpha-zone/\*\*\talpha$' "$OPENBRAIN_TRIGGERS_CONF" || grep -q $'^cwd\t\\*\\*/alpha-zone/\\*\\*\talpha$' "$OPENBRAIN_TRIGGERS_CONF"
    grep -q $'^file\t\\*\\.alp\talpha$'      "$OPENBRAIN_TRIGGERS_CONF"
    grep -q $'^branch\talpha/\\*\talpha$'    "$OPENBRAIN_TRIGGERS_CONF"
    grep -q $'^env\tALPHA_CASE_ROOT\talpha$' "$OPENBRAIN_TRIGGERS_CONF"
    grep -q $'^mcp\tmcp__alpha__\\*\talpha$' "$OPENBRAIN_TRIGGERS_CONF"
    grep -q $'^cwd\t\\*\\*/b-\\*/\\*\\*\tbeta$' "$OPENBRAIN_TRIGGERS_CONF"
    ! grep -q 'manual' "$OPENBRAIN_TRIGGERS_CONF"
    ! grep -q 'comentario' "$OPENBRAIN_TRIGGERS_CONF"
}

@test "compile es idempotente: sin cambios no reescribe" {
    bash "$S/openbrain-triggers-compile.sh" --force
    m1="$(bash -c "source '$S/lib/portable.sh'; p_stat_mtime '$OPENBRAIN_TRIGGERS_CONF'")"
    sleep 1
    bash "$S/openbrain-triggers-compile.sh"
    m2="$(bash -c "source '$S/lib/portable.sh'; p_stat_mtime '$OPENBRAIN_TRIGGERS_CONF'")"
    [ "$m1" = "$m2" ]
    touch "$OPENBRAIN_DOCTRINE_DIR/alpha.md"; sleep 1
    bash "$S/openbrain-triggers-compile.sh"
    m3="$(bash -c "source '$S/lib/portable.sh'; p_stat_mtime '$OPENBRAIN_TRIGGERS_CONF'")"
    [ "$m3" != "$m1" ]
}

tl() { bash -c "${2:-:}; source '$S/lib/common.sh'; source '$S/lib/triggers.sh'; triggers_load; triggers_active $1; printf '%s\n' \"\${TRIG_ACTIVE[@]}\""; }

@test "match cwd: **/X/** casa X y descendientes, ~ se expande, sin duplicar" {
    bash "$S/openbrain-triggers-compile.sh" --force
    run tl "start /a/b/alpha-zone '' ''";             [ "$output" = "alpha" ]
    run tl "start /a/b/alpha-zone/deep/er '' ''";     [ "$output" = "alpha" ]
    run tl "start $HOME/alpha-home/sub '' ''";        [ "$output" = "alpha" ]
    run tl "start /a/b/beta/x '' ''";                 [ "$output" = "beta" ]
    run tl "start /a/b/b-42/x '' ''";                 [ "$output" = "beta" ]
    run tl "start /a/b/gamma '' ''";                  [ -z "$output" ]
    run tl "start $HOME/alpha-home/alpha-zone '' ''"; [ "$output" = "alpha" ]
}

@test "match file / watch / branch / env / mcp" {
    bash "$S/openbrain-triggers-compile.sh" --force
    run tl "watch /n '' '' /x/y/caso.alp";   [ "$output" = "alpha" ]
    run tl "watch /n '' '' /x/alpha.yaml";   [ "$output" = "alpha" ]
    run tl "watch /n '' '' /x/otro.txt";     [ -z "$output" ]
    # patrón con directorio: casa por ruta (absoluta o expandida), no por basename
    run tl "watch /n '' '' /p/.beta-state/now.md";  [ "$output" = "beta" ]
    run tl "watch /n '' '' /p/now.md";              [ -z "$output" ]
    run tl "watch /n '' '' /p/hooks/x.sh";          [ "$output" = "beta" ]
    run tl "watch /n '' '' /p/x.sh";                [ -z "$output" ]
    run tl "watch /n '' '' /p/.beta.json";          [ "$output" = "beta" ]
    run tl "watch /n '' ''";                        [ -z "$output" ]
    # modo start: files por presencia a nivel 1 del cwd; watch nunca por presencia
    mkdir -p "$BATS_TEST_TMPDIR/p1" "$BATS_TEST_TMPDIR/p2/.beta-state"
    : > "$BATS_TEST_TMPDIR/p1/caso.alp"; : > "$BATS_TEST_TMPDIR/p1/.beta.json"; : > "$BATS_TEST_TMPDIR/p2/.beta-state/now.md"
    run tl "start $BATS_TEST_TMPDIR/p1 '' ''";      [ "$output" = "alpha" ]
    run tl "start $BATS_TEST_TMPDIR/p2 '' ''";      [ "$output" = "beta" ]
    run tl "start /n alpha/feature ''";             [ "$output" = "alpha" ]
    run tl "start /n main ''";                      [ -z "$output" ]
    run tl "start /n '' ''" "export ALPHA_CASE_ROOT=/c"; [ "$output" = "alpha" ]
    run tl "start /n '' ''";                        [ -z "$output" ]
    run tl "watch /n '' mcp__alpha__scan";          [ "$output" = "alpha" ]
    run tl "start /n '' mcp__alpha__scan";          [ "$output" = "alpha" ]
}

@test "env con nombre invalido (empieza por digito) no aborta el matching de otros bloques" {
    bash "$S/openbrain-triggers-compile.sh" --force
    run bash -c "export ALPHA_CASE_ROOT=/c; source '$S/lib/common.sh'; source '$S/lib/triggers.sh'; triggers_load; triggers_active start /n '' ''; echo \"rc=\$?\"; printf 'ACTIVE:%s\n' \"\${TRIG_ACTIVE[@]}\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"ACTIVE:alpha"* ]]
    [[ "$output" != *"variable"* ]]
}

@test "watch: un ** intermedio casa tanto a nivel directo como en profundidad" {
    printf -- '---\nname: rustglob\ndescription: d\ntriggers:\n  watch:\n    - "src/**/*.rs"\n---\n# rustglob\n' > "$OPENBRAIN_DOCTRINE_DIR/rustglob.md"
    bash "$S/openbrain-triggers-compile.sh" --force
    run tl "watch /n '' '' /proj/src/x.rs";     [ "$output" = "rustglob" ]
    run tl "watch /n '' '' /proj/src/a/b/x.rs"; [ "$output" = "rustglob" ]
}

@test "watch: ** inicial exige separador y ** intermedio casa cero o mas carpetas" {
    printf -- '---\nname: readme\ndescription: d\ntriggers:\n  watch:\n    - "**/README.md"\n    - "a/**/b"\n---\n# readme\n' > "$OPENBRAIN_DOCTRINE_DIR/readme.md"
    bash "$S/openbrain-triggers-compile.sh" --force
    run tl "watch /n '' '' /proj/README.md";     [ "$output" = "readme" ]
    run tl "watch /n '' '' /proj/x/README.md";   [ "$output" = "readme" ]
    run tl "watch /n '' '' /proj/NOTREADME.md";  [ -z "$output" ]
    run tl "watch /n '' '' /proj/a/b";           [ "$output" = "readme" ]
    run tl "watch /n '' '' /proj/a/x/y/b";       [ "$output" = "readme" ]
    run tl "watch /n '' '' /proj/a/xb";          [ -z "$output" ]
}

@test "un patron files: solo se evalua contra su propio glob, no contra lo hallado por otros bloques" {
    printf -- '---\nname: gamma\ndescription: d\ntriggers:\n  files:\n    - "sub/caso.alp"\n---\n# gamma\n' > "$OPENBRAIN_DOCTRINE_DIR/gamma.md"
    bash "$S/openbrain-triggers-compile.sh" --force
    mkdir -p "$BATS_TEST_TMPDIR/p3/sub"; : > "$BATS_TEST_TMPDIR/p3/sub/caso.alp"
    run tl "start $BATS_TEST_TMPDIR/p3 '' ''";      [ "$output" = "gamma" ]
}

@test "doctrine-watch: un file_path en una tool que no es Read no activa bloques" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s8.state"
    payload="$(jq -cn '{session_id:"s8",tool_name:"Write",tool_input:{file_path:"/z/caso.alp"}}')"
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "doctrine-watch: cambio de branch sin bloques activos deja active en [], no en ['']" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    REPO="$BATS_TEST_TMPDIR/gitrepo"; mkdir -p "$REPO"
    git -C "$REPO" -c init.defaultBranch=main init -q
    printf 'x' > "$REPO/file.txt"
    git -C "$REPO" -c user.email=t@t -c user.name=t add file.txt
    git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init
    git -C "$REPO" checkout -q -b otra
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s9.state"
    payload="$(jq -cn '{session_id:"s9",tool_name:"Bash",tool_input:{command:"ls"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -c .active "$XDG_STATE_HOME/openbrain/doctrine/s9.state")" = "[]" ]
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"DOCTRINA ACTUALIZADA"* ]]
    ! grep -qF '"session_id":"s9"' "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl" 2>/dev/null
}

@test "session-doctrine guarda rama y toplevel del repo en el estado" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    A="$BATS_TEST_TMPDIR/repoA"; mk_checkout_repo "$A"
    run bash -c "cd '$A' && printf '%s' '{\"session_id\":\"s18\"}' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -r .branch "$XDG_STATE_HOME/openbrain/doctrine/s18.state")" = "main" ]
    [ "$(jq -r .repo "$XDG_STATE_HOME/openbrain/doctrine/s18.state")" = "$(cd "$A" && pwd -P)" ]
}

@test "un repo bare no deja rama ni toplevel falsos en el estado" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    BARE="$BATS_TEST_TMPDIR/bare.git"; git init -q --bare "$BARE"
    run bash -c "cd '$BARE' && printf '%s' '{\"session_id\":\"s19\"}' | bash '$H/session-doctrine.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.branch + "|" + .repo' "$XDG_STATE_HOME/openbrain/doctrine/s19.state")" = "|" ]
    A="$BATS_TEST_TMPDIR/repoA"; mk_checkout_repo "$A"
    jq -cn --arg repo "$(cd "$A" && pwd -P)" '{branch:"main",repo:$repo,active:[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s20.state"
    payload="$(jq -cn '{session_id:"s20",tool_name:"Bash",tool_input:{command:"ls"}}')"
    run bash -c "cd '$BARE' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(jq -r '.branch + "|" + .repo' "$XDG_STATE_HOME/openbrain/doctrine/s20.state")" = "main|$(cd "$A" && pwd -P)" ]
}

@test "doctrine-watch: la rama de otro repo (worktree de un subagente) no es cambio de rama" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    A="$BATS_TEST_TMPDIR/repoA"; mk_checkout_repo "$A"
    B="$BATS_TEST_TMPDIR/repoB"; mk_checkout_repo "$B"; git -C "$B" checkout -q other
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"
    jq -cn --arg repo "$(cd "$A" && pwd -P)" '{branch:"main",repo:$repo,active:[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s17.state"
    payload="$(jq -cn '{session_id:"s17",tool_name:"Bash",tool_input:{command:"ls"}}')"
    run bash -c "cd '$B' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(jq -r .branch "$XDG_STATE_HOME/openbrain/doctrine/s17.state")" = "main" ]
    payload="$(jq -cn '{session_id:"s17",tool_name:"Bash",tool_input:{command:"git switch other"}}')"
    run bash -c "cd '$B' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"DOCTRINA ACTUALIZADA"* ]]
    [ "$(jq -r .branch "$XDG_STATE_HOME/openbrain/doctrine/s17.state")" = "other" ]
    [ "$(jq -r .repo "$XDG_STATE_HOME/openbrain/doctrine/s17.state")" = "$(cd "$B" && pwd -P)" ]
}

mk_checkout_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" -c init.defaultBranch=main init -q
    printf 'x' > "$repo/file.txt"
    git -C "$repo" -c user.email=t@t -c user.name=t add file.txt
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m init
    git -C "$repo" branch other
}

@test "doctrine-watch: git checkout de un fichero no es cambio de rama" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    REPO="$BATS_TEST_TMPDIR/repo1"; mk_checkout_repo "$REPO"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s11.state"
    payload="$(jq -cn '{session_id:"s11",tool_name:"Bash",tool_input:{command:"git checkout file.txt"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(jq -r .branch "$XDG_STATE_HOME/openbrain/doctrine/s11.state")" = "main" ]
}

@test "doctrine-watch: git checkout -b crea rama y se detecta el cambio" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    REPO="$BATS_TEST_TMPDIR/repo2"; mk_checkout_repo "$REPO"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s12.state"
    payload="$(jq -cn '{session_id:"s12",tool_name:"Bash",tool_input:{command:"git checkout -b feature/x"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"DOCTRINA ACTUALIZADA"* ]] || { echo "esperaba DOCTRINA ACTUALIZADA, obtuve: $ac" >&2; return 1; }
    [[ "$ac" == *"feature/x"* ]] || { echo "esperaba feature/x, obtuve: $ac" >&2; return 1; }
}

@test "doctrine-watch: -b con start-point y switch --create tambien crean rama" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    REPO="$BATS_TEST_TMPDIR/repo4"; mk_checkout_repo "$REPO"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"
    for cmd in "git checkout -b feature/y origin/feature/y" "git switch --create feature/z" "git switch -c feature/w main"; do
        printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s14.state"
        payload="$(jq -cn --arg c "$cmd" '{session_id:"s14",tool_name:"Bash",tool_input:{command:$c}}')"
        run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
        [ "$status" -eq 0 ]
        ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
        [[ "$ac" == *"DOCTRINA ACTUALIZADA"* ]] || { echo "$cmd: esperaba DOCTRINA ACTUALIZADA, obtuve: $ac" >&2; return 1; }
        [[ "$ac" == *"feature/"* ]] || { echo "$cmd: esperaba feature/, obtuve: $ac" >&2; return 1; }
    done
}

@test "doctrine-watch: git switch a una rama existente se detecta" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
    REPO="$BATS_TEST_TMPDIR/repo3"; mk_checkout_repo "$REPO"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s13.state"
    payload="$(jq -cn '{session_id:"s13",tool_name:"Bash",tool_input:{command:"git switch other"}}')"
    run bash -c "cd '$REPO' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" == *"DOCTRINA ACTUALIZADA"* ]] || { echo "esperaba DOCTRINA ACTUALIZADA, obtuve: $ac" >&2; return 1; }
    [[ "$ac" == *"other"* ]] || { echo "esperaba other, obtuve: $ac" >&2; return 1; }
}

@test "session-doctrine carga alpha en un cwd alpha-zone y nada fuera" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/alpha-zone" "$BATS_TEST_TMPDIR/nada"
    run bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && echo '{\"session_id\":\"s1\"}' | bash '$H/session-doctrine.sh'"
    ac1="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    # [[ ]] suelto a media prueba no aborta bats (a diferencia de `[ ]`, que
    # sí es un comando simple bajo set -e): forzar el fallo explícito con
    # `|| return 1` para que de verdad gatee, no solo la última linea.
    [[ "$ac1" =~ BEGIN\ [A-Za-z0-9-]+\ doctrine/alpha\.md ]] || { echo "esperaba BEGIN <nonce> doctrine/alpha.md en additionalContext, obtuve: $ac1" >&2; return 1; }
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && echo '{\"session_id\":\"s2\"}' | bash '$H/session-doctrine.sh'"
    [ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" = "" ]
}

@test "session-doctrine: un fichero con directorio presente en el cwd activa el bloque" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/proj/.beta-state"
    : > "$BATS_TEST_TMPDIR/proj/.beta-state/now.md"
    run bash -c "cd '$BATS_TEST_TMPDIR/proj' && echo '{\"session_id\":\"s4\"}' | bash '$H/session-doctrine.sh'"
    ac="$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)"
    [[ "$ac" =~ BEGIN\ [A-Za-z0-9-]+\ doctrine/beta\.md ]] || { echo "esperaba beta por .beta-state/now.md, obtuve: $ac" >&2; return 1; }
}

@test "session-doctrine: un patron watch presente en el cwd NO activa el bloque" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/proj2"
    : > "$BATS_TEST_TMPDIR/proj2/.beta.json"
    run bash -c "cd '$BATS_TEST_TMPDIR/proj2' && echo '{\"session_id\":\"s5\"}' | bash '$H/session-doctrine.sh'"
    [ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" = "" ]
}

@test "doctrine-watch amplia al leer un fichero watch" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s6.state"
    payload="$(jq -cn '{session_id:"s6",tool_name:"Read",tool_input:{file_path:"/z/.beta.json"}}')"
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"Nuevos bloques: beta"* ]]
}

@test "doctrine-watch amplia al leer un fichero .alp" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s3.state"
    payload="$(jq -cn '{session_id:"s3",tool_name:"Read",tool_input:{file_path:"/z/caso.alp"}}')"
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"Nuevos bloques: alpha"* ]]
}

@test "doctrine-watch: los bloques son pegajosos entre llamadas Read/Bash/Read" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s10.state"
    read_payload="$(jq -cn '{session_id:"s10",tool_name:"Read",tool_input:{file_path:"/z/caso.alp"}}')"
    bash_payload="$(jq -cn '{session_id:"s10",tool_name:"Bash",tool_input:{command:"ls"}}')"

    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$read_payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    [[ "$(printf '%s' "$output" | jq -r .hookSpecificOutput.additionalContext)" == *"Nuevos bloques: alpha"* ]]

    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$bash_payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(jq -c .active "$XDG_STATE_HOME/openbrain/doctrine/s10.state")" = '["alpha"]' ]

    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$read_payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(grep -cF '"session_id":"s10"' "$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl")" = 1 ]
}

@test "doctrine-watch: con el lock de estado tomado por un pid vivo sale 0 sin tocar nada" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine/s15.state.lock"; echo $$ > "$XDG_STATE_HOME/openbrain/doctrine/s15.state.lock/pid"
    printf '{"branch":"main","active":[]}' > "$XDG_STATE_HOME/openbrain/doctrine/s15.state"
    payload="$(jq -cn '{session_id:"s15",tool_name:"Read",tool_input:{file_path:"/z/caso.alp"}}')"
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ "$(jq -c .active "$XDG_STATE_HOME/openbrain/doctrine/s15.state")" = '[]' ]
    [ -d "$XDG_STATE_HOME/openbrain/doctrine/s15.state.lock" ]
}

@test "doctrine-watch: un estado con nombres vacios no genera bloques fantasma" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    mkdir -p "$XDG_STATE_HOME/openbrain/doctrine"; printf '{"branch":"main","active":["","alpha",""]}' > "$XDG_STATE_HOME/openbrain/doctrine/s16.state"
    payload="$(jq -cn '{session_id:"s16",tool_name:"Read",tool_input:{file_path:"/z/.beta.json"}}')"
    run bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'"
    [ "$status" -eq 0 ]
    [ "$(jq -c .active "$XDG_STATE_HOME/openbrain/doctrine/s16.state")" = '["alpha","beta"]' ]
    [ ! -d "$XDG_STATE_HOME/openbrain/doctrine/s16.state.lock" ]
}

@test "doctrine-watch: un subdirectorio nuevo en doctrine/ recompila una vez, no en cada Bash|Read" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/nada"
    bash "$S/openbrain-triggers-compile.sh" --force
    sleep 1.1; mkdir "$OPENBRAIN_DOCTRINE_DIR/_review"
    [ "$OPENBRAIN_DOCTRINE_DIR" -nt "$OPENBRAIN_TRIGGERS_CONF" ]
    payload="$(jq -cn '{session_id:"s7",tool_name:"Bash",tool_input:{command:"ls"}}')"
    watch() { bash -c "cd '$BATS_TEST_TMPDIR/nada' && printf '%s' '$payload' | bash '$H/doctrine-watch.sh'" >/dev/null; }
    sleep 1.1; watch
    [ "$OPENBRAIN_TRIGGERS_CONF" -nt "$OPENBRAIN_DOCTRINE_DIR" ]
    m1="$(bash -c "source '$S/lib/portable.sh'; p_stat_mtime '$OPENBRAIN_TRIGGERS_CONF'")"
    sleep 1.1; watch
    [ "$(bash -c "source '$S/lib/portable.sh'; p_stat_mtime '$OPENBRAIN_TRIGGERS_CONF'")" = "$m1" ]
}

@test "un subdirectorio nuevo en doctrine/ no es desfase para --check, pero si recompila" {
    bash "$S/openbrain-triggers-compile.sh" --force
    sleep 1.1; mkdir "$OPENBRAIN_DOCTRINE_DIR/_review"
    run bash "$S/openbrain-triggers-compile.sh" --check; [ "$status" -eq 0 ]
    sleep 1.1; bash "$S/openbrain-triggers-compile.sh"
    [ "$OPENBRAIN_TRIGGERS_CONF" -nt "$OPENBRAIN_DOCTRINE_DIR" ]
}

@test "hooks no contienen patrones hardcodeados de rutas" {
    ! grep -nE 'ACMECORP|PROJ-ALPHA|PROJ-BETA|CASEFILES' "$H/session-doctrine.sh" "$H/doctrine-watch.sh"
}

@test "el bloque citado va delimitado por un nonce por sesion, distinto en cada arranque" {
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR" "$BATS_TEST_TMPDIR/alpha-zone"
    get_nonce() {
        bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && echo '{\"session_id\":\"$1\"}' | bash '$H/session-doctrine.sh'" \
          | jq -r .hookSpecificOutput.additionalContext | sed -n 's/^# === DOCTRINA DINÁMICA CARGADA \(.*\) ===$/\1/p'
    }
    n1="$(get_nonce n1)"; n2="$(get_nonce n2)"
    [ -n "$n1" ]; [ "$n1" != "$n2" ]
    ac="$(bash -c "cd '$BATS_TEST_TMPDIR/alpha-zone' && echo '{\"session_id\":\"n3\"}' | bash '$H/session-doctrine.sh'" | jq -r .hookSpecificOutput.additionalContext)"
    n3="$(printf '%s' "$ac" | sed -n 's/^# === DOCTRINA DINÁMICA CARGADA \(.*\) ===$/\1/p')"
    grep -qF -- "--- BEGIN $n3 doctrine/alpha.md ---" <<<"$ac"
    grep -qF -- "--- END $n3 doctrine/alpha.md ---" <<<"$ac"
}

@test "compile acepta cualquier sangria en triggers: y sustituye tabuladores del valor" {
    printf -- '---\nname: cuatro\ndescription: d\ntriggers:\n    cwd:\n        - "**/cuatro/**"\n    files:\n        - "a\tb"\n---\n# cuatro\n' > "$OPENBRAIN_DOCTRINE_DIR/cuatro.md"
    bash "$S/openbrain-triggers-compile.sh" --force
    grep -q $'^cwd\t\\*\\*/cuatro/\\*\\*\tcuatro$' "$OPENBRAIN_TRIGGERS_CONF"
    grep -q $'^file\ta b\tcuatro$' "$OPENBRAIN_TRIGGERS_CONF"
    run tl "start /x/cuatro/y '' ''"; [ "$output" = "cuatro" ]
}

@test "start: un patron files: con ** casa a nivel cero, uno y dos" {
    bash "$S/openbrain-triggers-compile.sh" --force
    for lvl in p0 p1/mid p2/a/b; do
        mkdir -p "$BATS_TEST_TMPDIR/$lvl/hooks"; : > "$BATS_TEST_TMPDIR/$lvl/hooks/z.sh"
    done
    run tl "start $BATS_TEST_TMPDIR/p0 '' ''"; [ "$output" = "beta" ]
    run tl "start $BATS_TEST_TMPDIR/p1 '' ''"; [ "$output" = "beta" ]
    run tl "start $BATS_TEST_TMPDIR/p2 '' ''"; [ "$output" = "beta" ]
    mkdir -p "$BATS_TEST_TMPDIR/p3/hooks"; : > "$BATS_TEST_TMPDIR/p3/hooks/z.txt"
    run tl "start $BATS_TEST_TMPDIR/p3 '' ''"; [ -z "$output" ]
}
