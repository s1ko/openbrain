#!/usr/bin/env bash

[ -n "${_OPENBRAIN_RENDER_LOADED:-}" ] && return 0
_OPENBRAIN_RENDER_LOADED=1

render_template() {
    local tpl="$1" vars="$2"
    [ -r "$tpl" ] && [ -r "$vars" ] || { echo "render_template: falta plantilla o vars" >&2; return 1; }
    python3 - "$tpl" "$vars" <<'PY'
import json
import re
import sys

tpl_path, vars_path = sys.argv[1], sys.argv[2]
with open(tpl_path, encoding="utf-8") as f:
    tpl = f.read()
with open(vars_path, encoding="utf-8") as f:
    vars_ = json.load(f)

leftover = set()

def sub(m):
    k = m.group(1)
    if k in vars_:
        v = vars_[k]
        return "" if v is None else str(v)
    leftover.add(k)
    return m.group(0)

tpl = re.sub(r"\{\{([A-Za-z0-9_]+)\}\}", sub, tpl)

if leftover:
    leftover = sorted(leftover)
    sys.stderr.write(
        "render_template: placeholders sin valor en vars.json: "
        + ", ".join(leftover) + "\n"
    )
    sys.exit(1)

sys.stdout.write(tpl)
PY
}
