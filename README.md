# openbrain

Plugin de Claude Code: segundo cerebro con recall (`qmd`), memoria en
cascada firmada con HMAC, doctrina dinámica y un bucle de mejora continua.
macOS + Linux.

## Qué es

Cuatro piezas que comparten un mismo repo pero se activan por separado.

**Recall** — un wiki interconectado (artículos Markdown con `[[wikilinks]]`,
indexado por `qmd`) que el modelo consulta antes de asumir metodología,
convenciones o contexto técnico "de memoria". `openbrain recall` fuerza el
scope a una única colección, para que una búsqueda nunca mezcle el cerebro
de este host con otra colección del mismo `qmd`.

**Memoria en cascada** — la auto-memory nativa de Claude Code
(`~/.claude/projects/<slug>/memory/*.md`, tipos `user`/`feedback`/`project`/`reference`)
firmada con HMAC-SHA256 tras cada escritura, más un índice `MEMORY.md` por
proyecto y una capa global opcional (`_global/memory/`) inyectada en todas
las sesiones.

**Doctrina dinámica** — bloques de instrucciones especializadas
(`~/.claude/doctrine/*.md`) que se activan solos según `cwd`, ficheros
tocados, rama git, variables de entorno o el MCP invocado, en vez de vivir
siempre cargados en el system prompt. Un compilador convierte el
frontmatter `triggers:` de cada bloque en reglas planas que dos hooks
consultan: uno al arrancar la sesión, otro en cada tool call `Bash` o `Read`
(una escritura sin lectura previa no dispara: ver `docs/09-triggers.md`).

**Captura activa** — un cuarto pilar, más discreto: un hook detecta en cada
prompt señales de corrección o confirmación del usuario y las guarda,
redactadas, como candidatos a lección. Nadie las lee automáticamente; se
revisan a mano con `/openbrain:capture`. Detalle completo de qué se guarda y
por qué en [`docs/10-capture-privacy.md`](docs/10-capture-privacy.md).

## Qué NO lleva

Este repo es **maquinaria, no contenido**. No incluye artículos de wiki
reales, memorias reales, bloques de doctrina reales, ni ninguna ruta,
hostname, nombre de empresa o identificador de expediente del host donde se
usa. Todo eso vive fuera del repo, en los directorios que señala
`openbrain.env` (`OPENBRAIN_WIKI_ROOT`, `OPENBRAIN_MEMORY_ROOT`, `OPENBRAIN_DOCTRINE_DIR`).
Lo que se versiona aquí son los scripts, hooks, comandos, skills y
plantillas que operan sobre ese contenido — nunca el contenido en sí.

## Instalación

Resumen de seis pasos (detalle completo en [`INSTALL.md`](INSTALL.md)):
instalar dependencias (`bash jq openssl gitleaks gpg python3 node qmd`,
con `python3 >= 3.11`),
registrar el plugin (`claude plugin marketplace add` + `claude plugin
install openbrain@openbrain`), `openbrain install --apply` para crear `openbrain.env` y la
clave HMAC, editar `openbrain.env`, dar de alta la colección en `qmd`, firmar la
memoria existente (`openbrain memory sign`) y verificar con `/openbrain:doctor`.

## Comandos

| Comando | Qué hace | Escribe |
|---|---|---|
| `/openbrain:doctor` | Salud de cerebro (incluida frescura del índice frente a la wiki y tamaño de `_global/memory`), memoria, doctrina, captura y bucle de aprendizaje. Solo lectura. | No |
| `/openbrain:recall <consulta>` | Busca en el cerebro con scope forzado a la colección configurada. | No |
| `/openbrain:ingest <fuente>` | Incorpora una fuente nueva al wiki (raw → artículos → INDEX → log). | Sí — `wiki/*.md`, `INDEX.md`, `log.md` |
| `/openbrain:eval [--hybrid] [--verbose]` | Mide recall (BM25 y/o híbrido) contra el golden set. | Sí — anexa a `metrics.log` |
| `/openbrain:review [--run <bloque> \| --mark <bloque> <fecha>]` | Lista reviews con estado, lanza una consolidación, o marca un review como aplicado. | Sí — el fichero de review (`_review/<fecha>/<bloque>.md`) y el marcador `.applied.<bloque>`; nunca el bloque de doctrina |
| `/openbrain:capture` | Revisa candidatos de lección capturados y los promueve a memoria/wiki, uno a uno. | Sí — solo con OK explícito por candidato |
| `/openbrain:memory <op>` | Operaciones de memoria: `lint verify sign index metrics promote mark-reviewed backup restore dedupe search redact`. | Depende de `op` — ver más abajo |
| `/openbrain:install [--check\|--apply] [--remove-legacy]` | Verifica o instala lo que el plugin necesita fuera del repo. | Sí con `--apply`/`--remove-legacy`, siempre fuera de `settings.json` |

`/openbrain:memory`: `lint`, `verify`, `metrics`, `search` y `redact` son de
solo lectura. `sign`, `index`, `dedupe`, `promote` y `mark-reviewed`
escriben memoria curada y piden confirmación en terminal antes de tocar
nada (salvo que se pase `--yes`). `backup` y `restore` **no** piden
confirmación en terminal: `backup` solo escribe el archivo cifrado en
`OPENBRAIN_BACKUP_DIR` (requiere `OPENBRAIN_BACKUP_AGE` o `OPENBRAIN_BACKUP_GPG`); `restore <archivo>
<destino> extract` puede sobrescribir memoria y se protege con la variable
`RESTORE_FORCE=1` (se niega si el destino ya tiene `.md`), no con un prompt —
empieza siempre por `restore <archivo> <destino> test`.

## CLI `openbrain`

`bin/openbrain` es el punto de entrada estable — humanos, planificadores
(backup) y los propios comandos lo invocan como `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain"`
si `openbrain` no está en `PATH` (lo que deja `openbrain install --apply` en
`~/.local/bin/openbrain`):

```
uso: openbrain <comando> [args]
  doctor                         salud de cerebro/memoria/doctrina/captura/aprendizaje (solo lectura)
  recall [--lex|--hybrid] [-n N] [--json] <q>  buscar en el cerebro con scope forzado
  capture list|show <sid>|purge  candidatos de lección de la captura activa
  eval [--hybrid] [--verbose]    medir recall y anexar a metrics.log
  review [--run <b>|--mark <b> <fecha>]  reviews de doctrina con estado / consolidar / marcar aplicado
  memory <op> [args]             lint verify sign index metrics promote mark-reviewed backup restore dedupe [--apply] search redact
  install [--check|--apply] [--remove-legacy]  verificar/instalar (imprime el diff de settings.json, nunca lo aplica)
  triggers [--force|--check]     compilar triggers de doctrina
  config                         valores efectivos de OPENBRAIN_* (openbrain.env + defaults)
  version | help
```

Las ops de memoria que **escriben** (`sign index dedupe promote
mark-reviewed`) piden confirmación; `--yes` la omite (pensado para
planificadores, no para uso interactivo casual).

## Skills y agente

| Skill/agente | Se dispara cuando |
|---|---|
| `recall` | Antes de asumir metodología, doctrina o convención técnica sin comprobarla; al mencionar "el cerebro", "la wiki" o "qmd". |
| `ingest` | Al crear/actualizar artículos de wiki, ingerir una fuente nueva en `raw/`, o cuando un recall revela un hueco que merece documentarse. |
| `lesson-capture` | Cuando el usuario corrige ("no, …", "en realidad…", "recuerda que…") o valida explícitamente un enfoque no obvio ("exacto", "así sí"). |
| `memory-governance` | Antes de escribir, editar o borrar cualquier fichero de memoria, o al decidir si algo merece recordarse. |
| `librarian` (agente) | Pases largos de lectura sobre el wiki: ingest de varias fuentes, lint de contradicciones/wikilinks rotos/huérfanos, para no ensuciar el contexto principal. |

## Configuración

Precedencia: **variable de entorno > `~/.config/claude/openbrain.env` >
default compilado**. El fichero solo admite claves `OPENBRAIN_[A-Z0-9_]+` con
valor literal (nunca se evalúa); solo se expande un `~` o `$HOME` inicial.

| Variable | Default | En `openbrain.env.example` |
|---|---|---|
| `OPENBRAIN_REPO_ROOT` | `~/knowledge` | Sí |
| `OPENBRAIN_WIKI_ROOT` | `$OPENBRAIN_REPO_ROOT/wiki` | Sí |
| `OPENBRAIN_COLLECTION` | `openbrain` | Sí — **vacío explícito = sin scope**; `openbrain recall` se niega a buscar en vez de caer a un default en silencio |
| `OPENBRAIN_OTHER_COLLECTIONS` | *(vacío)* | Sí |
| `OPENBRAIN_EVAL_GOLDEN` | `$OPENBRAIN_REPO_ROOT/.eval/golden.json` | Sí |
| `OPENBRAIN_EVAL_METRICS` | `$OPENBRAIN_REPO_ROOT/.eval/metrics.log` | Sí |
| `OPENBRAIN_EVAL_MAX_AGE_DAYS` | `30` (0 = no avisar) | Sí |
| `OPENBRAIN_MEMORY_ROOT` | `~/.claude/projects` | Sí |
| `OPENBRAIN_GLOBAL_MEMORY` | `$OPENBRAIN_MEMORY_ROOT/_global/memory` | No — derivada, ver `INSTALL.md` |
| `OPENBRAIN_HMAC_KEY` | `~/.config/claude/memory.hmac` | Sí |
| `OPENBRAIN_STALE_DAYS` | `60` | Sí |
| `OPENBRAIN_MEMORY_INDEX_MAX` | `165` | Sí |
| `OPENBRAIN_SIGN_ON_STOP` | `1` (0 = no firmar en Stop) | Sí |
| `OPENBRAIN_SIGN_ON_STOP_MAX` | `25` (más fallos que esto y Stop no firma nada) | Sí |
| `OPENBRAIN_DOCTRINE_DIR` | `~/.claude/doctrine` | Sí |
| `OPENBRAIN_DOCTRINE_TTL` | `43200` (segundos, 12 h) | Sí |
| `OPENBRAIN_REVIEW_MAX_TURNS` | `30` | Sí |
| `OPENBRAIN_REFRESH_ALLOWLIST` | `~/.claude/refresh-allowlist` | Sí |
| `OPENBRAIN_TRIGGERS_CONF` | `$XDG_CACHE_HOME/openbrain/triggers.conf` | No — derivada, ver `INSTALL.md` |
| `OPENBRAIN_REVIEW_SKIP` | `0` | No — derivada, ver `INSTALL.md` |
| `OPENBRAIN_OPERATOR_CONTEXT` | `operador técnico` | Sí |
| `OPENBRAIN_CODE_REPO` | *(vacío)* | Sí |
| `OPENBRAIN_CAPTURE_ENABLED` | `1` | Sí |
| `OPENBRAIN_CAPTURE_DIR` | `$XDG_STATE_HOME/openbrain/candidates` | No — derivada, ver `INSTALL.md` |
| `OPENBRAIN_CAPTURE_TTL_DAYS` | `14` | Sí |
| `OPENBRAIN_CAPTURE_MAX_PER_SESSION` | `40` | Sí |
| `OPENBRAIN_BACKUP_AGE` | *(vacío; recipient `age1…`, gana sobre GPG)* | Sí |
| `OPENBRAIN_BACKUP_GPG` | *(vacío; huella de 40 hex. Los dos vacíos = backup desactivado)* | Sí |
| `OPENBRAIN_BACKUP_DIR` | `~/.claude/backups/memory` | Sí |
| `OPENBRAIN_BACKUP_KEEP` | `30` (copias que se conservan) | Sí |
| `OPENBRAIN_BACKUP_SIGN_KEY` | *(vacío; huella gpg para firmar además el backup)* | Sí |
| `OPENBRAIN_BACKUP_AGE_IDENTITY` | `~/.config/claude/memory-backup-key.txt` | Sí |

## Frontera de seguridad

De los 12 hooks que este pipeline cablea en un host típico, **7 migran al
plugin y 5 se quedan en el host**:

| Migran al plugin (7) | Evento |
|---|---|
| `refresh-doctrine.sh` | SessionStart |
| `session-doctrine.sh` | SessionStart |
| `load-global-memory.sh` | SessionStart |
| `doctrine-watch.sh` | PreToolUse |
| `verify-memory.sh` | PostToolUse |
| `doctrine-journal.sh` | Stop |
| `doctrine-lazy-check.sh` | Stop |

Los eventos con varios sub-hooks (SessionStart, Stop) los cablea `hooks.json`
a través de un único despachador, `hooks/openbrain-hook.sh <evento>`, que carga las
libs y lee stdin una vez y ejecuta cada sub-hook como función en un subshell —
sin arrancar tres `bash` por evento. Cada fichero sigue siendo ejecutable a
pelo. `doctrine-lazy-check.sh` corre también al arrancar: `session-doctrine.sh`
lo lanza en background fuera de `hooks.json`. `sign-memory.sh` no migra de
ningún host: es nuevo en el plugin y va por el mismo despachador, en
SessionStart (marca la ventana de sesión) y en Stop (firma las memorias sin
firma válida modificadas dentro de ella; `OPENBRAIN_SIGN_ON_STOP=0` lo desactiva).

Los 5 que se quedan (arranque de sesión, tripwires de bash y de secretos,
log de auditoría y resumen de sesión) son **controles**, no asistencia. Un
plugin se puede desactivar por proyecto vía `settings.local.json`; si un
control de seguridad viviera dentro del plugin, desactivarlo apagaría el
tripwire en silencio. La frontera resultante: el plugin es dueño del
conocimiento, la memoria y el aprendizaje; el host conserva los controles y
la auditoría. La doctrina dinámica sí migra porque es asistiva — orienta el
trabajo, no lo restringe.

Esa frontera vale en los dos sentidos: **el bucle de doctrina no depende del
`audit.log` del host**. Cada `SessionStart` con bloques activos deja una línea
en `$OPENBRAIN_DOCTRINE_DIR/_journal/_sessions.jsonl` (modo 600, podado a las
últimas 1000 entradas), y el hook `Stop` la lee para escribir el journal por
bloque que dispara la consolidación. Las métricas de edición de esa línea
(herramientas usadas, ficheros tocados, bloqueos) salen del `transcript_path`
que el propio harness pasa a `Stop`, no de `audit.log`: la ausencia de
`audit.log` — la norma en una instalación limpia — nunca dejó el bucle
parado, y `openbrain doctor` avisa si la cadena de todos modos se rompe.

El plugin, además, **nunca edita `settings.json`**: `openbrain install`
imprime el diff a aplicar y lo aplica el humano.

## Privacidad de la captura

Ver [`docs/10-capture-privacy.md`](docs/10-capture-privacy.md): qué guarda
el hook de captura activa, dónde, con qué permisos, cuánto dura, cómo se
redacta antes de tocar disco y cómo desactivarla o purgarla.

## Tests

```bash
make test          # shellcheck + bats + pytest, en este host
mkdir -p tests/.bats-tmp && TMPDIR=$PWD/tests/.bats-tmp bats tests/bats/NN-nombre.bats   # una suite concreta
```

Toda la suite corre con `HOME` redirigido a un directorio temporal
(`setup_fake_home` en `tests/bats/helpers.bash`) y fixtures sintéticas bajo
`$BATS_TEST_TMPDIR` o `tests/fixtures/` — ningún test toca `~/.claude/projects/`
ni `~/knowledge` reales.

## Layout

```
openbrain/
├── .claude-plugin/    plugin.json, marketplace.json
├── commands/          doctor recall ingest eval review capture memory install
├── skills/            recall ingest memory-governance lesson-capture ...
├── agents/            librarian
├── hooks/             openbrain-hook.sh (despachador), session-doctrine load-global-memory refresh-doctrine doctrine-watch verify-memory doctrine-journal doctrine-lazy-check capture-candidate capture-flush sign-memory
├── scripts/           implementación; scripts/lib/ = config.sh portable.sh triggers.sh common.sh render.sh
├── eval/              golden set y runners de recall
├── install/           systemd/ launchd/ git/ env/ — plantillas instalables
├── templates/         memoria, artículo de wiki, bloque de doctrina
├── tools/refresh-claude-md/   splice de doctrina en CLAUDE.md, con su propia suite pytest
├── tests/             bats/ + fixtures/ (siempre sintéticas)
├── docs/              07-runbook.md, 09-triggers.md, 10-capture-privacy.md, 11-design-notes.md (los porqués del código); history/ = arqueología del predecesor
└── CLAUDE.md  README.md  INSTALL.md  Makefile  LICENSE
```

## Historia

`openbrain` es la continuación de `claude-memory-docs`, con la historia del
repo original intacta: los mismos scripts de memoria (lint, firma HMAC,
backup cifrado, dedupe) empaquetados como plugin de Claude Code, con
doctrina dinámica, recall vía `qmd` y captura activa añadidos encima.

### Scripts heredados

Mapeo script → mejora, heredado del README del repo original, con las
rutas actualizadas a este layout:

| Script | Mejora | Qué hace |
|---|---|---|
| `scripts/lint-memory.sh` | A1 | Valida frontmatter + gitleaks + paths prohibidos. Acepta toda la raíz o un único `memory/`. `MEMORY.md` también escaneado (incluye entradas del índice que apuntan a un fichero borrado). Salta symlinks. |
| `scripts/update-memory-index.sh` | A2 | Anota `(YYYY-MM-DD)` y `stale` en cada línea de `MEMORY.md`, usando frontmatter `reviewed:` si existe, mtime si no. Re-firma el índice si cambió. |
| `scripts/mark-reviewed.sh` | A2 | Inserta/actualiza `reviewed: YYYY-MM-DD` en el frontmatter de un fichero de memoria. |
| `scripts/backup-memory.sh` | A4 | `tar \| age` o `tar \| gpg` en pipe directo, incluye `.md` **y** `.md.hmac`. Requiere `OPENBRAIN_BACKUP_AGE` o `OPENBRAIN_BACKUP_GPG`; opcional firma adicional. |
| `scripts/restore-memory.sh` | A4 | Desencripta + extrae un archive a un destino; modo `test` para smoke check sin tocar nada. |
| `scripts/verify-memory-hmac.sh` | C2 | `sign` y `verify` HMAC-SHA256 (incl. `MEMORY.md`). Acepta raíz, `memory/` único o un solo `.md` — este último solo si resuelve a `OPENBRAIN_MEMORY_ROOT/<slug>/memory/` (rc 2 si no). Salta symlinks; no reescribe un sidecar que no cambia; `verify` reporta sidecars `ORPHAN`. |
| `scripts/memory-metrics.sh` | C4 | Inventario por proyecto: bytes, edad, firma HMAC, cwd real. Salta symlinks; raíz inexistente es error. |
| `scripts/redact-before-haiku.sh` | C3 | gitleaks + regex específicas (gh/aws/gcp/slack/privkey/email/IBAN/DNI/tarjeta/teléfono) sobre stdin o fichero. En este plugin, cableado automáticamente en la captura activa. |
| `scripts/dedupe-global-memory-index.sh` | C1/P7 | Dry-run por defecto: imprime qué líneas de cada `<slug>/memory/MEMORY.md` apuntan a `_global/memory/*.md`. `--apply` (o `DEDUPE_APPLY=1`) las elimina; idempotente; `openbrain memory dedupe --apply` pide confirmación. |
| `hooks/load-global-memory.sh` | C1/P7 | SessionStart — inyecta `_global/memory/` como `additionalContext`, verificando el HMAC de cada fichero y delimitándolo con un nonce por sesión. |
| `hooks/refresh-doctrine.sh` | doctrina | SessionStart — regenera el bloque `AUTO-START…AUTO-END` de `~/.claude/CLAUDE.md`; el `CLAUDE.md` local del cwd solo si el cwd figura en `OPENBRAIN_REFRESH_ALLOWLIST` (un directorio por línea, absoluto o con `~/` inicial; `#` comenta). La herramienta (`tools/refresh-claude-md/refresh_claude_md.py`) se acota a sí misma con `REFRESH_CLAUDE_MD_BUDGET` segundos en total (default `8`, ha de quedar por debajo del `timeout 10` del hook); pasado ese presupuesto, los campos restantes toman su `default` sin ejecutarse. |
| `hooks/verify-memory.sh` | A1/C2 | PostToolUse — lint + firma HMAC del fichero de memoria editado (solo ese, no su directorio) tras cada escritura. Única excepción al "fallan abiertos": sale 2 (Claude ve el error) si la memoria quedó escrita pero sin firma válida. |
| `hooks/sign-memory.sh` | C2 | SessionStart deja la marca `sessions/<sid>.start`; Stop firma las memorias con `FAIL`/`MISS` modificadas después de la marca, una a una y tras pasar el lint (`rc<=1`). Lo anterior a la marca se registra como fuera de banda y se deja fallando; más de `OPENBRAIN_SIGN_ON_STOP_MAX` (25) fallos se rehúsan en bloque. Log JSON en `$XDG_STATE_HOME/openbrain/sign-memory.log`; `OPENBRAIN_SIGN_ON_STOP=0` lo desactiva. |

## Changelog

Ver [`CHANGELOG.md`](CHANGELOG.md).

## Licencia

MIT — ver [`LICENSE`](LICENSE).
