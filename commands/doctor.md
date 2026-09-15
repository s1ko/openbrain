---
description: Salud del cerebro (qmd), la memoria (HMAC/lint/staleness), la doctrina (triggers/reviews), la captura y el bucle de aprendizaje (journal/consolidación/eval). Solo lectura.
allowed-tools: Bash(openbrain:*), Bash(*/bin/openbrain:*)
---

Ejecuta el chequeo de salud y preséntalo tal cual, sin resumir ni omitir líneas `[WARN]`/`[FAIL]`:

```
openbrain doctor
```

Si `openbrain` no está en PATH usa `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" doctor`.

Después, para cada `[WARN]`/`[FAIL]`, indica en una línea el comando que lo arregla (viene entre paréntesis en el propio mensaje cuando existe). No ejecutes ninguna corrección: `doctor` es solo lectura y las correcciones que escriben en memoria o doctrina requieren OK explícito del usuario.
