# Runbook — operación

> **Para instalación de cero**, ver [`../INSTALL.md`](../INSTALL.md).
> Este documento cubre operación: estado, hallazgos, verificación
> periódica, restauración.

## Revisión 9 (2026-09-04) — qué mirar tras actualizar a 0.2.0

Cambios y motivos en [`../CHANGELOG.md`](../CHANGELOG.md). Operativamente:

- `openbrain doctor` tiene sección **Aprendizaje**. Un `[WARN] aprendizaje: N
  sesión(es) con doctrina activa y ningún <bloque>.jsonl` significa que el
  hook `Stop` no está escribiendo: revisar que `hooks.json` esté cableado.
- El journal de doctrina vive en `$OPENBRAIN_DOCTRINE_DIR/_journal/`:
  `_sessions.jsonl` (sesiones, podado a 1000 líneas) y `<bloque>.jsonl` (a
  2500). El `audit.log` del host ya no es requisito.
- Consolidación serializada: `doctrine-lazy-check.sh` no lanza otra tanda
  mientras exista `$XDG_STATE_HOME/openbrain/doctrine/consolidate.lock`, y
  `doctrine-consolidate.sh` omite un bloque cuyo `consolidate.<bloque>.lock`
  esté tomado (un `--run` manual y el lazy trigger no pisan el mismo review;
  bloques distintos sí consolidan en paralelo). Un lock caduca cuando su
  `pid` ya no vive (o a la hora si no tiene `pid`, y a las seis en todo
  caso); para forzar, `rm -r` sobre el directorio del lock.
- Salida del curator en `~/.claude/logs/doctrine-consolidate-<bloque>-*.log`;
  los de más de 30 días se borran cuando `doctrine-lazy-check.sh` lanza una
  tanda nueva.
- Las firmas HMAC existentes siguen siendo válidas: el digest no cambia.
- `verify-memory.sh` ya no crea symlinks de la memoria global en cada
  proyecto. Los que existan no estorban (`sign`/`verify`/`lint` los saltan);
  para retirarlos, borrarlos a mano tras comprobar que `_global/` está firmado.

## Revisión 11 (2026-09-09) — qué mirar tras actualizar a 0.6.0

Cambios y motivos en [`../CHANGELOG.md`](../CHANGELOG.md). Operativamente:

- Al cerrar cada sesión, el hook `Stop` firma las memorias que se editaron
  durante ella y quedaron sin firma válida — típicamente las escritas desde
  `Bash`, que `PostToolUse` no ve. Lo que no firme y por qué queda en
  `$XDG_STATE_HOME/openbrain/sign-memory.log`, una línea JSON por decisión.
  Un aviso en stderr al cerrar («firmadas N; M fuera de banda…») señala que
  algo se quedó fuera; el detalle está en ese log.
- Una memoria alterada **antes** de que empezara la sesión no se firma:
  sale como `out_of_band` y `openbrain memory verify` la sigue dando en `FAIL`.
  Es deliberado — es la diferencia entre firmar tu propia edición y sellar
  algo que ya estaba mal. Se resuelve mirándola y firmando a mano.
- Tras rotar la clave HMAC verás `refused` en ese log hasta que corras
  `openbrain memory sign`: el árbol entero falla y el hook se niega a tocarlo.
  No subas `OPENBRAIN_SIGN_ON_STOP_MAX` para esquivarlo.
- Para desactivarlo entero: `OPENBRAIN_SIGN_ON_STOP=0` en `openbrain.env`.
- `openbrain memory sign <fichero>` ahora exige que el fichero esté dentro de
  `OPENBRAIN_MEMORY_ROOT/<slug>/memory/`. Un `.md` fuera de ahí sale con rc 2 en
  vez de firmarse.

## Revisión 10 (2026-09-08) — qué mirar tras actualizar a 0.5.0

Cambios y motivos en [`../CHANGELOG.md`](../CHANGELOG.md). Operativamente:

- El journal por bloque (`$OPENBRAIN_DOCTRINE_DIR/_journal/<bloque>.jsonl`) ya
  no lee `$HOME/.claude/audit.log` en ningún punto (ni el hook `Stop` ni
  `doctrine-consolidate.sh`): las métricas de edición salen del
  `transcript_path` que el harness pasa a `Stop`, y la evidencia de cuándo
  se activó cada bloque sale de `_sessions.jsonl`. Una instalación sin
  `audit.log` — la norma — no pierde nada de esto.
- El journal pasa a una línea por (sesión, bloque), no una por turno: si ves
  un `<bloque>.jsonl` que deja de crecer en cada `Stop` de una sesión larga,
  es lo esperado — la línea de esa sesión se actualiza in situ. El evento se
  llama ahora `session`; las líneas antiguas `session_close` se siguen
  leyendo bien (todo se filtra por `ts`/`sid`, nunca por `event`).
- Un review de doctrina sin cambios que proponer (`## Sin cambios
  propuestos`) ya no queda PENDIENTE para siempre: se marca `.applied` en
  el momento de escribirse. Un review de este tipo generado antes de 0.5.0
  sigue PENDIENTE hasta que lo cierres a mano con
  `openbrain review --mark <bloque> <fecha>`.
- `openbrain doctor` gana avisos que antes no existían: frescura del índice de
  `qmd` frente a la wiki (sin necesitar golden set), tamaño de
  `_global/memory`, kinds de trigger desconocidas o que no compilan
  ninguna regla. Ninguno bloquea nada — apuntan a `openbrain memory
  index`/`qmd update`/revisar el frontmatter del bloque en cuestión.
- Formato de `_journal/<bloque>.notes.md` y rotación de la clave HMAC,
  documentados por primera vez más abajo en este runbook.

## Notas de revisión de doctrina (`_journal/<bloque>.notes.md`)

Formato que `doctrine-lazy-check.sh` y `doctrine-consolidate.sh` esperan al
leer las notas manuales de un bloque:

- Cada nota empieza con una cabecera de la forma exacta
  `## 2026-09-08T17:00:00Z` — UTC, ISO-8601, nada más en la línea. Cualquier
  otra línea que empiece por `## ` (un título humano, una sección) es
  cuerpo, no abre una nota nueva.
- El cuerpo va debajo, hasta la siguiente cabecera con ese formato exacto o
  el final del fichero.
- Una línea `> APLICADA` en cualquier parte del cuerpo marca la nota como ya
  gestionada: deja de contar como actividad nueva para el lazy trigger y
  para `doctrine-consolidate.sh --days`.
- Una nota sin cuerpo (solo la cabecera, sin nada debajo) tampoco cuenta
  como actividad nueva.

## Rotación de la clave HMAC

No hay herramienta de rotación. El procedimiento manual:

1. Sustituir `~/.config/claude/memory.hmac` (`OPENBRAIN_HMAC_KEY`) por una
   clave nueva.
2. Re-firmar el árbol vivo: `openbrain memory sign`.
3. Tomar un backup nuevo cuanto antes, o verificar uno reciente:
   `openbrain memory backup` y luego un `restore ... test`.

Entre el paso 1 y el 2 el firmador de Stop ve el árbol entero en `FAIL` y se
niega a tocarlo (`refused` en `$XDG_STATE_HOME/openbrain/sign-memory.log`). Es lo
esperado: no subas `OPENBRAIN_SIGN_ON_STOP_MAX` para «arreglarlo».

Cualquier backup cifrado antes de la rotación falla la verificación HMAC de
`restore-memory.sh` después — igual que si hubiera sido manipulado, porque
su sidecar sigue firmado con la clave anterior y `restore` verifica contra
la clave que hay en disco ahora. Guarda la clave retirada en depósito
(fuera del repo, idealmente fuera de este host) si quieres poder restaurar
backups anteriores a la rotación. `RESTORE_ALLOW_UNVERIFIED=1` es el escape
hatch para ese caso: retira del staging los ficheros que no verifican y
restaura el resto, pero renuncia a la garantía de integridad — no es una
forma recomendada de operar, solo el último recurso.

## Endurecimiento fail-closed de la refirma (revisión 8, 2026-08-13)

- `update-memory-index.sh`, `dedupe-global-memory-index.sh` y
  `mark-reviewed.sh` ahora **salen con código ≠ 0** cuando reescriben un
  índice/memoria pero no pueden refirmar su `.hmac` (clave ausente, permisos
  flojos, o firma vacía). Antes solo imprimían un `warn` y terminaban en
  verde, dejando una firma stale sin señal accionable. La firma previa se
  respeta siempre (nunca se trunca el sidecar antes de tener un digest bueno)
  y ahora se escribe de forma atómica (tmp + `mv`).
- La usabilidad de la clave se centraliza en `hmac_key_ok()` (`lib/common.sh`):
  exige fichero regular, legible y modo `600`/`400` — mismo contrato que ya
  aplicaba `verify-memory-hmac.sh`.
- `mark-reviewed.sh` confina la mutación al árbol bajo `OPENBRAIN_MEMORY_ROOT`
  (`~/.claude/projects` por defecto): un fichero que resuelva fuera se rechaza
  con `exit 2`. Preserva además el modo del fichero al reescribir.
- `restore-memory.sh` verifica los sidecars HMAC del backup **antes** de tocar
  el destino y se niega a sobrescribir un árbol con `.md` ya presentes salvo
  `RESTORE_FORCE=1`.
- Códigos de salida reales de `verify-memory-hmac.sh`: `exit 2` en cinco
  condiciones de entorno (clave ausente, clave que es symlink, permisos
  flojos de la clave, clave ilegible pese al modo, o ningún `memory/` bajo la
  raíz); `exit 1` en
  `FAIL`/`MISS`/`ORPHAN` de verificación; `exit 0` solo con todo `OK`.

## Verificación periódica

Una corrida semanal recomendada, toda desde el CLI del plugin:

```bash
openbrain doctor
openbrain memory lint     # rc 2 = fallo de seguridad (bloquea la firma); rc 1 = estilo (firma permitida)
openbrain memory verify
openbrain memory metrics | sort -k4,4 -n     # ordena por edad
openbrain memory index                        # anota fecha y stale en cada MEMORY.md; pide confirmación
systemctl --user list-timers openbrain-memory-backup.timer   # Linux
launchctl print "gui/$(id -u)/com.openbrain.memory-backup"   # macOS

# smoke test del último backup (no toca nada); OPENBRAIN_BACKUP_DIR por defecto:
latest="$(ls -t ~/.claude/backups/memory/memory-*.tar.gz.* | head -1)"
openbrain memory restore "$latest" "$(mktemp -d)" test
```

Si algo falla, investigar antes de añadir más memorias. `openbrain doctor` resume
los cinco pilares en una pasada; la mayoría de los `[WARN]` llevan entre
paréntesis el comando que los arregla.

## Restaurar un backup

```bash
openbrain memory restore ~/.claude/backups/memory/memory-<TS>.tar.gz.gpg "$(mktemp -d)" extract
```

`extract` verifica los sidecars HMAC del archivo antes de tocar el destino y
se niega a sobrescribir un árbol con `.md` ya presentes salvo `RESTORE_FORCE=1`.
Restaurar in-situ sobre `~/.claude/projects` es una acción manual: copiar lo
verificado proyecto a proyecto y cerrar con `openbrain memory verify`.
