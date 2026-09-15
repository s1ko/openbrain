---
description: Reviews de doctrina pendientes; lanzar consolidación de un bloque; marcar un review como aplicado.
argument-hint: "[--run <bloque> | --mark <bloque> <fecha>]"
allowed-tools: Bash(openbrain:*), Bash(*/bin/openbrain:*), Read
---

1. `openbrain review $ARGUMENTS` (o `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" review $ARGUMENTS` si `openbrain` no está en PATH) — lista reviews con estado PENDIENTE/aplicado; con `--run <bloque>` lanza la consolidación (tarda: invoca a `claude -p`; el fichero aparece en `_review/<fecha>/<bloque>.md`); con `--mark <bloque> <fecha>` registra que ese review ya se aplicó.
2. Si hay un review PENDIENTE, léelo y presenta cada propuesta `[ ]` con su evidencia. **No modifiques el bloque de doctrina**: el usuario marca `[x]`/`[-]`, aplica él los cambios a mano en `doctrine/<bloque>.md` y cierra con `openbrain review --mark <bloque> <fecha>`. Tu papel es explicar, contrastar la evidencia y detectar propuestas especulativas.
3. Si el usuario quiere dejar una nota manual para la próxima consolidación en vez de esperar al journal automático, recuérdale el formato exacto de `_journal/<bloque>.notes.md`: cabecera `## <YYYY-MM-DDTHH:MM:SSZ>` (UTC ISO-8601, nada más en la línea) seguida del cuerpo; una línea `> APLICADA` en el cuerpo la marca como ya gestionada (ver `docs/07-runbook.md`).
