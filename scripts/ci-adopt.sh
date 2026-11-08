#!/usr/bin/env bash
# ci-adopt.sh LIB DIR: write DIR/.github/workflows/ci.yml, the caller of the shared lib-ci.yml, for library LIB.
# The template is templates/ci.yml; apt/pre inputs come from ci-setup.tsv. A library missing there gets the bare caller.
set -euo pipefail
lib=${1:?usage: ci-adopt.sh LIB DIR}; dir=${2:?usage: ci-adopt.sh LIB DIR}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$dir/.github/workflows"
python3 -I - "$root" "$lib" > "$dir/.github/workflows/ci.yml" <<'PY'
import sys, json
root, lib = sys.argv[1:3]
out = open(f"{root}/templates/ci.yml").read()
for line in open(f"{root}/ci-setup.tsv"):
    if line.startswith("#") or not line.strip():
        continue
    name, apt, pre = (line.rstrip("\n").split("\t") + ["", ""])[:3]
    if name == lib:
        w = [f"      {k}: {json.dumps(v)}" for k, v in (("apt", apt), ("pre", pre)) if v]
        if w:
            out += "    with:\n" + "\n".join(w) + "\n"
print(out, end="")
PY
