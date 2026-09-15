---
name: alpha
description: bloque sintético alpha
triggers:
  cwd:
    - "**/alpha-zone/**"
    - "~/alpha-home/**"
  files:
    - "*.alp"
    - "alpha.yaml"
  branch:
    - "alpha/*"
  env:
    - "ALPHA_CASE_ROOT"
  mcp:
    - "mcp__alpha__*"
  manual: "/doctrine alpha"
version: 1.0
---

# alpha
Contenido sintético.
