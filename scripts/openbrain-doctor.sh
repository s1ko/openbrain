#!/usr/bin/env bash
set -uo pipefail
_self="${BASH_SOURCE[0]}"; while [ -L "$_self" ]; do _t="$(readlink "$_self")"; case "$_t" in /*) _self="$_t" ;; *) _self="$(dirname "$_self")/$_t" ;; esac; done
case "$_self" in *\\*) command -v cygpath >/dev/null 2>&1 && _self="$(cygpath -u "$_self")" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

RC=0; QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
ok()   { [ "$QUIET" = 1 ] || printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; RC=1; }
fail() { printf '[FAIL] %s\n' "$*"; RC=1; }
sec()  { printf '\n== %s ==\n' "$*"; }

sec Cerebro
if [ -r "$OPENBRAIN_CONFIG_FILE" ]; then
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$(( n + 1 ))
        case "$line" in ''|'#'*) continue ;; esac
        k="${line%%=*}"
        case "$k" in
            OPENBRAIN_[A-Z0-9_]*) case "$k" in *[!A-Z0-9_]*) ;; *) continue ;; esac ;;
        esac
        warn "cerebro: openbrain.env: línea $n no coincide con ^OPENBRAIN_[A-Z0-9_]+= (ignorada)"
    done < "$OPENBRAIN_CONFIG_FILE"
fi
for p in MEMORY_HMAC_KEY:OPENBRAIN_HMAC_KEY MEMORY_ROOT:OPENBRAIN_MEMORY_ROOT MEMORY_BACKUP_DIR:OPENBRAIN_BACKUP_DIR \
         MEMORY_BACKUP_GPG:OPENBRAIN_BACKUP_GPG MEMORY_BACKUP_AGE_RECIPIENT:OPENBRAIN_BACKUP_AGE \
         MEMORY_BACKUP_AGE_IDENTITY:OPENBRAIN_BACKUP_AGE_IDENTITY MEMORY_BACKUP_KEEP:OPENBRAIN_BACKUP_KEEP \
         MEMORY_BACKUP_SIGN_KEY:OPENBRAIN_BACKUP_SIGN_KEY STALE_DAYS:OPENBRAIN_STALE_DAYS \
         MEMORY_INDEX_MAX:OPENBRAIN_MEMORY_INDEX_MAX REFRESH_DOCTRINE_TTL:OPENBRAIN_DOCTRINE_TTL \
         REFRESH_DOCTRINE_ALLOWLIST:OPENBRAIN_REFRESH_ALLOWLIST; do
    declare -p "${p%%:*}" >/dev/null 2>&1 && warn "cerebro: ${p%%:*} está en el entorno y ya no se lee: renombrar a ${p#*:}"
done
if ! command -v qmd >/dev/null 2>&1; then
    fail "cerebro: qmd no está en PATH (npm i -g @tobilu/qmd)"
else
    if qmd collection list 2>/dev/null | grep -qE "(^|[[:space:]])${OPENBRAIN_COLLECTION}([[:space:]]|$)"; then
        ok "cerebro: colección \"$OPENBRAIN_COLLECTION\" indexada"
    else
        fail "cerebro: colección \"$OPENBRAIN_COLLECTION\" no existe en el índice (qmd collection add \"$OPENBRAIN_WIKI_ROOT\" --name $OPENBRAIN_COLLECTION)"
    fi
    doc_out="$(qmd doctor 2>&1)"
    if printf '%s\n' "$doc_out" | grep -q '[✗⚠]'; then
        while IFS= read -r l; do warn "cerebro: qmd doctor: $l"; done < <(printf '%s\n' "$doc_out" | grep '[✗⚠]')
    else ok "cerebro: qmd doctor limpio"; fi
    if [ -d "$OPENBRAIN_WIKI_ROOT" ]; then
        ok "cerebro: wiki en $OPENBRAIN_WIKI_ROOT ($(find "$OPENBRAIN_WIKI_ROOT" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') artículos)"
        if command -v python3 >/dev/null 2>&1 && [ -n "$OPENBRAIN_COLLECTION" ]; then
            fresh=0
            while IFS= read -r l; do [ -n "$l" ] || continue; warn "cerebro: ${l#index-freshness: }"; fresh=1; done \
                < <(python3 "$SCRIPT_DIR/../eval/index-freshness.py" "$OPENBRAIN_COLLECTION" "$OPENBRAIN_WIKI_ROOT" 2>/dev/null)
            [ "$fresh" = 0 ] && ok "cerebro: índice al día con la wiki"
        fi
    else
        warn "cerebro: OPENBRAIN_WIKI_ROOT no existe: $OPENBRAIN_WIKI_ROOT"
    fi
    if [ -n "$OPENBRAIN_OTHER_COLLECTIONS" ]; then
        case " $(printf '%s' "$OPENBRAIN_OTHER_COLLECTIONS" | tr ',' ' ') " in
            *" $OPENBRAIN_COLLECTION "*) warn "cerebro: OPENBRAIN_COLLECTION \"$OPENBRAIN_COLLECTION\" figura en OPENBRAIN_OTHER_COLLECTIONS (no mezclar)" ;;
            *) ok "cerebro: otras colecciones del host (no mezclar): $OPENBRAIN_OTHER_COLLECTIONS" ;;
        esac
    fi
fi

sec Memoria
if [ ! -d "$OPENBRAIN_MEMORY_ROOT" ]; then
    fail "memoria: OPENBRAIN_MEMORY_ROOT no existe: $OPENBRAIN_MEMORY_ROOT"
else
    if command -v python3 >/dev/null 2>&1; then
        ok "memoria: firma HMAC por python3 (lote)"
    else
        miss=""
        for t in openssl xxd od; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
        if [ -n "$miss" ]; then fail "memoria: sin python3 y falta(n) para el shim en bash:$miss — la firma no se puede calcular"
        else warn "memoria: sin python3; firma por el shim en bash (más lento, requiere openssl xxd od)"; fi
    fi
    if hmac_key_ok "$OPENBRAIN_HMAC_KEY"; then ok "memoria: clave HMAC presente y en 600/400"
    else fail "memoria: clave HMAC ausente o con permisos laxos: $OPENBRAIN_HMAC_KEY"; fi
    memdirs=(); while IFS= read -r d; do memdirs+=("$d"); done < <(resolve_memdirs "$OPENBRAIN_MEMORY_ROOT")
    if [ ${#memdirs[@]} -eq 0 ]; then
        ok "memoria: todavía sin ningún memory/ bajo $OPENBRAIN_MEMORY_ROOT (nada que verificar)"
    else
        hv="$(bash "$SCRIPT_DIR/verify-memory-hmac.sh" "$OPENBRAIN_MEMORY_ROOT" verify 2>&1)"; hrc=$?
        c_ok="$(grep -c '^OK '     <<<"$hv")"; c_miss="$(grep -c '^MISS '   <<<"$hv")"
        c_fail="$(grep -c '^FAIL ' <<<"$hv")"; c_orph="$(grep -c '^ORPHAN ' <<<"$hv")"
        if [ "$hrc" -eq 0 ] && [ "$c_fail" = 0 ] && [ "$c_miss" = 0 ] && [ "$c_orph" = 0 ]; then ok "memoria: HMAC OK=$c_ok"
        else fail "memoria: HMAC OK=$c_ok MISS=$c_miss FAIL=$c_fail ORPHAN=$c_orph (openbrain memory verify)"; fi
        if bash "$SCRIPT_DIR/lint-memory.sh" "$OPENBRAIN_MEMORY_ROOT" >/dev/null 2>&1; then ok "memoria: lint limpio"
        else warn "memoria: lint con avisos (openbrain memory lint)"; fi
        cutoff="$(p_epoch_ago "$OPENBRAIN_STALE_DAYS" d)"; stale=0
        for d in "${memdirs[@]}"; do
            for f in "$d"/*.md; do
                [ -f "$f" ] && [ "${f##*/}" != MEMORY.md ] || continue
                ts="$(memory_review_epoch "$f")" || continue
                [ "$ts" -lt "$cutoff" ] && stale=$(( stale + 1 ))
            done
        done
        if [ "$stale" = 0 ]; then ok "memoria: ninguna memoria sin revisar >$OPENBRAIN_STALE_DAYS días"
        else warn "memoria: $stale memoria(s) sin revisar desde hace >$OPENBRAIN_STALE_DAYS días (openbrain memory index)"; fi
        for d in "${memdirs[@]}"; do
            [ -f "$d/MEMORY.md" ] || continue
            n="$(wc -l < "$d/MEMORY.md" | tr -d ' ')"
            [ "$n" -gt 200 ] && warn "memoria: $d/MEMORY.md tiene $n líneas — el harness trunca a 200"
        done
        gbytes=0
        for f in "$OPENBRAIN_GLOBAL_MEMORY"/*.md; do
            [ -f "$f" ] || continue
            s="$(p_stat_size "$f")"; gbytes=$(( gbytes + ${s:-0} ))
        done
        [ "$gbytes" -gt 65536 ] && warn "memoria: _global/memory inyecta $gbytes bytes en cada SessionStart (>65536): podar o bajar a un proyecto"
    fi
fi

sec Doctrina
if [ ! -d "$OPENBRAIN_DOCTRINE_DIR" ]; then
    warn "doctrina: OPENBRAIN_DOCTRINE_DIR no existe: $OPENBRAIN_DOCTRINE_DIR"
else
    nb="$(find "$OPENBRAIN_DOCTRINE_DIR" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"; ok "doctrina: $nb bloque(s)"
    if bash "$SCRIPT_DIR/openbrain-triggers-compile.sh" --check; then
        ok "doctrina: triggers.conf al día"
        while IFS=$'\t' read -r k _ b; do
            [ -n "$k" ] && warn "doctrina: $b: kind desconocido '$k' en triggers: (válidos: cwd files watch branch env mcp)"
        done < <(awk -F'\t' '$1 !~ /^(cwd|file|watch|branch|env|mcp)$/' "$OPENBRAIN_TRIGGERS_CONF" 2>/dev/null)
        for f in "$OPENBRAIN_DOCTRINE_DIR"/*.md; do
            [ -f "$f" ] || continue; blk="${f##*/}"; blk="${blk%.md}"
            awk 'NR==1 && $0!="---" {exit} NR>1 && /^---$/ {exit} /^triggers:/ {tr=1; next} tr && /^[^[:space:]]/ {tr=0} tr && /^[[:space:]]+[a-z]+:/ && !/^[[:space:]]+manual:/ {t=1; exit} END {exit !t}' "$f" 2>/dev/null || continue
            grep -q $'\t'"$blk"'$' "$OPENBRAIN_TRIGGERS_CONF" 2>/dev/null || warn "doctrina: $blk declara triggers: pero no compila ninguna regla (solo se activará a mano)"
        done
    else warn "doctrina: triggers.conf desfasado o ausente (se regenera en el próximo SessionStart)"; fi
    while IFS=$'\t' read -r date_dir blk state _; do
        [ "$state" = PENDIENTE ] && warn "doctrina: review pendiente: $blk ($date_dir) (openbrain review --mark $blk $date_dir tras aplicarlo)"
    done < <(doctrine_reviews "$OPENBRAIN_DOCTRINE_DIR/_review")
    if [ -f "$HOME/.claude/refresh.toml" ]; then ok "doctrina: refresh.toml presente"
    else warn "doctrina: ~/.claude/refresh.toml ausente — refresh-doctrine es un no-op para el CLAUDE.md global (plantilla: install/env/refresh.toml.example)"; fi
fi
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    warn "doctrina: python3 sin tomllib ($(python3 -V 2>&1)) — refresh-doctrine necesita Python >= 3.11; el bloque AUTO de CLAUDE.md no se refresca"
fi

sec Captura
if [ "$OPENBRAIN_CAPTURE_ENABLED" != 1 ]; then ok "captura: desactivada (OPENBRAIN_CAPTURE_ENABLED=$OPENBRAIN_CAPTURE_ENABLED)"
else
    pend=0; [ -r "$OPENBRAIN_CAPTURE_DIR/.pending" ] && pend="$(tr -dc '0-9' < "$OPENBRAIN_CAPTURE_DIR/.pending")"
    if [ "${pend:-0}" -gt 0 ]; then warn "captura: $pend candidatos pendientes (/openbrain:capture)"
    else ok "captura: sin candidatos pendientes"; fi
    if [ -d "$OPENBRAIN_CAPTURE_DIR" ]; then
        p="$(p_stat_perms "$OPENBRAIN_CAPTURE_DIR")"
        if [ "$p" = 700 ]; then ok "captura: buffer en 700"; else warn "captura: buffer con permisos $p (esperado 700)"; fi
        soon=$(( OPENBRAIN_CAPTURE_TTL_DAYS - 3 )); [ "$soon" -lt 0 ] && soon=0
        n="$(find "$OPENBRAIN_CAPTURE_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime "+$soon" 2>/dev/null | wc -l | tr -d ' ')"
        [ "${n:-0}" -gt 0 ] && warn "captura: $n fichero(s) de candidatos caducan en ≤3 días (/openbrain:capture)"
    fi
fi

sec Backup
if [ -z "$OPENBRAIN_BACKUP_AGE" ] && [ -z "$OPENBRAIN_BACKUP_GPG" ]; then
    ok "backup: desactivado (OPENBRAIN_BACKUP_AGE y OPENBRAIN_BACKUP_GPG vacíos)"
else
    case "$(p_os)" in
        linux)
            if ! command -v systemctl >/dev/null 2>&1; then ok "backup: sin planificador soportado"
            elif systemctl --user is-enabled openbrain-memory-backup.timer >/dev/null 2>&1; then ok "backup: planificador activo (openbrain-memory-backup.timer)"
            else warn "backup: planificador no activo (openbrain install --apply)"; fi ;;
        darwin)
            if ! command -v launchctl >/dev/null 2>&1; then ok "backup: sin planificador soportado"
            elif launchctl print "gui/$(id -u)/com.openbrain.memory-backup" >/dev/null 2>&1; then ok "backup: planificador activo (com.openbrain.memory-backup)"
            else warn "backup: planificador no activo (openbrain install --apply)"; fi ;;
        windows)
            if ! command -v schtasks >/dev/null 2>&1; then ok "backup: sin planificador soportado"
            elif schtasks /query /tn openbrain-memory-backup >/dev/null 2>&1; then ok "backup: planificador activo (openbrain-memory-backup)"
            else warn "backup: planificador no activo (openbrain install --apply)"; fi ;;
        *) ok "backup: sin planificador soportado" ;;
    esac

    newest_mtime=0
    if [ -d "$OPENBRAIN_BACKUP_DIR" ]; then
        for f in "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.age "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.gpg; do
            [ -f "$f" ] || continue
            m="$(p_stat_mtime "$f")"
            [ -n "$m" ] && [ "$m" -gt "$newest_mtime" ] && newest_mtime="$m"
        done
    fi
    if [ "$newest_mtime" = 0 ]; then
        warn "backup: ningún archivo en $OPENBRAIN_BACKUP_DIR (openbrain memory backup)"
    else
        age_days=$(( ( $(date +%s) - newest_mtime ) / 86400 ))
        if [ "$age_days" -gt 2 ]; then warn "backup: último archivo hace $age_days días"
        else ok "backup: último archivo hace $age_days día(s)"; fi
    fi
fi

sec Aprendizaje

if [ ! -r "$OPENBRAIN_EVAL_GOLDEN" ]; then
    ok "aprendizaje: eval sin configurar (sin golden set en $OPENBRAIN_EVAL_GOLDEN; plantilla: eval/golden.example.json)"
elif [ "$OPENBRAIN_EVAL_MAX_AGE_DAYS" = 0 ]; then
    ok "aprendizaje: aviso de frescura del eval desactivado (OPENBRAIN_EVAL_MAX_AGE_DAYS=0)"
elif [ ! -s "$OPENBRAIN_EVAL_METRICS" ]; then
    warn "aprendizaje: hay golden set pero $OPENBRAIN_EVAL_METRICS está vacío o ausente (openbrain eval)"
else
    m="$(p_stat_mtime "$OPENBRAIN_EVAL_METRICS")"
    age=$(( ( $(date +%s) - ${m:-0} ) / 86400 ))
    if [ "$age" -gt "$OPENBRAIN_EVAL_MAX_AGE_DAYS" ]; then
        warn "aprendizaje: recall sin medir desde hace $age días (>$OPENBRAIN_EVAL_MAX_AGE_DAYS) (openbrain eval)"
    else ok "aprendizaje: recall medido hace $age día(s)"; fi
fi

JDIR="$OPENBRAIN_DOCTRINE_DIR/_journal"
nblk="$(find "$OPENBRAIN_DOCTRINE_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${nblk:-0}" = 0 ]; then
    ok "aprendizaje: sin bloques de doctrina, nada que consolidar"
elif [ "$OPENBRAIN_REVIEW_SKIP" = 1 ]; then
    ok "aprendizaje: consolidación desactivada (OPENBRAIN_REVIEW_SKIP=1)"
elif [ ! -s "$JDIR/_sessions.jsonl" ]; then
    ok "aprendizaje: todavía sin sesiones con doctrina activa registradas"
else
    nses="$(jq -rR 'fromjson? | select(((.event // "") | test("^doctrine_(loaded|extended)$")) and ((.doctrines // []) | map(select(type == "string" and length > 0)) | length > 0)) | .session_id // empty' "$JDIR/_sessions.jsonl" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    nblkj="$(find "$JDIR" -maxdepth 1 -name '*.jsonl' ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${nses:-0}" = 0 ]; then
        ok "aprendizaje: todavía sin sesiones con doctrina activa registradas"
    elif [ "${nblkj:-0}" = 0 ]; then
        warn "aprendizaje: $nses sesión(es) con doctrina activa y ningún <bloque>.jsonl — el journal de Stop no está escribiendo"
    else
        ok "aprendizaje: journal de $nblkj bloque(s) sobre $nses sesión(es)"
        if ! find "$OPENBRAIN_DOCTRINE_DIR/_review" -mindepth 2 -maxdepth 2 -type f -name '*.md' 2>/dev/null | grep -q .; then
            warn "aprendizaje: hay journal pero nunca se consolidó una revisión (openbrain review --run <bloque>)"
        fi
        command -v claude >/dev/null 2>&1 || warn "aprendizaje: 'claude' no está en PATH — doctrine-consolidate no puede correr"
    fi
fi

exit "$RC"
