---
description: Medir recall del cerebro (BM25 y/o híbrido) y anexar a metrics.log.
argument-hint: "[--hybrid] [--verbose]"
allowed-tools: Bash(openbrain:*), Bash(*/bin/openbrain:*)
---

Ejecuta `openbrain eval $ARGUMENTS` (o `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" eval $ARGUMENTS` si `openbrain` no está en PATH). Muestra la línea registrada y, si aparece un aviso de frescura del índice (`index-freshness: aviso —`), dilo antes que nada: una medida sobre un índice desfasado no vale. Con `--verbose`, `openbrain eval --verbose` (o `--hybrid --verbose`) imprime además cada consulta fallada (`MISS <query>`); enséñaselas al usuario si algo salió peor de lo esperado. Recuerda al comparar con líneas anteriores de `metrics.log` que **solo son comparables las de igual `n`** (el golden set se ha reconstruido varias veces).
