# Instalación

Flujo de instalación del plugin `openbrain` para Claude Code. Cubre desde los
requisitos del sistema hasta la migración de una instalación anterior por
symlinks (el repo predecesor — ver "Historia" en `README.md`) y la
actualización del plugin ya instalado.

## 1. Requisitos

Runtime:

```bash
# macOS
brew install bash jq openssl gitleaks gnupg python3 node qmd
# Debian/Ubuntu
apt install bash jq openssl gitleaks gnupg python3 nodejs
npm i -g @tobilu/qmd
```

`node` debe ser `>=22`. `qmd` es la CLI de recall (`npm i -g @tobilu/qmd`
si no viene por el gestor de paquetes del sistema). `python3` debe ser
`>=3.11`: `refresh-doctrine` importa `tomllib`, y el `python3` del sistema
en macOS (Xcode) es 3.9. `openbrain doctor` y `openbrain install` avisan si el
`python3` del PATH no lo trae.

Desarrollo (para `make test`):

```bash
# macOS
brew install bats-core shellcheck
# Debian/Ubuntu
apt install bats shellcheck
```

## 2. Registrar el plugin

```bash
claude plugin marketplace add <ruta-del-checkout>
claude plugin install openbrain@openbrain
claude plugin list
```

`<ruta-del-checkout>` es el directorio donde clonaste este repo (p.ej.
`~/openbrain`). `claude plugin list` debe mostrar `openbrain` habilitado.

## 3. Instalar lo que vive fuera del repo

```bash
openbrain install --apply
# o, la primera vez, antes de que ~/.local/bin esté en PATH:
"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" install --apply
```

Esto crea `~/.config/claude/openbrain.env` (copiado de
`install/env/openbrain.env.example`), genera la clave HMAC
(`~/.config/claude/memory.hmac`, modo 600) si falta, compila
`triggers.conf` si hay directorio de doctrina, y enlaza `~/.local/bin/openbrain`
al checkout. **Nunca** toca `~/.claude/settings.json`.

Opcional: `install/git/gitignore.global` reúne los patrones que no deben
versionarse en ningún repo del host (`.remember/`, `settings.local.json`,
`audit.log`, credenciales de Claude Code). Para aplicarlos como excludes
globales de git, añade su contenido al fichero que git lee por defecto:

```bash
mkdir -p ~/.config/git && cat install/git/gitignore.global >> ~/.config/git/ignore
```

Después, edita `~/.config/claude/openbrain.env` a tu gusto:

```bash
$EDITOR ~/.config/claude/openbrain.env
```

Al editar `openbrain.env`, **edita la línea existente (p.ej.
`OPENBRAIN_BACKUP_GPG=`), no añadas una nueva al final: el loader respeta la
primera aparición de cada clave** (el entorno tiene precedencia sobre el
fichero, y dentro del fichero, la primera coincidencia gana sobre las
siguientes).

## 4. Colección `qmd`

```bash
qmd collection add "$OPENBRAIN_WIKI_ROOT" --name "$OPENBRAIN_COLLECTION"
qmd update
qmd embed   # opcional — habilita --hybrid (expansión + rerank)
```

## 5. Firma inicial de la memoria

```bash
openbrain memory sign
```

Firma con HMAC toda la memoria existente bajo `OPENBRAIN_MEMORY_ROOT`. A partir
de aquí, el hook `verify-memory` lintea y firma automáticamente cada
`memory/*.md` que edites (solo ese fichero, no su directorio), siempre que
el lint pase. Lo que se escriba fuera de `Write`/`Edit` (una redirección
desde `Bash`, un script) no pasa por ese hook: lo firma `sign-memory` al
cerrar la sesión (Stop), solo si es más nuevo que el arranque de esa sesión
y pasa el lint. Lo que quede sin firmar y el porqué está en
`$XDG_STATE_HOME/openbrain/sign-memory.log`.

## 6. Si venías de la instalación por symlinks

Si tenías el pipeline instalado como symlinks sueltos en
`~/.claude/hooks/` y `~/.claude/scripts/memory/` (la instalación anterior a
este plugin), `openbrain install --check` te habrá avisado del diff pendiente
en `settings.json`. Aplícalo:

```bash
# openbrain install imprime la orden exacta con las rutas de tu host; algo así:
cp ~/.claude/settings.json ~/.claude/settings.json.bak-$(date +%Y%m%d)
jq --argjson names '[...]' 'def base: ...; ...' ~/.claude/settings.json > ~/.claude/settings.json.new
mv ~/.claude/settings.json.new ~/.claude/settings.json
```

Luego retira los symlinks y duplicados nativos que ahora provee el plugin:

```bash
openbrain install --remove-legacy
```

Pide confirmación y solo actúa sobre lo que reconoce como legado del propio
plugin (symlinks cuyo nombre coincide con un hook que ahora migró, o
duplicados nativos de una lista cerrada) — nunca toca hooks propios del
host que no sean parte de esta migración.

## 7. Verificar

Dos piezas opcionales que `openbrain doctor` señala si faltan, pero que no
bloquean una instalación funcional:

- **Golden set de eval** (para medir recall con `openbrain eval`):

  ```bash
  mkdir -p "$(dirname "$OPENBRAIN_EVAL_GOLDEN")"
  cp eval/golden.example.json "$OPENBRAIN_EVAL_GOLDEN"
  ```

  (`OPENBRAIN_EVAL_GOLDEN` sale de `openbrain.env`; default
  `~/knowledge/.eval/golden.json`.) Edita `collection` y sustituye las
  consultas de ejemplo por las tuyas, luego `openbrain eval`. Sin esto,
  `openbrain doctor` solo dice «eval sin configurar».

- **`refresh.toml`** (para que `refresh-doctrine.sh` mantenga vivo el bloque
  `AUTO-START…AUTO-END` de `~/.claude/CLAUDE.md`):

  ```bash
  cp install/env/refresh.toml.example ~/.claude/refresh.toml
  ```

  El `CLAUDE.md` destino debe llevar ya los marcadores
  `<!-- AUTO-START -->`/`<!-- AUTO-END -->`: la herramienta rellena entre
  ellos, no los crea. Para refrescar además el `CLAUDE.md` local de un repo,
  copia el mismo fichero a `<repo>/.claude/refresh.toml` y añade el repo a
  `OPENBRAIN_REFRESH_ALLOWLIST`. `REFRESH_CLAUDE_MD_BUDGET` (ver README) acota
  cuánto puede tardar en total el conjunto de comandos del manifiesto. Sin
  `refresh.toml`, `openbrain doctor` avisa y el hook es un no-op para el
  `CLAUDE.md` global.

Abre una sesión nueva y ejecuta `/openbrain:doctor`; debe salir en verde (sin
`[WARN]`/`[FAIL]`). `claude plugin list` debe seguir mostrando `openbrain`.

## 8. Backup cifrado (opcional)

Dos backends; si están los dos definidos gana age.

- **age** (recomendado en macOS, no necesita GPG):

  ```bash
  ( umask 077; age-keygen -o ~/.config/claude/memory-backup-key.txt )   # imprime "Public key: age1..."
  ```

  Rellena `OPENBRAIN_BACKUP_AGE=age1...` en `openbrain.env`. `restore` lee la
  identidad de ese fichero (`OPENBRAIN_BACKUP_AGE_IDENTITY` para otra ruta).

- **gpg**:

  ```bash
  gpg --list-secret-keys --keyid-format LONG   # anota la huella completa del recipient
  ```

  Rellena `OPENBRAIN_BACKUP_GPG=<40-hex-fingerprint>` en `openbrain.env`.

Entonces:

```bash
openbrain install --apply     # instala el planificador (launchd en macOS, systemd --user en Linux)
openbrain memory backup
```

Verificación sin tocar nada real:

```bash
latest="$(ls -t "$OPENBRAIN_BACKUP_DIR"/memory-*.tar.gz.gpg | head -1)"
openbrain memory restore "$latest" /tmp/x test
```

Empieza siempre por `test` — solo entonces `extract` a un destino real.

## 9. Variables derivadas (no están en `openbrain.env.example`)

Cuatro variables tienen un default calculado a partir de otras y no
aparecen en el fichero de ejemplo — se sobreescriben poniéndolas en
`openbrain.env` igualmente, o por variable de entorno:

- `OPENBRAIN_TRIGGERS_CONF` (default `$XDG_CACHE_HOME/openbrain/triggers.conf`) —
  caché compilada de triggers de doctrina.
- `OPENBRAIN_CAPTURE_DIR` (default `$XDG_STATE_HOME/openbrain/candidates`) —
  buffer de candidatos de la captura activa.
- `OPENBRAIN_GLOBAL_MEMORY` (default `$OPENBRAIN_MEMORY_ROOT/_global/memory`) —
  capa de memoria global inyectada en toda sesión.
- `OPENBRAIN_REVIEW_SKIP` (default `0`) — si vale `1`, salta la consolidación
  de reviews de doctrina (útil en CI/planificadores no interactivos).

## 10. Desinstalar

```bash
claude plugin disable openbrain@openbrain
```

`openbrain install` nunca deja entradas en `settings.json`, así que no hay
nada que revertir ahí. Para retirar lo que sí queda en el host:

```bash
rm -f ~/.local/bin/openbrain
rm -f ~/.local/bin/refresh-claude-md   # solo si quedó de una instalación anterior: ya no se enlaza
# macOS
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.openbrain.memory-backup.plist
rm -f ~/Library/LaunchAgents/com.openbrain.memory-backup.plist
# Linux
systemctl --user disable --now openbrain-memory-backup.timer
rm -f ~/.config/systemd/user/openbrain-memory-backup.{service,timer}
```

`~/.config/claude/openbrain.env`, la clave HMAC y la memoria/wiki/doctrina en
sí **no** se borran — son datos del usuario, no del plugin.

## 11. Actualizar el plugin instalado

Claude Code no ejecuta el checkout: copia el plugin a
`~/.claude/plugins/cache/openbrain/openbrain/<versión>/` y carga esa copia. La copia
solo se renueva cuando cambia `version` en `.claude-plugin/plugin.json`: tras
un `git pull` con la misma versión, `claude plugin marketplace update openbrain` y
`claude plugin install openbrain@openbrain` (o `update`) responden «already at the
latest version» y dejan la caché como estaba. Para renovarla sin publicar
versión:

```bash
claude plugin uninstall openbrain@openbrain && claude plugin install openbrain@openbrain
```

Con versión nueva basta `claude plugin update openbrain@openbrain`. Para saber si la
caché va atrás:

```bash
diff -rq hooks ~/.claude/plugins/cache/openbrain/openbrain/*/hooks
```

`~/.local/bin/openbrain` (el symlink que crea `openbrain install --apply`) **siempre**
apunta al checkout y por tanto está actualizado sin este paso — solo la
copia que carga el propio harness de Claude Code para hooks/comandos/skills
necesita la renovación explícita de arriba.

Tras actualizar, en cualquiera de los dos casos:

```bash
openbrain install --check
openbrain doctor
```

`--check` lista lo que la versión nueva ya no crea (por ejemplo el symlink
`~/.local/bin/refresh-claude-md`, retirable con `openbrain install
--remove-legacy`) y `doctor` avisa de variables heredadas que ya no se leen.
Los renombrados y retiradas de cada versión están en la sección «Eliminado»
de `CHANGELOG.md`.
