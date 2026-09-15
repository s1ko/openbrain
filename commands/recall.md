---
description: Buscar en el cerebro de trabajo con scope forzado a la colección configurada. --hybrid para expansión+rerank.
argument-hint: "[--lex|--hybrid] [-n N] [--json] <consulta>"
allowed-tools: Bash(openbrain:*), Bash(*/bin/openbrain:*), Bash(qmd get:*)
---

Busca en el cerebro: `openbrain recall $ARGUMENTS` (o `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" recall $ARGUMENTS`).

- Sin flags es BM25 (rápido, sin modelo). Si los resultados no encajan con la intención, repite con `--hybrid`.
- Lee los 1–3 artículos más relevantes con `qmd get "<file>"` y sigue los `[[wikilinks]]` que citen.
- Responde citando el artículo (nombre de fichero). Si el cerebro no cubre el tema, dilo — no rellenes con conocimiento general como si viniera del cerebro.
- Nunca ejecutes `qmd search`/`qmd query` a mano sin `-c`: el comando `openbrain recall` existe para que el scope no se pueda olvidar.
