---
name: recall
description: Use BEFORE assuming methodology, doctrine, tooling conventions or technical background you don't already have in this session — and before re-deriving something that has probably been written down. Also when the user mentions "el cerebro", "la wiki" or "qmd".
---

# Consultar el cerebro antes de asumir

El cerebro es un wiki interconectado indexado con qmd. Compila conocimiento una vez para no re-derivarlo por consulta. Si estás a punto de explicar un método, una convención o un procedimiento "de memoria", primero mira si ya está escrito.

## Cómo consultar

1. `openbrain recall <términos>` (o `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" recall <términos>` si `openbrain` no está en PATH) — BM25, rápido. Si la consulta es una pregunta en lenguaje natural y los resultados no encajan, `openbrain recall --hybrid <pregunta>`.
2. Lee los 1–3 artículos con mejor score: `qmd get "<file>"`. Sigue los `[[wikilinks]]` que citen — la información suele estar a un salto.
3. Cita el artículo por nombre de fichero al usar lo que dice.

## Reglas

- **Nunca** `qmd search`/`qmd query` a mano sin `-c`: `openbrain recall` fuerza el scope. En este host hay colecciones que no deben mezclarse.
- Prefiere el cerebro a `grep` sobre el repo cuando la pregunta es "cómo se hace X aquí" o "qué doctrina aplica"; prefiere `grep` cuando es "dónde está el símbolo Y".
- Si el cerebro no cubre el tema, **dilo**. No rellenes con conocimiento general presentándolo como si viniera del cerebro. Una laguna detectada es una candidata a ingest (`/openbrain:ingest`).
