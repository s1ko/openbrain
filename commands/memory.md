---
description: Operaciones de memoria — lint verify sign index metrics promote mark-reviewed backup restore dedupe search redact.
argument-hint: "<op> [args]"
allowed-tools: Bash(openbrain:*), Bash(*/bin/openbrain:*)
---

Ejecuta `openbrain memory $ARGUMENTS` (o `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" memory $ARGUMENTS` si `openbrain` no está en PATH). Ops de lectura (`lint verify metrics search redact`) van directas. `dedupe` sin `--apply` es dry-run (solo imprime). Ops que **escriben** memoria curada (`sign index promote mark-reviewed` y `dedupe --apply`) piden confirmación en terminal: **no añadas `--yes` por tu cuenta**; pregúntale al usuario primero y explica qué va a cambiar. `backup` y `restore` no piden confirmación: `backup` requiere `OPENBRAIN_BACKUP_AGE` o `OPENBRAIN_BACKUP_GPG`; `restore <archivo> <destino> [extract|test]` — empieza siempre por `test`, y `extract` solo sobrescribe un destino con `.md` si el usuario exporta `RESTORE_FORCE=1` (no lo pongas tú).
