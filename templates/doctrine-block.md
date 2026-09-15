---
name: <bloque>
description: <una línea>
triggers:
  cwd:
    - "**/<carpeta>/**"
  # files: activa el bloque por PRESENCIA (a nivel 1 del cwd, al arrancar la
  # sesión) Y por lectura del fichero. Úsalo para marcadores de proyecto
  # (p.ej. "docker-compose.yml") cuya sola existencia ya implica el contexto.
  files:
    - "*.<ext>"
  # watch: activa el bloque SOLO por lectura (nunca por presencia al
  # arrancar). Úsalo para ficheros de configuración (".mcp.json",
  # "settings*.json") que existen en casi cualquier proyecto y cuya mera
  # presencia no debe disparar el bloque — solo importa cuando se tocan.
  watch:
    - "<fichero-de-config>"
  branch:
    - "<prefijo>/*"
  env:
    - "<VARIABLE>"
  mcp:
    - "mcp__<servidor>__*"
  manual: "/doctrine <bloque>"
version: 1.0
---

# Doctrina: <bloque>

> Activado: <cuándo aplica y qué asume>.

## 1. <Regla>
