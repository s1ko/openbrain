# Notas de diseño

El código de runtime (`hooks/`, `scripts/`, `bin/`, `eval/`, `tools/`,
`Makefile`) no lleva comentarios: solo shebang y directivas `shellcheck`. Lo
que un comentario habría explicado vive aquí, indexado por fichero. Cada
entrada es un porqué que no se deduce leyendo el código: una decisión, una
restricción de portabilidad o de seguridad, un incidente que fijó una regla.
Al introducir una decisión así, añadir su entrada en el mismo cambio.

## Transversales

### Hooks fallan abiertos, scripts fallan cerrados
Cada hook resuelve `PLUGIN_ROOT` siguiendo symlinks a mano y, si el fichero se
movió o `common.sh` no es legible, avisa por stderr y sale 0: un hook roto
degrada la asistencia, nunca rompe la sesión. Los scripts de mantenimiento
(`scripts/*.sh`) hacen lo contrario: rc ≠ 0 y mensaje ante cualquier error real.
Dos excepciones deliberadas: `verify-memory.sh` sale 2 cuando una memoria
quedó escrita sin firma válida, sea porque la firma falló tras un lint
limpio (rc 0 o 1, estilo) o porque el propio linter falló (cualquier otro rc,
que bloquea la firma), y `capture-candidate.sh` descarta el candidato
si la redacción falla, porque lo que escribiría sin redactar podría ser un
secreto. `doctrine-consolidate.sh` tiene una única salida 0 silenciosa, la del
guard de `PLUGIN_ROOT`; a partir de ahí falla cerrado.
Los sub-hooks de SessionStart usan `set +e` y no `set -uo pipefail`: bajo
`set -u` una variable sin definir abortaba el subshell del despachador sin
aviso ni JSON, que es el fallo silencioso que el contrato fail-open quiere
evitar. Todo sub-hook cierra su bloque standalone con `exit 0` explícito, no
con el rc de la última función.

### El `session_id` es un nombre de fichero
Llega en un JSON externo y se concatena en rutas (estado por sesión, buffer de
captura, `openbrain capture show`). Todos los puntos aplican el mismo filtro,
`*[!A-Za-z0-9_.-]*|*..*`: un SID hostil no compone rutas. `session-doctrine.sh`
lo sustituye por un id sintético; los demás salen sin escribir.
El filtro vive en `brain_sid_ok` (`common.sh`) y lo aplica también el nombre
de bloque de doctrina en `doctrine-consolidate.sh` y `openbrain review --run`:
antes solo `--mark` lo validaba, y `--run ../../x` leía y escribía fuera del
árbol.

### Preservar el modo del fichero tras `mv` desde `mktemp`
`update-memory-index.sh`, `dedupe-global-memory-index.sh` y `mark-reviewed.sh`
sustituyen un fichero por su temporal con `p_replace_keep_mode`, que restaura
el modo original: `mktemp` crea en 600 y `mv` adopta ese modo, lo que
cambiaría en silencio un permiso fijado a propósito. `p_sed_inplace` se
retiró: ningún script edita in situ con `sed`, y un helper sin llamadores
solo mantenía viva una convención que nadie ejercía.

### Firma HMAC calculada en variable antes de tocar el sidecar
Una redirección `hmac_file … > f.hmac` trunca el sidecar al abrirse, antes de
que el cálculo termine: cualquier fallo (clave vacía, fichero ilegible un
instante) destruiría la firma válida anterior y, bajo `set -e`, abortaría el
bucle. Por eso se calcula primero, y solo con un digest no vacío se escribe
en un temporal y se mueve.
Esa secuencia vive en `hmac_write_sidecar` (`common.sh`), que además no
reescribe un sidecar cuyo contenido ya coincide: firmar el mismo directorio
dos veces no debe tocar N ficheros ni sus mtimes.

### `tmp` + `mv` contra symlinks plantados
Una redirección `> ruta` escribe a través de un symlink que alguien haya
puesto en esa ruta; `mv` sustituye el enlace en sí. Se usa para sidecars
`.hmac`, para el estado de sesión y para reescribir memorias. Por la misma
razón, el nombre del temporal lo elige `mktemp`, nunca un `"$FILE.tmp"`
predecible. A los destinos de backup y restore se les quita la barra final
antes de `-L`: con la barra, bash resuelve el enlace antes de que el test
pueda verlo.

### `confirm` trata EOF como "no"
En `bin/openbrain` y `openbrain-install.sh`, `read -r a || a=n`: con stdin cerrado
`read` devuelve 1 y, bajo `set -e`, abortaría sin mensaje. Nada destructivo se
dispara sin un `y` real.

### Detección por capacidad, no por sistema
`portable.sh` sondea qué acepta cada binario en vez de mirar `uname`: en un
Mac con coreutils de Homebrew delante en el PATH, `stat` ya es GNU y
"Darwin ⇒ BSD" fallaría. `OPENBRAIN_PORTABLE_FORCE=gnu|bsd` salta la sonda en
tests. El `timeout`/`gtimeout` de `refresh-doctrine.sh` sigue esa regla. El
planificador de backup en `openbrain-install.sh`, en cambio, elige primero por
`p_os` (`uname -s`), porque el destino en disco difiere por sistema
(LaunchAgents, unidad systemd de usuario), y solo después comprueba con
`command -v` que el binario exista.

`readlink -f` es GNU: macOS anterior a 12.3 y los BSD sin coreutils no lo
tienen. Por eso la cabecera de todo script y hook resuelve su propia ruta con
un bucle de `readlink` sin `-f` más `pwd -P`, y la única vía para canonicalizar
una ruta ajena es `p_abspath` (`realpath`, luego `readlink -f`, luego
`python3`). Diez scripts de `scripts/` llevaban `readlink -f` crudo en la
cabecera: sin él, `$(readlink -f x)` quedaba vacío, `dirname ""` daba `.`,
`SCRIPT_DIR` pasaba a ser el cwd y `source "$SCRIPT_DIR/lib/common.sh"`
cargaba lo que hubiera en el cwd o abortaba. `verify-memory.sh` lo usaba
para la ruta editada y salía 0 sin firmar y sin aviso. Los siete scripts que
despacha `bin/openbrain` y `eval/run.sh` componían la raíz con `dirname
"${BASH_SOURCE[0]}"` a secas, que no sigue symlinks: invocados a través de un
enlace cargaban el `lib/common.sh` del directorio del enlace, no el del
checkout. Las libs de `scripts/lib/` quedan fuera de la regla — se cargan por
`source` con la ruta ya resuelta por quien las carga, y el bucle pisaría el
`_self` del llamante.

### La clave HMAC y el corpus no pasan por argv
`ps` muestra los argumentos de cualquier proceso a otros usuarios del host.
La clave viaja por entorno (`python3`) o por descriptor, nunca como argumento
de `openssl`; el corpus de memoria global se emite por stdin a `jq`, nunca
como `--argjson`, lo que además esquiva el límite por argumento (128 KiB en
Linux).

### Estado de sesión bajo `XDG_STATE_HOME`, no en `/tmp`
Un nombre predecible en `/tmp` compartido más `>` permitiría que otro proceso
local hiciera que el hook sobrescribiera un fichero ajeno vía symlink. El
directorio es 0700 y la escritura atómica.

### Nonce por sesión en todo bloque citado
Doctrina y memoria global se inyectan delimitadas por un valor aleatorio por
sesión. Con un delimitador fijo, un bloque que contuviera `--- END … ---`
cerraría la cita y lo que siguiera se leería como instrucción.

### Cada lib de `scripts/lib/` se carga una vez
Las cinco abren con `[ -n "${_OPENBRAIN_X_LOADED:-}" ] && return 0`. `common.sh`
arrastra `portable.sh` y `config.sh` y el orden de carga lo decide cada script,
así que sin la guarda el mismo proceso releería `openbrain.env` línea a línea en
cada `source`. Recargar es idempotente —lo ya definido en el entorno gana sobre
el fichero, `declare -p` en `_brain_load_file`—, pero no es gratis.

## `hooks/`

### `openbrain-hook.sh`: un despachador para los eventos con varios hooks
SessionStart y Stop arrancaban tres `bash` y pagaban tres veces el sondeo de
`portable.sh`. El despachador resuelve la raíz, carga las libs y lee stdin una
vez, y ejecuta cada sub-hook como función en un subshell (aísla `set`, `shopt`,
traps y variables). Cada sub-hook sigue siendo ejecutable a pelo: su cabecera
y su cola solo corren cuando `OPENBRAIN_HOOK_SOURCED` no vale 1; los tests usan
ese modo. En SessionStart cada sub-hook emite su `additionalContext` crudo
(`brain_ctx_emit`); se captura con `part="$(…; printf X)"; CTX+="${part%X}"`
porque la sustitución de comandos recorta los saltos finales, y el despachador
envuelve una vez, con `python3` de respaldo si falta `jq`. El stderr de los
sub-hooks se conserva (avisos de verificación); el de `refresh-doctrine` se
descarta, como antes del despachador. En Stop los sub-hooks corren con stdout
y stderr descartados, salvo `sign-memory`, que conserva stderr acotado a tres
líneas (`head -3`): una memoria que se queda sin firmar es lo único que el
operador tiene que ver al cerrar. El proceso que `session-doctrine.sh`
lanza en background limpia `OPENBRAIN_HOOK_SOURCED` y `OPENBRAIN_HOOK_CTX` para que el
hijo corra su cuerpo standalone.

`refresh-doctrine` corre en background mientras los demás sub-hooks
producen su contexto, y el despachador hace `wait` antes de emitir el JSON:
su coste (hasta dos `timeout 10 python3`) se solapa en vez de sumarse, y el
hook sigue sin terminar antes de que el `CLAUDE.md` esté refrescado.

### `doctrine-watch.sh`: coste por tool call
La rama y el toplevel salen de `brain_git_branch_repo` (`common.sh`), el
mismo helper que usa `session-doctrine.sh`: un solo `git rev-parse` y, si no
hay toplevel absoluto (repo bare, directorio sin repo), rama vacía también —
antes `session-doctrine.sh` pagaba un `rev-parse --is-inside-work-tree`
extra para conseguir lo mismo.
Corre en cada `Bash`, cada `Read` y cada tool MCP (`hooks.json` matchea
`Bash|Read|mcp__.*`): es el único evaluador de la kind `mcp` de
`triggers.sh`, así que sin ese tercer patrón en el matcher un trigger `mcp:`
del frontmatter compilaba a TSV pero nunca podía dispararse — el matcher
gobierna qué invoca al hook, `triggers_active` gobierna qué patrón casa
dentro de él, y ambos tienen que estar de acuerdo en qué kinds existen.

Los cuatro campos del payload salen de
una sola llamada a `jq`, un campo por línea y no `@tsv` (el tabulador es
IFS-whitespace y `read` colapsaría los vacíos); el comando se aplana porque
solo alimenta la regex de cambio de rama. Lee el estado previo (rama y bloques)
del fichero que escribió `session-doctrine.sh` y sale en silencio si nada
cambió. Un cwd sin repo git da rama vacía, y eso es "sin señal", no "cambio de
rama": tratarlo como cambio invalidaría el contexto cada vez que una
herramienta tocara un directorio fuera de cualquier repo. Un `file_path` solo
cuenta cuando la tool es `Read`.

Los bloques activos son pegajosos dentro de la sesión: `ACTIVE` es siempre
`PREV_ACTIVE` (el estado previo, en su orden) más los nuevos que casan en
esta llamada, nunca solo lo que casa ahora mismo. Sin esto, un `Read` que
activa un bloque seguido de un `Bash` (que limpia `TOOL_FILE`) lo hacía
desaparecer del estado, y el siguiente `Read` del mismo fichero lo
re-inyectaba entero y añadía otra línea `doctrine_extended` al journal
compartido — una sesión que alterna `Read`/`Bash` sobre el mismo fichero
desplazaba las filas de otras sesiones al podarse en 1000 líneas. Un bloque
inyectado no puede des-inyectarse, así que "Bloques activos ahora" y el
journal reflejan siempre la unión, no el match puntual. El estado se lee y
reescribe bajo `brain_lock_acquire` sobre `<estado>.lock`: Claude Code
despacha a la vez las tool calls paralelas de un mismo turno, y dos hooks
haciendo read-modify-write cruzado perdían el bloque que escribió el primero.
Con el lock tomado el hook sale 0 sin inyectar; la siguiente llamada ya ve el
estado completo y lo inyecta entonces.

El journal solo recibe `doctrine_extended` cuando hay algún bloque activo: un
cambio de rama sin bloques se inyecta como contexto, pero no es telemetría de
doctrina. El estado previo (rama, repo y bloques) sale de una sola llamada a
`jq`: es el hook más frecuente del plugin.

Un cambio de rama solo repega el cuerpo de los bloques NUEVOS (`NEW_ONLY`);
los ya activos se listan por nombre bajo «Bloques activos ahora» sin
re-renderizar, y si no hay ninguno nuevo el aviso es una línea («Sin bloques
nuevos: los activos ya están inyectados.»). Antes se volvía a pegar el cuerpo
completo de cada bloque pegajoso en cada cambio de rama: una sesión que
alterna entre dos ramas conocidas (p.ej. `main`/`feature`) reinyectaba la
misma doctrina larga en cada vuelta, sin que hubiera nada nuevo que decir.

Un cambio de rama solo cuenta si viene de un `checkout`/`switch` explícito o
si el toplevel del repo coincide con el guardado en el estado (`repo`, que
escribe `session-doctrine.sh` al arrancar). Los subagentes heredan el
`session_id` de la sesión y trabajan en worktrees con su propia rama: sin
esta guarda, cada tool call suyo y cada uno de la sesión principal se turnaban
"cambiando de rama" contra el mismo estado — 442 inyecciones de «DOCTRINA
ACTUALIZADA» en un día. `repo` solo se acepta como ruta absoluta: en un repo
bare `rev-parse` imprime el propio flag en vez del toplevel. Un `checkout`
explícito de un subagente sí mueve el estado (rama, repo y bloques pegajosos)
a su worktree; se asume: lo inyectado sigue inyectado, y la sesión principal
se resincroniza en su siguiente `checkout` explícito.

Un `git checkout`/`switch` con flag de creación (`-b`/`-B`, `-c`/`-C`) se
acepta tal cual: la rama no existe todavía en el `PreToolUse`, así que no hay
nada contra lo que verificarla. Un nombre a secas, en cambio, se valida con
`git rev-parse --verify --quiet refs/heads/<nombre>` antes de tratarlo como
cambio de rama — sin eso, `git checkout algún-fichero.txt` parecía un cambio
de rama (la rama pasaba a llamarse como el fichero) y la siguiente llamada
revertía de vuelta, generando dos inyecciones espurias por cada checkout de
fichero. El coste de un `git rev-parse` extra solo se paga cuando la regex
ya casó, no en cada tool call. Con flag de creación se admite un start-point
detrás del nombre (`-b x origin/x`) y la forma larga `--create`.

El fast path explícito de `-b`/`switch` inyecta doctrina ANTES de que el
comando corra (es `PreToolUse`), así que no sabe si el `checkout` va a tener
éxito: un árbol sucio o un nombre ya usado por otra ref lo tumban. Por eso
graba la rama real de ese momento como `prev` en el estado. En la siguiente
llamada, si git informa que la rama sigue siendo `prev` (el checkout no
cuajó) y el repo no cambió, el estado se corrige a la rama real en silencio
— sin aviso de "cambio de rama" ni línea `doctrine_extended` — en vez de
tratar la vuelta a `prev` como un cambio de rama legítimo. Sin esto, un
`checkout -b` fallido dejaba una inyección fantasma «Branch: X → main» en la
siguiente tool call, sobre un cambio de rama que nunca ocurrió. El guardado
de `prev` exige repo igual (no solo rama igual): una vuelta a un nombre que
coincide por casualidad en otro repo no debe leerse como el mismo checkout
fallido.

### `session-doctrine.sh` y el lazy trigger
El timestamp de cooldown `.last_review.<bloque>` se escribe antes de lanzar
el consolidador, no después, para que dos sesiones en paralelo no disparen la
misma consolidación si ambas leen "pendiente" antes de que la primera
termine. Pero se escribe después de tomar el lock global, no antes: si el
lock está ocupado el hook devuelve sin consolidar nada, y estampar el
cooldown de todos modos apagaría la señal — la actividad que disparó la
revisión dejaría de contar hasta la siguiente ventana aunque nadie la haya
consolidado.

Con `source` ≠ `clear` (`resume`/`compact`, mismo `session_id`) el `active`
del estado previo se fusiona con lo que casa `start` en esta llamada, en vez
de sustituirlo: un `resume` tras perder el contexto solo re-evalúa `cwd` y
`branch` al arrancar, nunca un `Read`/`Bash` a mitad de sesión, así que un
bloque activado por `watch:` desaparecía del estado y de la inyección en
cuanto el harness compactaba o resumía — exactamente el caso de uso de
`watch:` (ficheros de configuración tocados a mitad de trabajo). Con
`source: clear` sí se resetea: es una sesión nueva y el estado previo no le
pertenece.

### `doctrine-lazy-check.sh`: un consolidador a la vez
Cada consolidación arranca un `claude -p`; N en paralelo multiplican coste y
carga sin adelantar nada. El lock lo toma primero el propio hook (para poder
devolver 0 sin más si ya hay uno vivo) y por eso `<LOCK>/pid` nace con el pid
del hook; en cuanto el subshell en background arranca, se sobreescribe con
`$!` porque bash 3.2 no tiene `BASHPID` dentro del subshell y `$$` allí sigue
siendo el hook, que para entonces ya ha terminado — dejaría el lock con un
pid muerto y `brain_lock_acquire` lo reclamaría antes de que el consolidador
acabe. Un bloque entra en cola si tiene journal
nuevo o notas manuales nuevas en `_journal/<bloque>.notes.md`; las notas
solas bastan, porque un bloque cuya doctrina nunca llega a cargarse no escribe
journal. Las notas marcadas a mano con `> APLICADA` no cuentan.
La marca vale en cualquier línea de la nota: solo en la primera tras el
título, una nota de varias líneas marcada al final se reencolaba para
siempre. Una nota sin cuerpo tampoco cuenta.

El conteo del `.jsonl` es por `sid` distinto, no por línea del `awk`: con
`doctrine-journal.sh` escribiendo una línea por turno (ver más abajo), contar
líneas convertía el gate en un temporizador de una hora que siempre
encontraba "actividad nueva" mientras la sesión siguiera abierta, sin que
importara si de verdad había algo que consolidar. Una nota solo abre si su
cabecera casa exactamente `## <YYYY-MM-DDTHH:MM:SSZ>` (ISO-8601 UTC, nada más
en la línea): antes cualquier `## ...` arrancaba una nota y su segundo campo
se comparaba como si fuera fecha contra el cutoff, así que un título humano
como «## Nota del 2026-09-08» («Nota» ordena por encima de cualquier dígito
en la comparación de cadenas) daba `cand=1` sin importar cuándo se escribió
de verdad la nota, y esa nota se contaba como actividad nueva en cada pasada
para siempre, sin relación con si ya se había consolidado.

Cada tanda deja un `~/.claude/logs/doctrine-consolidate-<bloque>-<ts>.log` y
nada más los tocaba; al lanzar una nueva se borran los de más de 30 días
(`brain_prune_older`). Solo entonces, porque solo entonces crece el
directorio.

### `doctrine-journal.sh`: evidencia desde el transcript
El journal por bloque se escribe en cada Stop, así que lleva cota (se poda
por líneas). Ya no lee `audit.log` del host: nada del plugin escribía los
eventos `post_write`/`bash_blocked`/`gitleaks_blocked` que buscaba, así que
`edit_count`/`edited_paths`/`tools_used`/`blocked_actions` eran siempre cero
o vacíos en cualquier instalación — telemetría, no evidencia. Ahora los
cuatro salen de una sola pasada de `jq` sobre el `transcript_path` que
entrega `Stop` (el JSONL de la conversación): los `tool_use` de los mensajes
`assistant` dan `tools_used` y, filtrados a `Write`/`Edit`/`MultiEdit`,
`edit_count` y `edited_paths` (más reciente primero, deduplicado con
`reduce`, no con `unique`, que ordena alfabéticamente y sesgaría los 10
primeros a los ficheros que empiezan por letra temprana); los `tool_result`
con `is_error: true` de los mensajes `user`, cruzados por `tool_use_id`
contra el mapa de `tool_use`, dan `blocked_actions` — solo el nombre de la
tool, nunca el texto del error, para que un mensaje de error que citara un
secreto no pueda colarse en el journal que luego lee `claude -p`. Solo se
acepta una ruta absoluta, regular y legible; con cualquier otra cosa las
stats quedan en cero sin abortar el hook. Medido: un transcript de 4.4 MB
tarda ~0.15 s.

El journal guarda ahora una línea por (sesión, bloque), no una por `Stop`:
`_dj_upsert` quita la línea previa de ese `sid` (si la hay) y añade la
nueva, conservando el `ts` de la primera y actualizando `ts_end` — tmp+mv
sin lock, con fallback a un `>>` simple si `mktemp`/`mv` fallan (duplicados
posibles pero raros, nunca pérdida de datos). Antes cada `Stop` añadía una
línea nueva; `Stop` dispara una vez por turno de asistente, así que una
sesión de 200 turnos dejaba 200 líneas casi idénticas, desplazando fuera de
la ventana `tail -200` que lee `doctrine-consolidate.sh` la evidencia de
otras sesiones — y el `.[0:10]` posterior al `unique` de `jq` (que ordena)
sesgaba `edited_paths` a los mismos 10 ficheros alfabéticamente primeros
para siempre. El evento pasa de llamarse `session_close` a `session`: lo
primero prometía un cierre que no existía, porque dispara por turno, no al
cerrar la sesión. Las líneas `session_close` de antes de este cambio se
siguen leyendo sin problema: todo lector clave por `ts`/`sid`, no por
`event`.

Los bloques de una sesión son la unión de todos sus eventos
`doctrine_loaded` (SessionStart, también en resume y compact) y
`doctrine_extended` (`doctrine-watch.sh` al activar bloques a mitad de
sesión): el último evento solo describe el estado final, no lo que estuvo
activo.

### `capture-flush.sh`
La purga por TTL no usa `find -delete` por coherencia con la denylist de
comandos destructivos del host. El payload se recibe como argumento y no se
usa: la purga es global, y bajo el despachador stdin ya se consumió. El
recuento que deja en `.pending` existe solo para que `load-global-memory.sh`
anuncie al arrancar cuántos candidatos esperan revisión.
Se cuenta con un solo `cat | wc -l` sobre el glob, no con un `wc` por
fichero: el buffer es de todo el host y crece con las sesiones.

### `refresh-doctrine.sh`
`refresh_claude_md.py` importa `tomllib` (Python ≥ 3.11) y el hook silencia
su salida, así que con un `python3` más viejo delante en el PATH (el
`/usr/bin/python3` de Xcode es 3.9) el splice dejaba de correr sin aviso.
`openbrain doctor` y `openbrain install` sondean `python3 -c 'import tomllib'` en vez
de comparar versiones: lo que importa es la capacidad, no el número.

Un marcador de TTL que sea symlink se borra en vez de usarse: confiar en él
permitiría redirigir `stat`/`touch` fuera del directorio de caché. El `~` del
allowlist se expande a mano porque `cd` no lo expande dentro de una variable
citada; `config.sh` hace lo mismo con `OPENBRAIN_REFRESH_ALLOWLIST`. La
herramienta se acota con `timeout` porque corre en serie dentro del
presupuesto de SessionStart.

El marcador de TTL solo se toca cuando la herramienta sale con rc 0: un
refresh fallido (manifiesto inválido, target no confiable, exit no-cero por
cualquier otra razón) no debe suprimir el próximo intento durante
`OPENBRAIN_DOCTRINE_TTL` (12 h) — el fallo tiene que reintentarse en la siguiente
sesión, no quedar silenciado medio día.

### `load-global-memory.sh`
Bajo el despachador emite el contexto crudo con `brain_ctx_emit`; standalone
envuelve el JSON él mismo. Verifica todo el directorio en una sola invocación
de `python3`, con las rutas por stdin como bytes y nunca por argv: un solo
nombre de fichero no-UTF-8 no puede tumbar la memoria global de toda la
sesión. El shim en bash (`openssl`+`xxd`+`od`) cubre los hosts sin `python3`.
Solo los ficheros con estado `ok` producen un marco en el contexto: un marco
vacío para un fichero saltado (sin firma, firma rota) contradecía el aviso
de stderr y diluía el significado de la verificación.

### `capture-candidate.sh`
Redacta antes de tocar disco y descarta el candidato si la redacción falla.
Ver "Hooks fallan abiertos, scripts fallan cerrados".

Ignora los prompts que empiezan por `<task-notification>`: las
notificaciones de tareas en segundo plano entran por UserPromptSubmit como
si fueran del usuario, y su texto («actually», «resolved») casa con las
señales de corrección.

La señal se busca en el prompt entero, pero lo que se guarda es una ventana
de 2000 bytes: si la coincidencia cae más allá del byte 1500 la ventana
arranca 500 bytes antes de ella, no en el byte 0 — un prompt largo con la
corrección al final guardaba 2000 bytes de contexto sin la lección. Los tres
campos del payload salen de una sola llamada a `jq`, separados por NUL y
leídos con `read -d ''`: el prompt es multilínea y un campo por línea lo
partiría.

`RX_CORR` se evalúa antes que `RX_CONF` y ahora incluye las formas negadas
(`no es/está así/correcto/exacto/bien`, `isn't/not right/correct`): sin
ellas, «no es correcto» casaba la palabra suelta «correcto» de `RX_CONF`
primero y el hook clasificaba una corrección como confirmación. Las palabras
sueltas `exacto`/`correcto`/`exactly` de `RX_CONF` solo cuentan en posición
de interjección — inicio de prompt o justo tras puntuación (`(^|[[:punct:]])`
antes de la palabra) — porque sin esa ancla cualquier frase que contuviera la
palabra en otro papel gramatical («necesito el número exacto de usuarios»)
generaba un candidato de confirmación sin que nadie hubiera confirmado nada.
El tope `OPENBRAIN_CAPTURE_MAX_PER_SESSION` se comprueba antes del `fork` de
`redact-before-haiku.sh` (gitleaks incluido), no después: una sesión que ya
llegó al tope no debe pagar el coste de redactar un candidato que se va a
descartar de todos modos.

### `verify-memory.sh`
Lint y firma se hacen sobre el fichero editado, no sobre su directorio. Con el
directorio entero, cada edición relintaba y volvía a pasar gitleaks por todos
los vecinos y reescribía todos sus sidecars, y un vecino con frontmatter
inválido o un secreto bloqueaba la firma del fichero que sí estaba bien. El
barrido de directorio sigue existiendo, pero es `openbrain memory lint`/`verify`
y `openbrain doctor`, que son quien debe verlo.
El hook descarta cualquier ruta que no acabe en `.md` antes de resolver
`PLUGIN_ROOT`, cargar las libs y canonicalizar con `p_abspath`: es
el `PostToolUse` de toda escritura de la sesión y casi ninguna es memoria.
Sin stdin (`[ -t 0 ]`, ejecutado a mano) sale 0 en vez de dejar a `jq`
esperando.
El filtro mira solo la extensión, no la ruta, para que un alias por symlink
hacia `memory/` siga llegando a la comprobación canónica de después.

### `sign-memory.sh`
`PostToolUse` solo casa `Write|Edit|MultiEdit`: una memoria escrita desde
`Bash` (heredoc, `tee`, un script) queda sin firma y `verify-memory.sh` no la
ve. Firmar en `Stop` cubre ese hueco, pero solo lo tocado dentro de la ventana
de la sesión: un barrido general pondría un HMAC válido también a lo que
alguien alteró fuera de banda, y la firma dejaría de ser un control. La
ventana la marca `sessions/<sid>.start` en `SessionStart`; `-nt` compara
segundos enteros, así que la marca se atrasa 2 s para que una memoria escrita
en el mismo segundo cuente como dentro. Las dos marcas de tiempo (`date` y
`touch -t`) se calculan en UTC: en hora local la hora repetida del cambio de
otoño es ambigua y `touch` elige la primera, una hora atrás. Un SessionStart
repetido (`compact`, `resume`) no mueve la marca: la ventana empieza en el
primer arranque de ese `session_id`, y la purga a 7 días acota lo que puede
envejecer. La marca vive en `sessions/` 0700; si en su lugar hay un symlink
se retira antes de escribir. Sin marca no se firma nada.
La ventana es temporal, no de autoría: cualquier proceso del mismo usuario
que escriba dentro de ella queda firmado. No es un límite nuevo — la clave
HMAC es un fichero 0600 del mismo uid y ese proceso podría firmar por su
cuenta; lo que el hook no hace es extender la confianza hacia atrás en el
tiempo. Por lo mismo el tope (`OPENBRAIN_SIGN_ON_STOP_MAX`, que cuenta por Stop)
es un detector de clave rotada o manipulación en bloque, no una barrera: se
rehúsa entero y se deja al operador (`openbrain memory verify`). Un valor no
numérico del tope vuelve al valor por defecto; un `verify` con rc 2 (clave
ausente o laxa, raíz vacía) se registra como `skipped` — sin log, un Stop
que no firma nada es indistinguible de uno que no tenía nada que firmar.
El lint corre sobre cada fichero, no sobre su directorio, por la misma razón
que en `verify-memory.sh`: un vecino inválido y fuera de ventana no debe
bloquear la firma del que sí está bien; `rc<=1` sigue firmando, igual que
`PostToolUse`: un aviso de estilo no deja la memoria sin firma. Todo queda en
`sign-memory.log` como JSON por línea con el `session_id`, para que lo
firmado, lo saltado y lo rehusado sea auditable.

El log es append por cada Stop y nada más lo tocaba: al pasar de 4000 líneas
se recorta a las últimas 2000 (`brain_prune_lines`).

## `scripts/lib/`

### `common.sh`: HMAC
`hmac_stdin` prefiere `python3` al shim en bash: mismo digest estándar, sin
depender de `xxd`, sin tres `openssl` y 64 iteraciones de shell por fichero,
y con la clave fuera de argv. Una clave de menos de 16 bytes solo avisa:
abortar rompería la verificación de árboles ya firmados. `hmac_files` y
`hmac_verify_json` hacen `rstrip(b"\n")` sobre la clave porque el shell la lee
con `cat`, que también absorbe el salto final; sin eso, dos vías de lectura
darían digests distintos. `hmac_equal` recorre toda la cadena en vez de
`[[ a == b ]]`, que corta en el primer byte distinto; comparar la longitud
antes es aceptable porque es pública. `hmac_key_ok` exige 600/400: el mismo
contrato fail-closed que `verify-memory-hmac.sh`. `resolve_memdirs` descarta
sin aviso un `memory/` que sea symlink: un proyecto cuyo directorio de
memoria es un enlace queda fuera de lint, firma, índice y métricas.
Descarta igualmente un directorio de proyecto que sea symlink: el `memory/`
real al que lleva no es de este árbol. El shim en bash calcula los pads
`ipad`/`opad` una vez por clave y los reutiliza: verificar N ficheros sin
`python3` rehacía el key schedule N veces. `resolve_memdirs` restaura
`nullglob` con un `trap RETURN` que expande la orden al declararse (SC2064
silenciado): quiere capturar el estado de entonces, no el de la salida.
`brain_nonce` sin `openssl` lee `/dev/urandom`; `$$-$RANDOM` es el último
recurso, con 15 bits de entropía no sirve como delimitador.

`hmac_install_sidecar` (tmp + `chmod 600` + `mv`, no-op si el contenido no
cambia) es la mitad mecánica de `hmac_write_sidecar`, extraída porque
`verify-memory-hmac.sh sign` también la necesita suelta. `hmac_write_sidecar`
recalcula el hash del fichero justo después de instalar el sidecar y, si ya
no coincide con lo firmado, vuelve a firmar (hasta 3 vueltas): sin lock, dos
firmantes concurrentes del mismo fichero (dos sesiones, o dos tool calls en
paralelo del mismo turno, cada una disparando `verify-memory.sh`) pueden
calcular su hash, y el que escribe el sidecar más tarde deja la firma sobre
contenido que ya no es el que hay en disco — el propio orden de escritura
decide cuál gana, y puede ganar la más vieja. El recálculo tras escribir
hace que el último sidecar en instalarse siempre describa el contenido final
sin necesitar un lock: el último escritor, por definición, ve ese contenido
al recalcular. Sin esto, `openbrain memory verify` reportaba `FAIL` sobre un
fichero que nadie manipuló, solo perdió una carrera de firmas.

`memory_review_epoch` centraliza la fecha de "última revisión" de una
memoria: el `reviewed:` del frontmatter si tiene forma de fecha válida y no
cae en el futuro, si no el mtime del fichero. La comparten
`update-memory-index.sh` (cuyo `reviewed_of` local hacía justo el parseo de
fecha, sin el fallback a mtime) y `openbrain-doctor.sh` (que antes solo miraba
si `reviewed:` existía, sin mirar la fecha) — antes de compartirla, las dos
rutas podían discrepar sobre qué memoria está "sin revisar", y de hecho lo
hacían: una memoria revisada una sola vez, hace años, contaba como fresca
para siempre en `openbrain doctor` pero como stale para `update-memory-index.sh`.

### `common.sh`: podas
`brain_prune_lines f max keep` recorta un fichero append-only a sus últimas
`keep` líneas cuando pasa de `max`, por temporal en el mismo directorio. Deja
el resultado en 600 en vez de conservar el modo: journal y log llevan datos
de sesión, y un fichero heredado con 644 sale de la poda corregido. Lo usan
el journal de doctrina (antes llevaba su copia local) y `sign-memory.log`. `brain_prune_older dir glob días` borra por edad
sin descender: los logs no son candidatos de captura y no necesitan
`p_secure_rm`.

### `common.sh`: `brain_lock_acquire`/`brain_lock_release`
El lock por `mkdir` caducaba por antigüedad del directorio (60 min de mtime)
sin que nadie la refrescara mientras `claude -p` corría: una consolidación
legítima más larga que eso perdía el lock y una segunda arrancaba en
paralelo. `brain_lock_acquire` guarda el pid del dueño en `<dir>/pid` y decide
"vivo" con `kill -0`, no con la edad del directorio; los 360 min de `find
-mmin` quedan solo como backstop contra reuso de pid (un pid reclamado por
otro proceso tras un reinicio no debe bloquear para siempre). Un lock sin
`pid` solo caduca a los 60 min, la semántica de 0.3.0 (que nunca escribía
pid): tratarlo como muerto al instante abría una carrera entre el `mkdir` y
la escritura del pid, y robaba el lock a un consolidador de 0.3.0 aún vivo
tras actualizar. Un `pid` no numérico sí cuenta como muerto. Dos límites
asumidos: `kill -0` confunde EPERM con muerto y `brain_lock_release` no
comprueba el dueño; el directorio de estado es por usuario y ningún
consolidador dura las 6 h del backstop, así que no se protegen.
El `find` del backstop solo corre si las comprobaciones anteriores no dieron
ya el lock por muerto. El `mkdir` del lock se intenta antes de asegurar su
directorio padre: el padre existe desde la primera sesión, y crearlo
"por si acaso" costaba un subshell y dos forks en cada tool call de
`doctrine-watch.sh`; solo si el `mkdir` falla y el padre no existe se crea y
se reintenta.

### `config.sh`: parser sin `eval`
El fichero es del usuario, pero un `eval` sobre él sería ejecución de código
si alguien lo pisa: las claves se filtran con `OPENBRAIN_[A-Z0-9_]+` y se asignan
con `printf -v`; `declare -p` decide si el entorno ya trae la clave (aunque
esté vacía), preservando entorno > fichero > default. `OPENBRAIN_COLLECTION` usa
`=` y no `:=`: un valor explícitamente vacío significa "sin scope" y
`openbrain recall` se niega a buscar, en vez de caer en silencio a la colección
por defecto. `OPENBRAIN_BACKUP_AGE` gana a `OPENBRAIN_BACKUP_GPG`; los dos vacíos
desactivan el backup. `OPENBRAIN_REVIEW_MAX_TURNS` existe porque un curator que se
enrosca cuesta dinero sin producir review.

### `portable.sh`
`p_date_to_epoch` convierte ida y vuelta porque BSD `date -j` no falla ante
2026-02-30: lo desborda a otra fecha válida. `p_epoch_ago` resta con
aritmética para no abrir otra rama `date -v` frente a `date -d`.

La sonda de sabor (GNU/BSD) es perezosa y por herramienta: `_p_stat`,
`_p_date` y `_p_b64` memoizan la primera vez que un `p_*` las necesita. Sondear las tres al cargar costaba tres forks en cada hook,
incluido `doctrine-watch.sh`, que corre en cada tool call y no usa ninguna.
La API pública es solo lo que tiene llamador: `p_sha256` y `p_find_newer` se
retiraron sin sustituto.

`p_os` gana `windows` para `uname -s` con prefijo `MINGW`/`MSYS`/`CYGWIN`
(lo que reporta Git Bash/MSYS2). No hace falta ninguna rama nueva en
`_p_stat`/`_p_date`/`_p_b64`/`p_secure_rm`: sondean por capacidad del binario,
no por SO, y Git for Windows trae coreutils GNU vía MSYS2 — `p_secure_rm` ya
caía a `rm -f` para cualquier SO no reconocido, así que Windows hereda ese
mismo fallback sin tocar el `case`.

**Riesgo abierto, sin verificar en Windows real**: los 28 entrypoints (todo
lo que resuelve su propio `_self` desde `BASH_SOURCE[0]`, `scripts/lib/common.sh`
queda fuera a propósito — ver su propia nota) añaden, justo tras el bucle de
resolución de symlinks, `case "$_self" in *\\*) command -v cygpath >/dev/null
2>&1 && _self="$(cygpath -u "$_self")" ;; esac`. Es una traducción defensiva
por si `${CLAUDE_PLUGIN_ROOT}` llega a Git Bash con separadores `\` en vez de
`/` — la documentación de Claude Code confirma que los placeholders de ruta
se sustituyen como string plano sin normalizar, pero no dice en qué forma
llegan bajo Git Bash. Si `_self` no lleva backslash (todo POSIX, todo
Windows-Git-Bash-nativo bien resuelto) o si `cygpath` no existe (macOS,
Linux), la línea es un no-op — cero riesgo fuera de Windows. Si en Windows
real `BASH_SOURCE[0]` ya llega en forma POSIX (`/c/Users/...`), esta línea
tampoco hace nada y sobra pero no rompe. Falta confirmar en una máquina
Windows real cuál de los dos casos ocurre.

### `render.sh`
Sustituye `{{CLAVE}}` en una sola pasada de regex, no con `replace()`
encadenados: un valor insertado que contuviera `{{OTRA}}` (journal, notas,
fuera de control) se expandiría o se colaría en el chequeo de huérfanos según
el orden del diccionario. Un placeholder sin valor es error, no un literal
que llega al prompt.

### `triggers.sh`
Dos predicados de desfase, ver `docs/09-triggers.md`. El matching es una
pasada en bash puro porque `session-doctrine.sh` y `doctrine-watch.sh` lo
pagan por sesión y por tool call.

El guard de `env` rechaza también el nombre vacío y el que empieza por
dígito: `${!p}` con un nombre inválido es un error fatal de expansión en
bash, no un simple "no casa", y abortaba `triggers_active` a mitad de bucle
dejando sin evaluar el resto de bloques. `triggers_compile` no lleva la
misma validación: filtrar ahí un nombre inválido es una rama nueva del awk,
no una línea, y silenciaría la regla en vez de que el operador la vea en el
TSV; el guard de runtime ya la neutraliza sin más cambios.
Un tabulador dentro del valor sí se sustituye por espacio al compilar: el
TSV es de tres columnas y `read` plegaría el resto en el nombre del bloque.
La clave de `kind` (`/^[[:space:]]+[a-z]+:/`) acepta cualquier indentación,
no solo dos espacios: el frontmatter es YAML tecleado a mano, y un bloque
con 4 espacios o un tabulador delante de `files:` compilaba CERO reglas sin
ningún aviso — el awk simplemente no reconocía la línea como cabecera de
kind y el bloque entero de triggers quedaba mudo.

Para `case` de bash `**` no significa nada: equivale a `*`, y `*` cruza `/`.
Lo que decide el match de un patrón `files:`/`watch:` con `/` es la barra
pegada al `**`: `src/**/*.rs` tal cual exige un `/` literal de más y nunca
casa `src/x.rs`. Por eso se prueban dos globs: `**/` → `*/` (una o más
carpetas) y `**/` → nada (cero). Con solo el segundo, `**/README.md` quedaría
en `*README.md` y casaría `NOTREADME.md`; `cwd:` no lo necesita porque
compensa el sufijo `/**` con un patrón aparte.

El modo `start` (presencia en `files:`, evaluado por `session-doctrine.sh` al
arrancar) traduce `**` por su cuenta, distinto del modo `watch`: primero
prueba el nivel cero con un glob normal (el `**/` quitado del patrón, `z` en
el código); si no hay match, paga un `find "$cwd" -path` con el patrón
colapsado a `*` (`g`) para cualquier profundidad, quedándose con el primer
resultado (`head -1`) y con el `cwd` escapado para `-path` (un `cwd` con
corchetes o `*` literales no debe leerse como patrón). Antes, un patrón con
`**` en `files:` no casaba nunca en `SessionStart`: sin `globstar`, bash
trata `**` como `*` normal (exactamente un nivel), así que `**/hooks/*.sh`
no casaba ni `hooks/x.sh` (cero niveles) ni `a/b/hooks/x.sh` (dos niveles).
El `find` solo se paga cuando el patrón lleva `**`: en un árbol grande sin
match, el coste de `SessionStart` es un recorrido completo, así que conviene
un glob llano (`hooks/*.sh`) cuando la profundidad ya se conoce.

## `scripts/`

### `backup-memory.sh`
El recipient de age debe ser `age1` + 58 caracteres bech32 y el de gpg una
huella completa de 40 hex: un id corto o un email fallan tarde o cifran para
la clave equivocada. La lista de ficheros va por NUL (`-print0`): un salto de
línea es legal en un nombre y con `-print` partiría la entrada en dos rutas
inexistentes, dejando memorias fuera sin aviso; es lista explícita porque BSD
`find` no tiene `-printf`. El tar va por tubería al cifrador: el claro no toca
disco. Con gpg el archivo solo se firma además de cifrarse si
`OPENBRAIN_BACKUP_SIGN_KEY` está definida; es la mitad productora de la firma que
`restore-memory.sh` exige confiable. La poda ordena por `p_stat_mtime`, no por `ls -t` (nombres raros) ni
`head -n -N` (extensión GNU que dejaba la poda rota en macOS). Un
`OPENBRAIN_BACKUP_KEEP` no numérico o 0 se rechaza: borraría todos los backups.
El valor se fuerza a base 10: `08` es un octal inválido en `(( ))` y dejaba
la poda muda. La lista de ficheros sale de `resolve_memdirs`, no de un `find`
con `*/memory/*` relativo a la raíz: con `OPENBRAIN_MEMORY_ROOT` apuntando a un
`memory/` directo ese patrón no casaba nada. Por eso `find` se invoca una vez
por directorio de memoria en vez de una vez sobre la raíz, y `rel` se
antepone con `./`: todo slug real de `path_to_slug` empieza por `-`
(`-tmp-proyecto`, el mismo formato que usa Claude Code para sus propios
directorios de proyecto), y `find -tmp-proyecto/memory` lo lee como una
opción desconocida, no como un path, y muere con «unknown predicate» — así
fallaba `openbrain memory backup` en cualquier instalación real y solo
`_global` (sin guion) sobrevivía. Los fixtures de bats usaban un slug sin
guion inicial (`proj-a`) y nunca lo vieron.

### `restore-memory.sh`
Para `.gpg` se rechaza una firma presente pero no confiada. age no firma: la
verificación HMAC posterior es la única comprobación de integridad para
`.age`, y por eso corre para ambos backends. Se recorren los `.md` y se busca
su `.hmac`, no al revés: recorriendo sidecars, un fichero al que quitaron el
`.hmac` nunca se comprobaría. Con `RESTORE_ALLOW_UNVERIFIED=1` los ficheros sin
verificar se retiran del staging antes de copiar nada, y el script termina con
1 igualmente: una restauración parcial nunca parece limpia.
Los `find` llevan `-type f`: un directorio llamado `x.md` en un archivo
corrupto entraba en la lista, y `rm -f` sobre él abortaba el script bajo
`set -e`. Los digests se calculan en lote con `hmac_files` (un `python3` para
todo el staging), con el mismo respaldo fichero a fichero que
`verify-memory-hmac.sh`.

### `verify-memory-hmac.sh`
`key="$(cat …)"` se comprueba explícitamente: bajo `set -e` una sustitución
fallida aborta sin mensaje, y modo 600 no garantiza lectura (ACL, atributos,
NFS). `collect_files` salta symlinks (la memoria global se procesa una vez bajo
`_global/`) y rutas con salto de línea (romperían la tabla
`<hex>\t<ruta>`, donde `-` significa "no se pudo calcular"). `compute_digests`
tiene dos niveles de respaldo: el lote `hmac_files` (un `python3` para todo el
árbol), y si falla o no produce salida, `hmac_file` fichero a fichero, que a
su vez cae al shim en bash cuando no hay `python3`. Antes de firmar se
reconfirma que el fichero no se convirtió en symlink desde que se listó: el
sidecar describiría el destino del enlace.
La clave que sea symlink se rechaza antes de mirar sus permisos: `stat` da
los del destino. Un `.md` regular como argumento firma o verifica solo ese
fichero (modo del hook `verify-memory.sh`); un sidecar cuyo contenido ya
coincide no se reescribe. Ese fichero tiene que resolver (`p_abspath`, ruta
física) a `OPENBRAIN_MEMORY_ROOT/<slug>/memory/<nombre>.md`, y ni `memory/` ni
`<slug>` pueden ser symlinks — la misma forma que exige `verify-memory.sh`.
El firmador de Stop toma rutas de la salida de `verify`, y `openbrain memory sign
<fichero>` acepta cualquier ruta: sin ese anclaje bastaría un directorio
llamado `memory` en cualquier punto del disco para obtener un HMAC válido. La
ruta relativa se acepta porque se compara ya resuelta. En modo
fichero `dirs` queda vacío y el barrido de sidecars huérfanos no corre: firmar
o verificar un fichero no debe opinar sobre el resto del directorio, y en bash
3.2 con `set -u` expandir `"${dirs[@]}"` vacío aborta el script.

### `doctrine-consolidate.sh`
El nombre de bloque, explícito o descubierto en `_journal/`, pasa por
`brain_sid_ok`. `--days` exige valor numérico: `shift 2` con un solo
argumento no desplaza nada y el bucle de argumentos giraba para siempre. La
comprobación de `claude` en PATH va después de `--dry-run`, que no lo invoca.
`claude -p` corre con `--allowedTools Write`: la restricción que la plantilla
pide en prosa la impone la CLI. Lo que no depende del bloque (commits
recientes, cutoff, prefiltro del audit) se calcula una vez fuera del bucle.
El trap de salida por bloque borra también el prompt y el log de `claude`: un
`kill` durante la llamada dejaba ambos temporales en `TMPDIR`.
Sin nombre de bloque, la selección automática solo considera bloques con
`doctrine/<bloque>.md` existente y journal o notas tocados en los últimos
`--days`; los nombres con `_` inicial son ficheros internos y se ignoran. Un
bloque sin fichero de doctrina es invisible aunque tenga journal: hay que
pasarlo explícito. Todo el contexto del prompt viaja como JSON (`jq -n --arg`) a
`render_template`: contenido arbitrario del journal, las notas o los commits
no puede romper la plantilla ni colar una inyección de shell. `--dry-run` no
deja rastro: ni `_review/<fecha>/` (que `openbrain review` listaría como pendiente
vacío) ni cooldown ni `audit.log`. La salida de `claude -p` se conserva:
sin ella, un review que no aparece no se distingue de un fallo de la CLI. Un
review regenerado borra el marcador `.applied` de la misma fecha: certificaba
otro contenido. El lock por bloque cubre el hueco que el lock global de
`doctrine-lazy-check.sh` deja a un `--run` manual. La lib de auditoría del
host (`~/.claude/hooks/lib/audit.sh`, Keychain) es opcional y no portable.
Éxito no es solo "`output_file` no vacío": en una re-consolidación del mismo
día el fichero ya trae el review anterior, así que si `claude` falla sin
escribir nada, `-s` sigue siendo verdad por el contenido viejo — se compara
`cksum` antes y después de la llamada, y solo un contenido distinto cuenta
como review nuevo. Sin ese cambio, un fallo silencioso borraría el marcador
`.applied` de un review que el humano ya validó, dándolo por pendiente otra
vez. El evento `doctrine_consolidate` del audit solo lista los bloques de
`DONE`, no todo `BLOQUES`: un bloque saltado por lock o sin review nuevo no
consolidó nada, y listarlo igual mentiría sobre lo que pasó esa corrida; si
`DONE` queda vacío, la llamada al audit ni se hace.

`prev_cksum` comprueba `[[ -f "${output_file}" ]]` antes de invocar `cksum`:
en la primera consolidación del día `output_file` no existe todavía, y
`cksum < missing_file` manda al log por bloque el «No such file or
directory» del propio bash antes de que `claude` haya corrido, ruido que no
dice nada sobre el review. Un review sin cambios que proponer escribe su
propio `## Sin cambios propuestos` (lo pide la plantilla) y ahora también
crea el `.applied.<bloque>` en el momento de escribirse, no cuando un humano
lo marca: un review sin propuestas no tiene nada que aplicar, así que
esperar a `openbrain review --mark` lo dejaba PENDIENTE para siempre en
`openbrain doctor`/`openbrain review` aunque no hubiera ninguna decisión pendiente.
`journal_recent` colapsa el `.jsonl` a la última línea por `sid` antes del
`tail -200` (el mismo criterio que aplica `doctrine-journal.sh` al escribir
una línea por sesión): sin eso, una sesión larga con journal por turno podía
llenar la ventana completa con sus propias líneas y dejar al curator sin
evidencia de ninguna otra sesión. La sección de eventos
`doctrine_loaded`/`doctrine_extended` del prompt (`AUDIT_DOCTRINE`) se
filtra de `sessions_recent`, precalculado una vez fuera del bucle desde
`_journal/_sessions.jsonl` — nunca del `audit.log` del host, que este script
no escribe ni depende de que exista.

### `openbrain-install.sh`
"Legacy" es un symlink en `hooks/` o `scripts/memory/` del host cuyo nombre
coincide con algo que ahora provee el plugin: el plugin nunca instala symlinks
ahí, y no se ancla el nombre del repo predecesor. La lista de duplicados
nativos es una foto cerrada de la migración, no una regla viva. Antes de
retirar se recomprueba el tipo: un symlink solo se borra si sigue siendo
symlink; `rm` nunca toca un nativo. El diff de `settings.json` se calcula
contra el JSON normalizado por `jq` (un diff crudo enterraría los hooks entre
cambios de sangría), sin eventos vacíos, y la orden impresa lleva `$(date …)`
sin interpolar para que el `.bak` lleve la fecha del momento real.
La unidad systemd y el plist se renderizan al instalar (`__BACKUP_DIR__`,
`__CONFIG_FILE__`, `__OPENBRAIN_BIN__`): con `ProtectHome=read-only` y
`ReadWritePaths` fijo al valor por defecto, un `OPENBRAIN_BACKUP_DIR` distinto
hacía fallar cada backup programado, y `ConditionPathExists` fijo saltaba el
timer en silencio bajo otro `XDG_CONFIG_HOME`. `node` se comprueba como
dependencia: `qmd` lo necesita.

La rama `windows` (Task Scheduler) no tiene equivalente de
`ConditionPathExists`: la XML de Task Scheduler no ofrece una condición
declarativa de "salta si falta este fichero", así que `__CONFIG_FILE__` ni se
sustituye ahí — si `openbrain.env` falta, `openbrain memory backup` falla al
arrancar en vez de no lanzarse, mismo resultado observable (backup no corre),
peor trazabilidad (un intento fallido en vez de ningún intento). El XML
renderizado se escribe en `$OPENBRAIN_BACKUP_DIR/openbrain-memory-backup.xml`
(no en un `mktemp` que se borra) a propósito: a diferencia del plist/unit no
hay un fichero "instalado" persistente que inspeccionar (la tarea vive en el
almacén interno de Task Scheduler), así que este es el único artefacto que
un operador puede releer o volver a registrar a mano con `schtasks /create
/xml ... /f` si algo falla. `<Command>` y la ruta pasada a `/xml` van por
`cygpath -w`: `schtasks.exe` los resuelve con las APIs de Windows, no con la
capa POSIX de MSYS2, y necesitan forma nativa (`C:\...`) aunque el resto del
script razone en rutas `/c/...`. **Sin verificar en Windows real**: si
`schtasks /create /xml` rechaza un XML en UTF-8 plano (hay reportes de que
en ciertas configuraciones regionales exige UTF-16) haría falta convertir con
`iconv -t UTF-16LE` y anteponer BOM antes de escribir el fichero — no
implementado porque no hay forma de confirmar el requisito sin la máquina.

El symlink `~/.local/bin/refresh-claude-md` que creaban versiones anteriores
se lista como legacy: `refresh-doctrine.sh` invoca la herramienta del plugin
y nada más lo usa.

### `openbrain-review.sh`

`--mark` escribe el marcador con `mktemp` + `mv -f` en el mismo directorio:
una redirección desnuda seguiría un symlink plantado en esa ruta y truncaría
su destino (ver «`tmp` + `mv` contra symlinks plantados»).

### `openbrain-doctor.sh`
Es el único sitio donde un typo en `openbrain.env` se hace visible: `config.sh`
descarta en silencio las claves que no casan. Comprueba que el bucle de
aprendizaje corre, no solo que sus ficheros existen: un bucle parado no da
error por sí mismo. Avisa de candidatos de captura a punto de caducar porque
un candidato caducado es una lección perdida.
`warn`/`fail` van a stdout a propósito: el informe se lee entero y en orden, y
redirigirlo a un fichero no debe partir los avisos del contexto; el rc≠0 ya
es la señal para scripts. Comprueba también el backup cuando hay backend
configurado (planificador activo y edad del último archivo): un timer que
dejó de correr no da error por sí mismo.

Avisa de los nombres de variable del repo predecesor (`MEMORY_*`,
`STALE_DAYS`, `REFRESH_DOCTRINE_*`) que sigan en el entorno: `config.sh` dejó
de leerlos sin sustituto, y el caso silencioso es un backup cifrado que se
desactiva porque `MEMORY_BACKUP_GPG` ya no llega. Cuenta consolidaciones por
la existencia de al menos una revisión generada (`_review/<fecha>/<bloque>.md`),
no por el sello `.last_review.<bloque>`: ese sello lo escriben
`doctrine-lazy-check.sh` y `doctrine-consolidate.sh` como cooldown *antes* de
lanzar `claude`, así que un intento fallido (sin PATH, sin auth) lo dejaría
puesto para siempre y silenciaría el aviso sin haber consolidado nada. El
`.last_review` global de 0.2.0 tampoco cuenta: se escribía en cada ejecución,
hubiera o no algo que consolidar. Las sesiones se cuentan por `session_id`
distinto, no por línea: `doctrine_extended` se escribe varias veces por
sesión (bloque nuevo, cambio de rama) y `SessionStart` se repite en cada
resume o compact. Un evento sin ningún bloque (`doctrines: []`, o `[""]` en
0.3.0, escritos por `doctrine-watch.sh` en cada cambio de rama) no hace de la
sesión una "sesión con doctrina activa"; se filtra por valor con `jq`, no por
literal, para que dé igual quién escribió la línea y con qué espacios.

Una instalación recién hecha, sin ningún `memory/` todavía bajo
`OPENBRAIN_MEMORY_ROOT`, imprime `[OK] memoria: todavía sin ningún memory/ ...
(nada que verificar)` y salta verify/lint/stale en vez de correr
`verify-memory-hmac.sh` sobre cero directorios y reportar
`[FAIL] memoria: HMAC OK=0 MISS=0 FAIL=0 ORPHAN=0`: un `FAIL` con todos los
contadores en cero no describe ningún problema real, y contradecía la
promesa de INSTALL.md §7 de que `openbrain doctor` sale en verde justo después
de instalar, antes de que exista una sola memoria.

`qmd doctor` se grepea por `[✗⚠]`, no solo `✗`: qmd 2.5.x reporta con `⚠`
las condiciones que sí importan para el recall híbrido (caché de modelo
ausente, documentos pendientes de embeddings) y nunca llega a imprimir `✗`
para ellas, así que mirar solo `✗` daba «qmd doctor limpio» con el híbrido
roto. La frescura del índice corre siempre que haya `python3` y
`OPENBRAIN_COLLECTION`, invocando `eval/index-freshness.py` directamente sobre
la colección y la wiki (sqlite de solo lectura de `qmd`, sin escribir nada):
antes esa misma comprobación solo se ejecutaba dentro de `openbrain eval`, que
exige tener un golden set — algo que INSTALL.md nunca pedía crear — así que
una instalación por defecto, con `qmd` sano y la wiki editada a mano sin
`qmd update`, no tenía ninguna señal de desfase. El aviso de `_global/memory`
sobre 65536 bytes es una constante fija, como el límite de 200 líneas de
`MEMORY.md`: esa capa se inyecta entera y sin recorte en cada `SessionStart`
de cada proyecto (`load-global-memory.sh`), así que su tamaño es coste fijo
por sesión, no un límite de un solo proyecto. `OPENBRAIN_OTHER_COLLECTIONS` que
incluye al propio `OPENBRAIN_COLLECTION` sube de informativo a aviso: la
variable solo la lee `openbrain doctor` (documentado en el propio
`openbrain.env.example`, no en `openbrain recall`), pero listarse a sí misma como
"colección a no mezclar" es casi siempre un error de configuración.

En Doctrina, cada regla compilada cuyo `kind` no es uno de `cwd file watch
branch env mcp` genera un aviso con el bloque de origen: un typo en el
frontmatter (`cwds:` en vez de `cwd:`) compila igual a una línea del TSV sin
que `triggers_compile` lo distinga de una kind válida, y esa regla nunca
casa nada; sin este aviso el operador solo lo nota cuando el trigger que
esperaba simplemente no dispara nunca. Por el mismo motivo avisa por bloque
cuyo frontmatter declara una kind no-`manual` que no aportó ninguna fila a
`triggers.conf` — un bloque `manual:`-only es intencional y no avisa. Los
punteros de `refresh.toml` ausente y de eval sin configurar señalan sus
plantillas (`install/env/refresh.toml.example`, `eval/golden.example.json`):
un aviso sin remedio a mano es doble trabajo para quien lo lee.

### `openbrain-recall.sh`
Sin `-c`, `qmd` busca en todas las colecciones del host, y alguna puede ser
confidencial: con `OPENBRAIN_COLLECTION` vacía el wrapper se niega a buscar.

### `redact-before-haiku.sh`
Dos capas, ambas fail-closed: gitleaks (obligatorio) y un scrub por regex para
clases de PII que gitleaks no cubre (email, DNI/NIE, IBAN, tarjeta, teléfono).
Sobre-redactar es la dirección de fallo elegida. Hueco residual deliberado:
una palabra clave suelta con solo un espacio de separador (`password hunter2`)
no se redacta, porque en prosa esas palabras son demasiado comunes y la tasa
de falsos positivos hacía la regla inviable; las claves compuestas
(`api_key`, `client_secret`) sí, aun con espacio. Un prepaso `awk` arma la
redacción de la línea siguiente cuando una línea es solo una clave sensible
con valor vacío (forma YAML/env partida), que `sed` no ve por ser línea a
línea. Sin `\b` (BSD sed) y solo ERE. Su log no es `audit.log`, que es
evidencia firmada.

### `dedupe-global-memory-index.sh`
No deduplica texto: poda en cada `MEMORY.md` las líneas que enlazan a una
memoria global del mismo nombre cuando el proyecto ya no tiene copia local.
El nombre se mantiene por compatibilidad con la CLI y las docs.

### `mark-reviewed.sh`
Sin sidecar previo avisa y no firma: firmar aquí daría por buena una memoria
que nunca pasó el lint.
Confina la mutación al árbol bajo `OPENBRAIN_MEMORY_ROOT`: para operar sobre otro
árbol (una restauración en staging) se apunta la variable allí, no se dan
rutas arbitrarias. Inserta `reviewed:` con `awk`: `sed -i` y el
direccionamiento `0,/re/` son extensiones GNU.

### `update-memory-index.sh`
Una fecha `reviewed:` bien formada pero imposible (2026-02-30) se trata como
ausente y se cae al mtime, en vez de mostrar una antigüedad absurda.
Recorre `resolve_memdirs` como sus hermanos y falla cerrado sin directorios:
con el glob a mano, `openbrain memory index <memdir>` no hacía nada y decía
`done`. El enlace de cada línea lo extrae `memory_index_link_target`
(`common.sh`), el mismo parser que `dedupe-global-memory-index.sh`, en bash y
sin fork. Su antiguo `reviewed_of` local se retira en favor del
`memory_review_epoch` compartido con `openbrain-doctor.sh` (`common.sh`): el
parseo de fecha era idéntico en los dos sitios, y solo aquí caía a mtime
cuando faltaba `reviewed:`.

### `memory-metrics.sh`
bash 3.2 no tiene `declare -A`: el mapa slug → ruta es una tabla
`slug<TAB>ruta` en un temporal consultada con `awk`. Las claves de
`~/.claude.json` se leen por NUL porque una clave JSON puede contener un salto
de línea; una ruta con salto o tabulador se descarta porque la tabla no puede
representarla. Sin `jq` o sin `~/.claude.json` legible, la columna `cwd` es
`?` para todos los proyectos y no hay aviso: el inventario sigue siendo útil
sin ella. Una raíz que no existe es error (rc 2), no una tabla vacía con rc 0.

### `openbrain-capture.sh`
`show` exige al `session_id` el mismo alfabeto que usa el hook al escribir,
para no poder leer nada fuera del directorio de capturas.

### `lint-memory.sh`
El `~` de `FORBIDDEN_PATTERNS` es un literal que se busca dentro de la
memoria, no una ruta: por eso se silencia SC2088.
`lint_dir` usa `dotglob` como `verify-memory-hmac.sh`: un `.oculto.md` se
firmaba sin haber pasado por el lint. Un `.md` regular como argumento lintea
solo ese fichero (modo del hook).
`check_index_targets` avisa (STYLE, no bloquea la firma) de una entrada de
`MEMORY.md` cuyo link apunta a un nombre de fichero llano, del mismo
directorio, que no existe: usa `memory_index_link_target` para no reimplementar
el parser del índice, y solo mira objetivos sin `/` (un link a otra ruta no
es responsabilidad de este chequeo). Sin esto, una entrada del índice que
apuntaba a un fichero renombrado o borrado se quedaba ahí indefinidamente,
sin que nada la señalara.

## `bin/`, `eval/`, `tools/`, `Makefile`

### `bin/openbrain`
El gate de confirmación de `dedupe` mira dos superficies, el flag `--apply` y
la variable `DEDUPE_APPLY=1`, porque el script acepta ambas; comprobar solo el
flag pediría menos confirmación de la debida. `restore` no pasa por `confirm`:
su guarda es `RESTORE_FORCE=1` (se niega a sobrescribir un destino con `.md`)
más la verificación HMAC previa, y el flujo documentado empieza siempre por
el modo `test`.

### `eval/recall-eval.py`
El timeout por consulta es ajustable por `QMD_EVAL_TIMEOUT` en vez de
reintentar: el harness falla cerrado ante un timeout, y una máquina cargada es
indistinguible de una rota; el backend híbrido arranca con un default mayor
porque carga modelos. El match es por basename, no `endswith` simétrico
(`second-openbrain-overview.md` no acredita a `overview.md`), y asume `wiki/`
plano: si anida, pasar `expected_files` a rutas relativas a `wiki/`.
`collection` es obligatorio por la misma razón que en `openbrain recall`.
Sin argumento posicional sale con un mensaje de uso, no con un golden path
por defecto: ese default apuntaba a un fichero que el plugin no distribuye,
así que `openbrain eval` sin golden set configurado terminaba en un traceback de
Python en vez de un error legible.

### `eval/run.sh`
`p_date_iso` se llama sin argumento a propósito (SC2119 silenciado): sin
epoch devuelve "ahora", y el `$1` de `run.sh` es el flag `--hybrid`, no una
fecha. `--hybrid` se hace `shift` antes de invocar `recall-eval.py`, y el
resto de argumentos (`"$@"`) se reenvía tal cual: sin ese reenvío,
`--verbose` no tenía forma de llegar desde `openbrain eval --verbose` hasta el
runner de Python, que sí lo entiende. Antes de medir, compara la
`collection` que declara el golden set con `OPENBRAIN_COLLECTION` y se niega si
difieren: sin esa guarda, un golden set copiado de otro host o de otra
colección medía en silencio un recall que `openbrain recall` nunca ejecuta.

### `eval/index-freshness.py`
Compara el SHA-256 del contenido con el hash que `qmd` guarda, no el mtime: un
fichero tocado sin cambios es fresco. Abre el índice en solo lectura: es
estado derivado de `qmd`. `eval/run.sh` ignora cualquier fallo suyo: un aviso
nunca bloquea una medida.
La ruta del índice respeta `XDG_CACHE_HOME`, como `qmd`: con la ruta fija el
aviso de frescura desaparecía sin decirlo.
Recibe `<collection> <wiki>`, no la ruta del golden set: antes derivaba la
colección leyendo el `collection` del golden set, así que sin un golden set
configurado (el caso normal de una instalación por defecto) la comprobación
de frescura era imposible de invocar fuera de `openbrain eval`. Separar la
colección del golden le permite a `openbrain-doctor.sh` invocarlo directamente
con `OPENBRAIN_COLLECTION`. El prefijo de sus avisos es `index-freshness:`, no
`run.sh:`: ahora lo llaman dos programas distintos, y el mensaje no debe
mentir sobre cuál.

### `tools/refresh-claude-md/refresh_claude_md.py`
Escribe su propio log y no `~/.claude/audit.log`: ese es evidencia firmada y
una línea sin firma lo marcaría como manipulado. Exige objetivo y manifiesto
sin escritura de grupo u otros, también en su directorio, y no symlink.

El `timeout` de `refresh-doctrine.sh` es opcional (solo si `timeout`/`gtimeout`
está en el `PATH`) y mata al proceso antes de que corra `splice()`, perdiendo
la escritura entera aunque algunos campos ya hubieran resuelto. Por eso el
presupuesto total va dentro de la herramienta, no solo en el hook:
`REFRESH_CLAUDE_MD_BUDGET` (default 8 s, por debajo del `timeout 10` del hook)
se mide con `time.monotonic()` y cada campo recibe `min(TIMEOUT, restante)`
como timeout propio; agotado el presupuesto, los campos que faltan toman su
`default` igual que un timeout por campo, y `splice()` corre siempre al
final del bucle. Un valor de entorno inválido cae al default en silencio,
igual que un campo sin comando; `nan` e `inf` también, porque con `nan`
ninguna comparación del restante es cierta y el presupuesto dejaría de
aplicarse. Un presupuesto agotado sigue siendo rc 0 y toca el marcador de
TTL: los `default` son un refresco válido y el reintento llega con el TTL,
no en cada sesión.
El presupuesto se acota a `TIMEOUT - 1`: un valor de entorno por encima del
`timeout 10` del hook reproducía el fallo que el presupuesto existe para
evitar. Un campo del manifiesto sin `label` o sin `command` cuenta como
fallido (y sale con su `default` si tiene `label`), no desaparece: un typo en
la clave era indistinguible de un manifiesto vacío.

### `Makefile`
`shellcheck -P scripts`: los `source=lib/common.sh` (o `../scripts/lib/…`
desde `hooks/`) son rutas dinámicas en runtime; sin `-P` shellcheck las
resuelve relativas al cwd de invocación y SC1091 dispara aunque
`external-sources=true` y el `source=` sean correctos.
