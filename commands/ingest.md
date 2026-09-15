---
description: Ingerir una fuente nueva en el cerebro con el método karpathy (raw → artículos → INDEX → log).
argument-hint: "<ruta a la fuente en raw/>"
allowed-tools: Read, Write, Edit, Bash(qmd:*), Bash(openbrain:*), Bash(*/bin/openbrain:*)
---

Vas a incorporar `$ARGUMENTS` al cerebro. La raíz del wiki es `OPENBRAIN_WIKI_ROOT` (mírala con `openbrain doctor` o en `~/.config/claude/openbrain.env`). Sigue la skill `ingest`; en resumen:

1. Lee `INDEX.md` del wiki para saber qué existe.
2. Lee la fuente. `raw/` es inmutable: **jamás la edites**.
3. Para cada concepto nuevo, crea `wiki/<slug>.md` desde `templates/wiki-article.md`; para los existentes, actualiza. Añade `[[wikilinks]]` a artículos relacionados y enlaces de vuelta.
4. Añade una línea por artículo nuevo a `INDEX.md` (`- [Título](fichero.md) - resumen de una frase`).
5. Anota en `log.md` (append-only) qué se ingirió y qué artículos se crearon/tocaron.
6. Reindexa: `qmd update`. Si hay embeddings: `qmd embed`.

Cero secretos, cero PII, cero datos de cliente en `wiki/`. Si la fuente los contiene, se abstraen a método. Si el pase es grande (más de ~8 artículos), delega en el agente `librarian` para no ensuciar este contexto.
