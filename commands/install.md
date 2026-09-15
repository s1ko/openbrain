---
description: Verificar la instalación del plugin (deps, openbrain.env, clave HMAC, triggers, symlink, planificador) e imprimir el diff de settings.json.
argument-hint: "[--check|--apply] [--remove-legacy]"
allowed-tools: Bash(openbrain:*), Bash(*/bin/openbrain:*)
---

`openbrain install $ARGUMENTS` (o `"${CLAUDE_PLUGIN_ROOT}/bin/openbrain" install $ARGUMENTS`; sin flag = `--check`). Presenta el informe. Si imprime un diff para `~/.claude/settings.json`, muéstralo íntegro y **no lo apliques**: ese fichero es de controles del usuario y lo edita él. Con `--apply` el instalador crea lo que falta bajo `~/.config/claude`, `~/.local/bin` y el planificador del usuario, y sigue sin tocar `settings.json`. Con `--remove-legacy` (pide confirmación) retira symlinks al repo antiguo y mueve los duplicados nativos a `_retired_<fecha>`.
