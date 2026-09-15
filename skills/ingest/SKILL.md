---
name: ingest
description: Use when creating or updating wiki articles in the openbrain, ingesting a new source into raw/, or when a recall reveals a gap worth writing down. Enforces the raw → wiki → INDEX → log discipline and the no-secrets invariant.
---

# Autoría en el cerebro (patrón LLM-wiki)

Tres capas, una dirección: `raw/` (fuentes inmutables) → `wiki/` (artículos, uno por concepto) → `INDEX.md` (mapa) y `log.md` (bitácora append-only).

## Al ingerir una fuente

1. Lee `INDEX.md` completo: qué artículos existen y qué cubren.
2. Lee la fuente en `raw/`. **No la edites nunca.** Si está mal, se anota la discrepancia en el artículo.
3. Identifica conceptos: uno por artículo. Nombre de fichero = slug en minúsculas con guiones.
4. Crea desde `templates/wiki-article.md`: frontmatter (`title`, `type`, `created`), cuerpo con secciones, `## Sources` con la ruta en `raw/`. Enlaza con `[[slug]]` a lo relacionado **y añade el enlace de vuelta** en el artículo destino.
5. `INDEX.md`: una línea por artículo nuevo — `- [Título](slug.md) - resumen de una frase`.
6. `log.md`: entrada fechada con qué se ingirió, artículos creados/actualizados, decisiones.
7. `qmd update` (y `qmd embed` si hay embeddings) para que el recall lo vea.

## Invariantes

- **Cero secretos, PII, datos de cliente, hostnames, rutas de expediente** en `wiki/`. Se escribe el método, no el caso. Antes de escribir, pregúntate si la línea sería publicable.
- `raw/` es inmutable: nunca se edita ni se borra desde una sesión. No se indexa — el recall va scoped a `wiki/`.
- Un artículo que contradice otro se resuelve en el texto (fecha y porqué), no borrando el viejo en silencio.
- Pases largos (lint de todo el wiki, ingest de decenas de ficheros): delega en el agente `librarian`.
