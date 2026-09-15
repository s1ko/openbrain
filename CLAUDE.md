# CLAUDE.md

Guía para sesiones de Claude Code que trabajen **en** este repo (no para
sesiones que solo lo usen como plugin instalado — eso es `README.md`).

## Qué es este repo

El plugin de Claude Code `openbrain`: fuente única de la maquinaria de recall
(`qmd`), memoria en cascada firmada, doctrina dinámica y captura activa.
**No lleva contenido**: ni wiki real, ni memorias reales, ni bloques de
doctrina reales, ni rutas/hostnames/nombres de empresa de ningún host. Todo
lo que aquí se versiona son scripts, hooks, comandos, skills, plantillas y
tests — nunca los datos que esas piezas operan.

## Comandos

```bash
make test          # lint (shellcheck) + bats + pytest
make lint           # solo shellcheck -x -s bash sobre scripts/hooks/bin/eval
make test-bats       # solo la suite bats
make test-py         # solo pytest (tools/refresh-claude-md, tests/py)
make clean           # borra tests/.bats-tmp y las cachés de pytest/__pycache__
mkdir -p tests/.bats-tmp && TMPDIR=$PWD/tests/.bats-tmp bats tests/bats/NN-nombre.bats    # una sola suite
```

## Convenciones

- **bash 3.2 compatible** en todo `scripts/` y `hooks/`: sin `mapfile`, sin
  `declare -A`, sin `${var,,}`, sin `[[ -v ]]`. Shebang `#!/usr/bin/env bash`.
- **Nunca `sed -i` directo.** Escribe a un temporal (`mktemp "$f.XXXXXX"`)
  y sustituye con `p_replace_keep_mode destino temporal`
  (`scripts/lib/portable.sh`: conserva el modo del destino y hace `mv`).
- **Detección por capacidad, no por SO** en `scripts/lib/portable.sh` —
  sondea qué acepta `stat`, no `uname`.
- **Cero comentarios en el código de runtime** (`hooks/`, `scripts/`, `bin/`,
  `eval/`, `tools/`, `Makefile`): solo shebang y directivas `# shellcheck`.
  El porqué de una decisión no evidente va a `docs/11-design-notes.md`,
  indexado por fichero; una sección nueva allí acompaña al cambio que la
  motiva. Los tests sí pueden llevar comentarios.
- **Hooks fallan abiertos**: todo fichero en `hooks/` termina en `exit 0`
  (o `set +e` con guardas explícitas) — un hook roto degrada la asistencia,
  nunca rompe la sesión. Excepción deliberada: `verify-memory.sh` sale 2
  cuando una memoria quedó escrita sin firma válida (o el lint falló por
  error), para que el fallo de integridad no pase en silencio.
- **Scripts de mantenimiento fallan cerrados**: `scripts/*.sh` sale con
  rc≠0 y mensaje a stderr cuando algo va mal — nunca en silencio.
- **Encabezado estándar de hook** (ver cualquier fichero en `hooks/`):
  resolver `PLUGIN_ROOT` a través de symlinks, comprobar que
  `scripts/lib/common.sh` es legible, y salir `0` con aviso a stderr si no
  — antes de tocar nada más.
- **Fixtures sintéticas siempre.** Ningún test toca `~/.claude/projects/`
  ni `~/knowledge` reales; todo bajo `$BATS_TEST_TMPDIR` con `HOME`
  redirigido (`setup_fake_home` en `tests/bats/helpers.bash`).
- **`make test-bats` fija `TMPDIR=tests/.bats-tmp`.** Con `/tmp` montado
  `noexec`, los stubs `chmod +x` que escriben los tests no arrancan y los
  hooks los ven como no ejecutables. Al lanzar `bats` a mano, exportar el
  mismo `TMPDIR`. Como el tmpdir queda dentro de este repo git,
  `setup_fake_home` fija `GIT_CEILING_DIRECTORIES` al padre de
  `$BATS_TEST_TMPDIR` (git no bloquea el propio cwd, solo el ascenso más allá
  del techo) para que los hooks no descubran esta rama desde un cwd
  sintético. Los canarios de fuga han de ser sintéticos: la ruta del tmpdir
  contiene el nombre del usuario real.

## Qué NO hacer

- No editar `~/.claude/settings.json` desde ningún script: `openbrain-install.sh`
  imprime el diff, lo aplica el humano.
- No meter rutas del host (`/Users/...`, `/home/...`), hostnames, nombres
  de empresa ni identificadores de expediente en código de runtime,
  fixtures no marcadas como sintéticas, o docs.
- No referenciar el nombre ni el path absoluto del repo predecesor fuera de
  la línea de "Historia" de `README.md`, que ya lo cita como continuación.
- No usar `sed -i` directo — siempre temporal + `p_replace_keep_mode`.

## Mapa `hooks.json` ↔ ficheros

Los eventos con varios hooks (SessionStart, Stop) van por un único despachador,
`hooks/openbrain-hook.sh <evento>`: resuelve la raíz, carga las libs y lee stdin una
sola vez, y ejecuta cada sub-hook como función en un subshell. Cada fichero de
sub-hook sigue siendo ejecutable a pelo (los tests lo usan así): su cabecera y su
cola standalone solo corren cuando `OPENBRAIN_HOOK_SOURCED` no vale `1`.

| Evento | Comando en `hooks.json` | Sub-hooks (en orden) |
|---|---|---|
| SessionStart | `openbrain-hook.sh SessionStart` | `refresh-doctrine.sh`, `sign-memory.sh` (marca), `session-doctrine.sh`, `load-global-memory.sh` |
| UserPromptSubmit | `capture-candidate.sh` | — |
| PreToolUse (`Bash\|Read\|mcp__.*`) | `doctrine-watch.sh` | — |
| PostToolUse (`Write\|Edit\|MultiEdit`) | `verify-memory.sh` | — |
| Stop | `openbrain-hook.sh Stop` | `doctrine-journal.sh`, `capture-flush.sh`, `doctrine-lazy-check.sh`, `sign-memory.sh` |

`doctrine-lazy-check.sh` corre además en background al arrancar: lo lanza
`session-doctrine.sh` fuera de `hooks.json` (salvo `OPENBRAIN_REVIEW_SKIP=1`), así
que una consolidación puede dispararse al inicio y al cierre de la sesión.
`sign-memory.sh` deja en SessionStart la marca de ventana de sesión y en Stop
firma solo las memorias sin firma válida modificadas después de esa marca
(`OPENBRAIN_SIGN_ON_STOP=0` lo desactiva).

En SessionStart los sub-hooks no imprimen su propio JSON: con
`OPENBRAIN_HOOK_CTX=1` escriben su `additionalContext` crudo a stdout (helper
`brain_ctx_emit` en `common.sh`), el despachador lo captura, lo concatena en
orden y lo envuelve una vez (`jq`, con `python3` de respaldo). Los presupuestos
de `hooks.json` para SessionStart y Stop son la suma de sus sub-hooks;
`refresh-doctrine` acota su herramienta con `timeout` cuando existe. Fuente de
verdad: `hooks/hooks.json`.

## Commits

Trailer único: `Signed-off-by:` (`git commit -s`). Nunca `Co-authored-by`,
`Assisted-by`, ni ninguna mención a IA/Claude/Anthropic en el mensaje.
