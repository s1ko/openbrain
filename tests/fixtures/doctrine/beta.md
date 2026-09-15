---
name: beta
description: bloque sintético beta
triggers:
  cwd:
    # comentario dentro de la lista
    - "**/beta/**"
    - "**/b-*/**"
  files:
    - ".beta-state/now.md"
    - "**/hooks/*.sh"
  watch:
    - ".beta.json"
  env:
    - "2FA_ENABLED"
---

# beta
