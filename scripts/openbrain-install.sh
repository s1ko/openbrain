#!/usr/bin/env bash
set -uo pipefail
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"; ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODE=check; REMOVE=0
for a in "$@"; do case "$a" in --check) MODE=check ;; --apply) MODE=apply ;; --remove-legacy) REMOVE=1 ;; *) echo "uso: openbrain install [--check|--apply] [--remove-legacy]" >&2; exit 2 ;; esac; done
RC=0
ok()   { printf '  [OK]    %s\n' "$*"; }
falta(){ printf '  [FALTA] %s\n' "$*"; RC=1; }
info() { printf '  [..]    %s\n' "$*"; }
confirm() { printf '%s — ¿continuar? [y/N] ' "$1"; read -r a || a=n; case "$a" in y|Y) return 0 ;; *) return 1 ;; esac; }
CFG_DIR="$(dirname "$OPENBRAIN_CONFIG_FILE")"; BIN_DIR="$HOME/.local/bin"
MIGRATED=(session-doctrine.sh load-global-memory.sh refresh-doctrine.sh doctrine-watch.sh verify-memory.sh doctrine-journal.sh doctrine-lazy-check.sh)

echo "== openbrain install ($MODE) — $(p_os) =="
echo "-- dependencias"
for t in bash jq openssl gitleaks python3 node qmd; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"
    elif [ "$t" = qmd ]; then falta "$t  (npm i -g @tobilu/qmd)"
    elif [ "$t" = node ]; then falta "$t  (>=22, requerido por qmd)"
    else falta "$t"; fi
done
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    falta "python3 >= 3.11 (tomllib; refresh-doctrine no corre con $(python3 -V 2>&1))"
fi
for t in bats shellcheck; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t (dev)"; else info "$t (dev) ausente — solo para make test"; fi
done
BACKUP_BACKEND=""; [ -n "$OPENBRAIN_BACKUP_GPG" ] && BACKUP_BACKEND=gpg; [ -n "$OPENBRAIN_BACKUP_AGE" ] && BACKUP_BACKEND=age
for t in age gpg; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t (backup)"
    elif [ "$t" = "$BACKUP_BACKEND" ]; then falta "$t (backend de backup configurado en openbrain.env)"
    else info "$t ausente — solo para backup cifrado con ese backend"; fi
done

echo "-- configuración"
if [ -f "$OPENBRAIN_CONFIG_FILE" ]; then ok "openbrain.env: $OPENBRAIN_CONFIG_FILE"
elif [ "$MODE" = apply ]; then install -d -m 700 "$CFG_DIR"; install -m 600 "$ROOT/install/env/openbrain.env.example" "$OPENBRAIN_CONFIG_FILE"; ok "openbrain.env creado desde el ejemplo — EDÍTALO: $OPENBRAIN_CONFIG_FILE"
else falta "openbrain.env: $OPENBRAIN_CONFIG_FILE (--apply lo crea desde install/env/openbrain.env.example)"; fi
if hmac_key_ok "$OPENBRAIN_HMAC_KEY"; then ok "clave HMAC: $OPENBRAIN_HMAC_KEY"
elif [ -e "$OPENBRAIN_HMAC_KEY" ]; then falta "clave HMAC con permisos laxos: chmod 600 '$OPENBRAIN_HMAC_KEY'"
elif [ "$MODE" = apply ]; then install -d -m 700 "$(dirname "$OPENBRAIN_HMAC_KEY")"; ( umask 077; head -c 32 /dev/urandom | p_base64_oneline > "$OPENBRAIN_HMAC_KEY" ); chmod 600 "$OPENBRAIN_HMAC_KEY"; ok "clave HMAC creada (600). Firma inicial: openbrain memory sign"
else falta "memory.hmac: $OPENBRAIN_HMAC_KEY (--apply la genera)"; fi
if [ -d "$OPENBRAIN_DOCTRINE_DIR" ]; then
    if [ "$MODE" = apply ]; then
        if bash "$SCRIPT_DIR/openbrain-triggers-compile.sh" --force; then ok "triggers.conf compilado"; else falta "triggers.conf no compiló"; fi
    elif bash "$SCRIPT_DIR/openbrain-triggers-compile.sh" --check; then ok "triggers.conf al día"; else falta "triggers.conf desfasado (--apply o openbrain triggers --force)"; fi
else info "sin directorio de doctrina ($OPENBRAIN_DOCTRINE_DIR): pilar doctrina inactivo"; fi

echo "-- enlaces"
link() {
    if [ "$(readlink "$2" 2>/dev/null)" = "$1" ]; then ok "$2 → $1"
    elif [ "$MODE" = apply ]; then mkdir -p "$(dirname "$2")"; ln -sfn "$1" "$2"; ok "$2 → $1 (creado)"
    else falta "$2 → $1"; fi
}
link "$ROOT/bin/openbrain" "$BIN_DIR/openbrain"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) info "$BIN_DIR no está en PATH: añádelo o usa \${CLAUDE_PLUGIN_ROOT}/bin/openbrain" ;; esac

echo "-- planificador de backup"
if [ -z "$BACKUP_BACKEND" ]; then info "backup desactivado (OPENBRAIN_BACKUP_AGE y OPENBRAIN_BACKUP_GPG vacíos en openbrain.env)"
elif [ "$MODE" = apply ]; then
    case "$OPENBRAIN_BACKUP_DIR$OPENBRAIN_CONFIG_FILE" in *'#'*) TPL_OK=0 ;; *) TPL_OK=1 ;; esac
    if [ "$TPL_OK" = 0 ]; then falta "OPENBRAIN_BACKUP_DIR o OPENBRAIN_CONFIG_FILE contiene '#': no se puede plantillar el planificador"
    elif confirm "Instalar el planificador diario de backup ($(p_os), backend $BACKUP_BACKEND)"; then
        if [ "$(p_os)" = darwin ] && command -v launchctl >/dev/null 2>&1; then
            dst="$HOME/Library/LaunchAgents/com.openbrain.memory-backup.plist"; mkdir -p "$(dirname "$dst")"
            sed -e "s#__BACKUP_DIR__#$OPENBRAIN_BACKUP_DIR#g" -e "s#__CONFIG_FILE__#$OPENBRAIN_CONFIG_FILE#g" -e "s#__OPENBRAIN_BIN__#$BIN_DIR/openbrain#g" \
                "$ROOT/install/launchd/com.openbrain.memory-backup.plist" > "$dst"
            install -d -m 700 "$OPENBRAIN_BACKUP_DIR"
            launchctl bootout "gui/$(id -u)" "$dst" 2>/dev/null
            if launchctl bootstrap "gui/$(id -u)" "$dst"; then ok "launchd: $dst"; else falta "launchctl bootstrap falló"; fi
        elif [ "$(p_os)" = linux ] && command -v systemctl >/dev/null 2>&1; then
            d="$HOME/.config/systemd/user"; mkdir -p "$d"
            svc_tmp="$(mktemp)"
            sed -e "s#__BACKUP_DIR__#$OPENBRAIN_BACKUP_DIR#g" -e "s#__CONFIG_FILE__#$OPENBRAIN_CONFIG_FILE#g" -e "s#__OPENBRAIN_BIN__#$BIN_DIR/openbrain#g" \
                "$ROOT/install/systemd/openbrain-memory-backup.service" > "$svc_tmp"
            install -m 644 "$svc_tmp" "$d/openbrain-memory-backup.service"; rm -f "$svc_tmp"
            install -m 644 "$ROOT/install/systemd/openbrain-memory-backup.timer" "$d/"
            if systemctl --user daemon-reload && systemctl --user enable --now openbrain-memory-backup.timer; then ok "systemd: openbrain-memory-backup.timer"; else falta "systemctl --user falló"; fi
        elif [ "$(p_os)" = windows ] && command -v schtasks >/dev/null 2>&1; then
            if ! command -v cygpath >/dev/null 2>&1; then falta "cygpath no encontrado: instala Git for Windows para el planificador"
            else
                install -d -m 700 "$OPENBRAIN_BACKUP_DIR"
                xml="$OPENBRAIN_BACKUP_DIR/openbrain-memory-backup.xml"
                sed -e "s#__BACKUP_DIR__#$OPENBRAIN_BACKUP_DIR#g" -e "s#__OPENBRAIN_BIN__#$BIN_DIR/openbrain#g" \
                    -e "s#__BASH_EXE__#$(cygpath -w "$(command -v bash)")#g" \
                    "$ROOT/install/wintask/openbrain-memory-backup.xml" > "$xml"
                if schtasks /create /tn openbrain-memory-backup /xml "$(cygpath -w "$xml")" /f >/dev/null; then
                    ok "Task Scheduler: openbrain-memory-backup"
                else falta "schtasks /create falló"; fi
            fi
        else falta "sin planificador soportado ($(p_os): ni launchctl, ni systemctl --user, ni schtasks)"; fi
    else info "planificador omitido"; fi
else
    if [ "$(p_os)" = darwin ] && command -v launchctl >/dev/null 2>&1; then
        if launchctl print "gui/$(id -u)/com.openbrain.memory-backup" >/dev/null 2>&1; then ok "launchd: com.openbrain.memory-backup (cargado)"
        else falta "planificador no instalado (--apply lo instala tras confirmar)"; fi
    elif [ "$(p_os)" = linux ] && command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-enabled openbrain-memory-backup.timer >/dev/null 2>&1; then ok "systemd: openbrain-memory-backup.timer (enabled)"
        else falta "planificador no instalado (--apply lo instala tras confirmar)"; fi
    elif [ "$(p_os)" = windows ] && command -v schtasks >/dev/null 2>&1; then
        if schtasks /query /tn openbrain-memory-backup >/dev/null 2>&1; then ok "Task Scheduler: openbrain-memory-backup (creada)"
        else falta "planificador no instalado (--apply lo instala tras confirmar)"; fi
    else info "sin planificador soportado ($(p_os)): backup solo manual"; fi
fi

echo "-- legacy (symlinks al repo antiguo y duplicados nativos)"
LEGACY_LINKS=(); LEGACY_NATIVE=()
provided_by_plugin() { [ -e "$ROOT/hooks/$1" ] || [ -e "$ROOT/scripts/$1" ]; }
f="$BIN_DIR/refresh-claude-md"; [ -L "$f" ] && { LEGACY_LINKS+=("$f"); info "symlink legacy: $f → $(readlink "$f")"; }
for f in "$HOME"/.claude/hooks/* "$HOME"/.claude/scripts/memory/*; do
    [ -L "$f" ] && provided_by_plugin "$(basename "$f")" && { LEGACY_LINKS+=("$f"); info "symlink legacy: $f → $(readlink "$f")"; }
done
for n in session-doctrine.sh doctrine-watch.sh doctrine-journal.sh; do f="$HOME/.claude/hooks/$n"; [ -f "$f" ] && [ ! -L "$f" ] && { LEGACY_NATIVE+=("$f"); info "duplicado nativo: $f"; }; done
for n in doctrine-lazy-check.sh doctrine-consolidate.sh; do f="$HOME/.claude/scripts/$n"; [ -f "$f" ] && [ ! -L "$f" ] && { LEGACY_NATIVE+=("$f"); info "duplicado nativo: $f"; }; done
if [ "$REMOVE" = 1 ] && [ $(( ${#LEGACY_LINKS[@]} + ${#LEGACY_NATIVE[@]} )) -gt 0 ]; then
    if confirm "Retirar ${#LEGACY_LINKS[@]} symlink(s) y mover ${#LEGACY_NATIVE[@]} nativo(s) a _retired_"; then
        for f in "${LEGACY_LINKS[@]+"${LEGACY_LINKS[@]}"}"; do
            if [ -L "$f" ] && rm -f "$f"; then ok "borrado symlink $f"; else falta "no se borró $f (ya no es symlink o rm falló)"; fi
        done
        if [ "${#LEGACY_NATIVE[@]}" -gt 0 ]; then
            rd="$HOME/.claude/hooks/_retired_$(p_date_ymd)"; mkdir -p "$rd"
            for f in "${LEGACY_NATIVE[@]}"; do
                if [ -f "$f" ] && [ ! -L "$f" ] && mv "$f" "$rd/"; then ok "movido $f → $rd/"; else falta "no se movió $f (ya no es fichero regular o mv falló)"; fi
            done
        fi
    else info "retirada cancelada"; fi
elif [ $(( ${#LEGACY_LINKS[@]} + ${#LEGACY_NATIVE[@]} )) -gt 0 ]; then info "retirar con: openbrain install --remove-legacy (tras verificar que el plugin carga)"; fi

echo "-- ~/.claude/settings.json (no lo aplico: es tu fichero de controles)"
SJ="$HOME/.claude/settings.json"
if [ -f "$SJ" ] && command -v jq >/dev/null 2>&1; then
    names_json="$(printf '%s\n' "${MIGRATED[@]}" | jq -R . | jq -sc .)"
    # shellcheck disable=SC2016
    FILTER='def base: split("/") | last; .hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command|base) as $b | ($names|index($b))|not))) | map(select(.hooks|length>0)))) | with_entries(select(.value|length>0)))'
    proposed="$(jq --argjson names "$names_json" "$FILTER" "$SJ")"
    if [ "$(jq -S . "$SJ")" = "$(printf '%s' "$proposed" | jq -S .)" ]; then ok "settings.json sin entradas de hooks migrados"
    else
        info "diff propuesto (quita los 7 hooks que ahora declara el plugin; JSON normalizado con jq):"
        diff -u --label "$SJ" --label "$SJ (propuesto)" <(jq . "$SJ") <(printf '%s\n' "$proposed") || true
        printf '  Aplícalo tú (copia de seguridad incluida):\n'
        # shellcheck disable=SC2016
        printf "    cp '%s' '%s.bak-'\$(date +%%Y%%m%%d) && jq --argjson names %s %s '%s' > '%s.new' && mv '%s.new' '%s'\n" \
            "$SJ" "$SJ" "'$names_json'" "'$FILTER'" "$SJ" "$SJ" "$SJ" "$SJ"
        RC=1
    fi
fi

cat <<'EOF'

-- Privacidad (captura activa)
  El hook capture-candidate guarda, ya REDACTADOS (gitleaks + regex), los prompts
  tuyos que parecen correcciones o confirmaciones, en un buffer 0700/0600 con TTL.
  Nada sale del host y ningún modelo los lee salvo que ejecutes /openbrain:capture.
  Desactivar: OPENBRAIN_CAPTURE_ENABLED=0 en openbrain.env.
EOF
exit "$RC"
