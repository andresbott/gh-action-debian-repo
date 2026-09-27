#!/usr/bin/env python3
"""Print one composite-action step the way the runner would execute it.

  action-step.py <action.yml> <step-id|step-name> [input=value ...]

Writes the step's env (NUL-separated KEY=VALUE, `${{ inputs.x }}` resolved
against the given inputs, else the declared defaults) to fd 3 and its `run`
script to stdout. An input that is not declared, or an `inputs.x` reference
to an undeclared input, is an error: that is the typo this helper catches.
"""
import os, re, sys
import yaml

path, which, *pairs = sys.argv[1:]
action = yaml.safe_load(open(path))
declared = action.get("inputs", {})
given = dict(p.split("=", 1) for p in pairs)
for k in given:
    if k not in declared:
        sys.exit(f"{path}: input '{k}' is not declared")
values = {k: str(v.get("default", "")) for k, v in declared.items()}
values.update(given)

def resolve(s):
    def one(m):
        expr = m.group(1).strip()
        ref = re.fullmatch(r"inputs\.([A-Za-z0-9_-]+)", expr)
        if not ref:
            sys.exit(f"{path}: unsupported expression '{expr}'")
        if ref.group(1) not in declared:
            sys.exit(f"{path}: references undeclared input '{ref.group(1)}'")
        return values[ref.group(1)]
    return re.sub(r"\$\{\{(.*?)\}\}", one, str(s))

steps = action["runs"]["steps"]
step = next((s for s in steps if which in (s.get("id"), s.get("name"))), None)
if step is None:
    sys.exit(f"{path}: no step '{which}'")
with os.fdopen(3, "w") as env:
    for k, v in (step.get("env") or {}).items():
        env.write(f"{k}={resolve(v)}\0")
sys.stdout.write(step["run"])
