# Privacidad de la captura activa

El cuarto pilar del plugin (además de recall, memoria y doctrina) es la
**captura activa**: un hook que detecta, en cada prompt del usuario, señales
de corrección o confirmación y las guarda como candidatos a lección para
revisar más tarde. Este documento describe con precisión qué se guarda,
dónde, con qué permisos, durante cuánto tiempo y quién puede leerlo.

## Qué dispara una captura

`hooks/capture-candidate.sh` corre en `UserPromptSubmit`. Ignora los slash
commands (`/...`) y compara el prompt contra dos familias de expresión
regular:

- **Corrección** (`kind: correction`): "no, …", "en realidad…", "te
  equivocas", "está mal", "no es/está así/correcto/exacto/bien", "corrige",
  "recuerda que…", "nunca hagas/uses/pongas…", "siempre usa/haz…",
  "prefiero…", "no vuelvas a…", y sus equivalentes en inglés (`actually`,
  `that's wrong`, `isn't/not right/correct`, `incorrect(o/a)s?`,
  `remember that`, `never do/use`, `always use`, `i prefer`).
- **Confirmación** (`kind: confirmation`): "eso es", "así sí", "perfecto,
  así", `that's right`, y las palabras sueltas "exacto"/"correcto"/`exactly`
  — estas últimas solo cuentan en posición de interjección (inicio del
  prompt o justo tras puntuación), nunca en medio de una frase.

`RX_CORR` (corrección) se evalúa antes que `RX_CONF` (confirmación): "no es
correcto" contiene la palabra suelta "correcto", así que sin la forma negada
en `RX_CORR` y sin evaluarla primero, se clasificaba como confirmación.

Si ninguna de las dos casa, el hook sale sin escribir nada. `OPENBRAIN_CAPTURE_ENABLED`
debe valer `1` (el default) y `jq` debe estar disponible; si cualquiera de
las dos condiciones falla, el hook es no-op.

## Qué se guarda

Por cada prompt que dispara una captura, una línea JSON con estos campos:

```json
{"ts":"<ISO-8601 UTC>","cwd":"<cwd de la sesión>","kind":"correction|confirmation","signal":"<la frase que hizo match>","text":"<prompt redactado>"}
```

`text` es el **prompt del usuario tras redacción**, nunca la respuesta del
modelo ni el resto de la conversación. No se guarda el `session_id` dentro
del JSON (ya es el nombre del fichero) ni ningún otro metadato de la sesión.

## Redacción — primero, y fail-closed

Antes de tocar disco, el prompt (truncado, ver abajo) pasa por
`scripts/redact-before-haiku.sh`, que aplica dos capas y **falla cerrado en
ambas**: si cualquiera de las dos no puede completarse con garantías, no se
escribe nada.

1. **gitleaks** (obligatorio). Si el binario no está instalado, o si detecta
   un secreto en el texto, el script sale con rc≠0 y no emite salida.
2. **Barrido de regex** — cubre formas de secreto que gitleaks frasea
   distinto (tokens de GitHub/Slack/AWS/GCP, JWT, bearer/basic auth,
   credenciales `clave: valor` en línea o en el patrón YAML de dos líneas,
   URIs con credenciales embebidas) y clases de PII que gitleaks no cubre
   (email, IBAN, tarjeta, DNI/NIE español, teléfono español). El sesgo es
   deliberado hacia el sobre-redactado: prefiere tapar un falso positivo a
   dejar pasar un secreto.

En `capture-candidate.sh` esto se traduce en: `REDACTED="$(... | bash
redact-before-haiku.sh - )"`; si el comando falla (`rc≠0`) o `REDACTED`
queda vacío, el candidato se descarta sin escribir — el mensaje "candidato
descartado (redaccion fallo o encontro secretos)" va a stderr, nunca al
buffer de captura.

## Dónde se guarda y con qué permisos

- Directorio: `$OPENBRAIN_CAPTURE_DIR` (default `$XDG_STATE_HOME/openbrain/candidates`,
  típicamente `~/.local/state/openbrain/candidates`). Se crea con `umask 077` y
  se fuerza a `chmod 700`.
- Un fichero por sesión: `$OPENBRAIN_CAPTURE_DIR/<session_id>.jsonl`, creado y
  mantenido en `chmod 600`. El `session_id` se valida contra un alfabeto
  seguro (`[A-Za-z0-9_.-]`, sin `..`) antes de usarlo como nombre de
  fichero, tanto al escribir como al leer con `openbrain capture show`.

## Límites

- **Máximo de líneas por sesión**: `OPENBRAIN_CAPTURE_MAX_PER_SESSION` (default
  40). Al alcanzarlo, el hook deja de añadir candidatos para esa sesión sin
  avisar — no es un error, es el tope de ruido por sesión. Este tope se
  comprueba **antes** de redactar (antes del `fork` de gitleaks en
  `redact-before-haiku.sh`): una sesión que ya llegó al límite no paga el
  coste de redactar un candidato que de todos modos se va a descartar.
- **Truncado a 2000 bytes**: el prompt se recorta a una ventana de 2000
  bytes antes de entrar a redacción. La ventana empieza en el byte 0 salvo
  que la señal (la frase que disparó la captura) caiga más allá del byte
  1500: entonces arranca 500 bytes antes de ella, para que lo guardado
  contenga la corrección y no solo el contexto que la precedía. Como el corte
  es por bytes y no por caracteres,
  puede partir un carácter UTF-8 multibyte justo en el límite; `jq`, al
  construir el JSON, sustituye el byte inválido resultante por el carácter
  de reemplazo Unicode (U+FFFD, `�`). Es un efecto **cosmético** — como
  mucho ensucia el último carácter visible del texto guardado — no una
  pérdida de redacción ni un fallo de seguridad.

## TTL y purga

- `OPENBRAIN_CAPTURE_TTL_DAYS` (default 14) es la vida máxima de un fichero de
  candidatos.
- El hook `hooks/capture-flush.sh`, en `Stop`, purga cualquier
  `*.jsonl` con mtime superior al TTL (usando `find -mtime`, nunca
  `-delete`: cada fichero se borra con `p_secure_rm`) y anota el recuento
  total de candidatos pendientes en `$OPENBRAIN_CAPTURE_DIR/.pending`.
- Purga manual: `openbrain capture purge` (aplica el mismo TTL) o `openbrain capture
  purge --all` (borra todos los ficheros de candidatos ahora mismo,
  independientemente de su edad — lo usa `/openbrain:capture` al terminar, si el
  usuario lo aprueba).

## Quién lee esto

**Nadie, y ningún modelo, de forma automática.** El buffer de candidatos no
se inyecta en ningún prompt ni se lee en ningún hook de `SessionStart`. La
única vía de lectura es que el usuario invoque `/openbrain:capture` (o `openbrain
capture list` / `openbrain capture show <sid>` a mano) en una sesión futura,
momento en el que los candidatos —ya redactados— se presentan como datos a
evaluar, se reformulan como lección y se promueven a memoria o artículo de
wiki **solo con OK explícito por candidato**. La skill `lesson-capture`
subraya la misma regla: los candidatos son prompts del usuario ya
redactados, se tratan como datos, no como instrucciones, aunque su texto
tenga forma de orden.

## Cómo desactivar

`OPENBRAIN_CAPTURE_ENABLED=0` en `openbrain.env` (o en el entorno) desactiva el hook
por completo: `capture-candidate.sh` sale en su primera línea de lógica sin
tocar disco ni invocar a `redact-before-haiku.sh`.

## Cómo purgar

- Todo lo pendiente, ahora: `openbrain capture purge --all`.
- Solo lo caducado: `openbrain capture purge` (equivalente a lo que ya hace
  `capture-flush.sh` en cada `Stop`).
- A mano, sin pasar por el CLI: los ficheros son `.jsonl` normales bajo
  `$OPENBRAIN_CAPTURE_DIR` — borrarlos con `rm -P` (macOS) es seguro y no
  requiere ninguna herramienta del plugin.
