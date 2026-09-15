# Triggers de doctrina — formato y paridad

La doctrina dinámica vive en `$OPENBRAIN_DOCTRINE_DIR/*.md` (default
`~/.claude/doctrine/`), un bloque por fichero. La fuente de verdad es el
frontmatter `triggers:` de cada bloque; el plugin lo compila a un TSV plano
que los hooks consultan sin volver a parsear YAML en caliente.

## Frontmatter → TSV

`scripts/openbrain-triggers-compile.sh` recorre `$OPENBRAIN_DOCTRINE_DIR/*.md`,
extrae la sección `triggers:` de cada frontmatter y escribe una línea por
regla en `$OPENBRAIN_TRIGGERS_CONF` (default `$XDG_CACHE_HOME/openbrain/triggers.conf`,
modo 600):

```
kind<TAB>pattern<TAB>block
```

`kind` es uno de: `cwd`, `file`, `watch`, `branch`, `env`, `mcp`. La clave
`manual:` del frontmatter (el texto de `/doctrine <bloque>`) no genera fila
— es solo documentación para humanos. Las líneas de comentario dentro de una
lista YAML (`# ...`) también se descartan.

Recompila solo si hace falta. Dos predicados en `scripts/lib/triggers.sh`,
ambos con el builtin `-nt` y sin forks: `triggers_stale` (el conf no existe o
algún `*.md` de `$OPENBRAIN_DOCTRINE_DIR` es más nuevo) es lo que significa
"desfasado" para `--check`; `triggers_touched` añade el mtime del propio
directorio (una entrada creada, borrada o renombrada: un bloque nuevo o
retirado, pero también un subdirectorio como `_review/`) y es lo que usan los
hooks y `openbrain triggers` sin flag para decidir recompilar, porque recompilar
es barato y deja el conf más nuevo que el directorio. Los hooks lo hacen en
proceso con `triggers_compile`; `openbrain-triggers-compile.sh` es solo la CLI.
`--force` ignora la comprobación; `--check` solo informa (rc 1 = desfasado o
ausente) sin escribir nada — es lo que usa `openbrain install --check`.

## Claves de frontmatter

```yaml
triggers:
  cwd:
    - "<glob>"        # directorio de trabajo al arrancar la sesión
  files:
    - "<patrón>"       # presencia a nivel 1 del cwd AL ARRANCAR + lectura
  watch:
    - "<patrón>"       # SOLO lectura (doctrine-watch); nunca presencia
  branch:
    - "<glob>"         # rama git activa
  env:
    - "<VARIABLE>"      # variable de entorno definida y no vacía
  mcp:
    - "<glob>"         # nombre de tool MCP invocado (mcp__servidor__*)
  manual: "/doctrine <bloque>"   # documentación, no genera regla
```

## `files:` frente a `watch:`

Los dos pasan por el mismo matcher de una pasada (`triggers_active` en
`scripts/lib/triggers.sh`, modo `start` desde `session-doctrine.sh` y modo
`watch` desde `doctrine-watch.sh`), pero se consultan desde sitios distintos:

- **`files:`** — el hook `SessionStart` (`session-doctrine.sh`) comprueba si
  algún patrón existe a nivel 1 del cwd **al arrancar la sesión**, y el hook
  `PreToolUse` (`doctrine-watch.sh`) lo comprueba también cada vez que se lee
  ese fichero (`Read`; una edición con `Write`/`Edit` sin lectura previa no
  dispara: el matching de `file`/`watch` solo mira `Read`, aunque el hook
  está registrado en `PreToolUse` para `Bash|Read|mcp__.*`). Es la kind correcta para un marcador de proyecto cuya
  sola presencia ya implica el contexto (p.ej. `.remember/now.md`: si existe,
  el proyecto usa el pipeline de memoria en capas). Cada patrón se evalúa
  solo contra su propio glob bajo el cwd: un fichero que casa el patrón de
  otro bloque no activa este.
- **`watch:`** — SOLO cuenta en `doctrine-watch.sh` (lectura del fichero con
  `Read`; nunca por `Write`/`Edit`). Nunca activa el bloque por el mero hecho de que el fichero exista
  en el cwd al arrancar. Es la kind correcta para ficheros de configuración
  genéricos (`.mcp.json`, `settings.json`, `settings.local.json`) que
  aparecen en casi cualquier proyecto del workspace: su presencia no dice
  nada por sí sola, pero tocarlos sí es una señal de que se está
  administrando el propio entorno.

## Traducción glob → patrón de `case`

Los valores del frontmatter son globs de fichero pensados para lectura
humana (`**/foo/**`); el matching en runtime usa `case ... in $pat)` de bash
(shell globbing, no regex), así que `triggers_active` traduce antes de
comparar:

- `**/` → `*/` (cualquier profundidad de directorios intermedios pasa a un
  único `*` de shell-glob, que en `case` ya casa "cero o más segmentos").
- `**` interior (no seguido de `/`) → `*` (colapsa a un comodín normal).
- Sufijo `/**` al final del glob → dos patrones: el propio directorio (`X`,
  sin el sufijo) y `X/*` (cualquier cosa dentro). Así `**/alpha-zone/**`
  produce, tras el primer paso, `*/alpha-zone/*`, y activa tanto
  `.../alpha-zone` como `.../alpha-zone/lo-que-sea`.
- Un prefijo `~/` en el glob se expande a `$HOME/` **en el momento del
  match**, no al compilar — el conf es portable entre hosts con `$HOME`
  distinto.

Ejemplos (bloque `alpha`, `cwd: "**/alpha-zone/**"`):

| cwd real | ¿casa? |
|---|---|
| `/a/b/alpha-zone` | sí |
| `/a/b/alpha-zone/deep/er` | sí |
| `/a/b/otra-cosa` | no |

Con `cwd: "~/alpha-home/**"` y `$HOME=/Users/x`: casa `/Users/x/alpha-home/sub`.

## Patrones de fichero (`file`/`watch`)

- **Sin `/`** (p.ej. `*.eml`, `alpha.yaml`) — casan contra el **basename**
  del path que reciba el hook, sea cual sea el directorio.
- **Con `/`** (p.ej. `.remember/now.md`, `**/hooks/*.sh`) — casan contra la
  **ruta completa**, tal cual la pasa el llamador (absoluta desde
  `doctrine-watch`, o `$CWD/patrón` expandido desde `session-doctrine`), o
  anclados por la derecha con un `*/` implícito delante (`*/patrón`). Esto
  es lo que corrige el bug de paridad descrito abajo: antes del fix, un
  patrón con `/` se comparaba solo contra el basename y nunca casaba.
- En modo `watch` (solo `doctrine-watch.sh`), un patrón con `/` también
  traduce `**` antes de comparar, con dos globs en alternancia: `**/` → `*/`
  (una o más carpetas) y `**/` → nada (cero carpetas). Así `src/**/*.rs`
  activa tanto `/proj/src/x.rs` como `/proj/src/a/b/x.rs`, y `**/README.md`
  sigue exigiendo un separador delante (no casa `NOTREADME.md`). Como el `*`
  de `case` cruza `/`, `src/*.rs` también casa a cualquier profundidad. El
  modo `start` (presencia en `files:`) traduce `**` de otra forma: primero
  prueba un glob normal de nivel cero (el `**/` quitado del patrón) contra
  `$cwd`, y si no hay match paga un `find "$cwd" -path` con el patrón
  colapsado a `*` para casar a cualquier profundidad (se queda con el
  primer resultado). El `find` solo corre cuando el patrón lleva `**`; en un
  árbol grande sin match el coste de `SessionStart` es un recorrido
  completo, así que un glob llano (`hooks/*.sh`) es preferible cuando la
  profundidad ya se conoce.

## Cómo `--check` detecta desfase

`openbrain install --check` (y `openbrain triggers --check`) llaman a
`openbrain-triggers-compile.sh --check`, que evalúa `triggers_stale`: compara el
mtime del conf contra el de cada `*.md` (nunca el del directorio, que solo
cuenta para recompilar): si el conf no existe o hay al menos un bloque más
nuevo, sale con rc 1 y el instalador lo reporta como
`[FALTA] triggers.conf desfasado`. No escribe nada — el efecto secundario
(recompilar) solo ocurre con `--apply`/`--force`.

## Resultado de la paridad (2026-09-03)

Comparación estática y solo lectura entre la tabla de triggers hardcodeada
del hook antiguo y los bloques reales de doctrina del host, compilados con
este plugin: **9 bloques → 79 reglas** (31 cwd, 33 file, 5 branch, 4 env, 6
mcp), sondeados sobre **23 cwd** representativos.

Se encontró y corrigió un bug del plugin (no del frontmatter): el matching
de ficheros comparaba siempre contra el basename, así que un patrón con
directorio (p.ej. `.remember/now.md`) nunca casaba aunque el fichero
existiera. Corregido pasando a comparar por ruta completa (o anclada por la
derecha) cuando el patrón contiene `/`. Con el fix, la paridad es total
salvo un caso de diseño: un bloque que en la tabla vieja solo se activaba al
*tocar* ciertos ficheros de configuración se activaba en el plugin también
por su mera *presencia* en el cwd al arrancar, porque esos patrones vivían
bajo `files:`. Se resuelve moviéndolos a la kind `watch:` — ver la sección
anterior — sin tocar el resto del bloque.
