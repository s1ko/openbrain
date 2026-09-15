#!/usr/bin/env bats
load helpers

setup() {
    setup_fake_home
    P="$REPO_ROOT/scripts/lib/portable.sh"
    F="$BATS_TEST_TMPDIR/f.txt"; printf 'hola\n' > "$F"; chmod 640 "$F"
}

# Ejecuta $1 (código bash) con portable.sh cargado y la rama forzada en $2 (gnu|bsd|"")
run_p() { local force="$1"; shift; run bash -c "OPENBRAIN_PORTABLE_FORCE='$force' source '$P'; $*"; }

# La rama BSD solo es ejecutable donde existen binarios BSD (/usr/bin/stat -f).
# En GNU stat "-f" es un flag valido (modo filesystem), asi que "no falla" no
# prueba que sea BSD: se exige ademas Darwin.
bsd_available() { [ "$(uname -s)" = Darwin ] && /usr/bin/stat -f %m / >/dev/null 2>&1; }

@test "p_os devuelve darwin o linux" {
    run_p "" 'p_os'
    [[ "$output" == darwin || "$output" == linux ]]
}

@test "p_os detecta windows via uname MINGW/MSYS/CYGWIN" {
    STUB="$BATS_TEST_TMPDIR/stub-uname"; mkdir -p "$STUB"
    for k in MINGW64_NT-10.0-19045 MSYS_NT-10.0-19045 CYGWIN_NT-10.0; do
        printf '#!/usr/bin/env bash\necho "%s"\n' "$k" > "$STUB/uname"
        chmod +x "$STUB/uname"
        PATH="$STUB:$PATH" run_p "" 'p_os'
        [ "$output" = "windows" ]
    done
}

@test "p_stat_perms: 640 en ambas ramas" {
    run_p gnu "p_stat_perms '$F'"; [ "$output" = "640" ]
    bsd_available || skip "sin binarios BSD en este host"
    run_p bsd "p_stat_perms '$F'"; [ "$output" = "640" ]
}

@test "p_stat_mtime y p_stat_size coinciden entre ramas" {
    run_p gnu "p_stat_mtime '$F'; p_stat_size '$F'"; gnu_out="$output"
    [[ "$gnu_out" =~ ^[0-9]+$'\n'5$ ]]
    bsd_available || skip
    run_p bsd "p_stat_mtime '$F'; p_stat_size '$F'"; [ "$output" = "$gnu_out" ]
}

@test "p_date_iso formatea UTC ISO-8601 a partir de epoch" {
    run_p gnu 'p_date_iso 0';   [ "$output" = "1970-01-01T00:00:00Z" ]
    run_p gnu 'p_date_ymd 86400'; [ "$output" = "1970-01-02" ]
    bsd_available || skip
    run_p bsd 'p_date_iso 0';   [ "$output" = "1970-01-01T00:00:00Z" ]
}

@test "p_date_to_epoch: fecha valida ida y vuelta; invalida devuelve vacio" {
    run_p gnu 'p_epoch_to_ymd "$(p_date_to_epoch 2026-02-28)"'; [ "$output" = "2026-02-28" ]
    run_p gnu 'p_date_to_epoch 2026-02-30'; [ -z "$output" ]
    bsd_available || skip
    run_p bsd 'p_date_to_epoch 2026-02-30'; [ -z "$output" ]   # BSD date -j desborda: debe rechazarse
}

@test "p_epoch_ago 1 h es ~3600 s menos que ahora" {
    run_p gnu 'now=$(date +%s); ago=$(p_epoch_ago 1 h); echo $((now-ago))'
    [ "$output" -ge 3599 ] && [ "$output" -le 3601 ]
}

@test "p_replace_keep_mode sustituye por el temporal y conserva el modo" {
    run_p gnu "t=\$(mktemp '$F.XXXXXX'); printf 'adios\n' > \"\$t\"; p_replace_keep_mode '$F' \"\$t\"; cat '$F'; p_stat_perms '$F'"
    [ "${lines[0]}" = "adios" ]
    [ "${lines[1]}" = "640" ]
}

@test "p_base64_oneline no emite saltos de linea" {
    run_p gnu 'head -c 100 /dev/zero | p_base64_oneline | wc -l | tr -d " "'
    [ "$output" = "0" ]
}

@test "p_abspath resuelve symlinks" {
    ln -s "$F" "$BATS_TEST_TMPDIR/link"
    run_p gnu "p_abspath '$BATS_TEST_TMPDIR/link'"
    [ "$output" = "$(cd "$(dirname "$F")" && pwd -P)/f.txt" ]
}

@test "p_secure_rm elimina el fichero" {
    run_p gnu "p_secure_rm '$F'; [ ! -e '$F' ] && echo gone"
    [ "$output" = "gone" ]
}

@test "common.sh no define alias legacy: solo la API p_*" {
    run bash -c "source '$REPO_ROOT/scripts/lib/common.sh'; for f in stat_size stat_mtime stat_perms date_to_epoch epoch_to_date abspath sed_inplace; do type -t \"\$f\" >/dev/null 2>&1 && echo \"legacy: \$f\"; done; p_stat_perms '$F'"
    [ "$output" = "640" ]
}
