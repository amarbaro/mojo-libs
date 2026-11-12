# Common rules for every mojo-tls lane (read docs/plan.md and docs/api.md first)
- Mojo nightly in ~/Projects/mojo/mojo-tls/.venv/bin/mojo. Load skills: mojo-syntax, mojo-lean, memory-optimization, mojo-nightly-lane-builder (~/Projects/mojo/.claude/skills/).
- Pure Mojo: no C library, no std.python, no FFI except getrandom/syscalls. Python, openssl, curl only as test oracles in tools/ and tests/.
- References in ~/Projects/imports/tls-refs (Mosaad-M-tls MIT: may port with its MIT notice in the file header; nsalerni Apache-2.0: API ideas; corv89 no licence: read only, never copy).
- Constant time on secrets; check every peer length before use; fuzz every parser.
- Fewest lines that pass the gates. Measure: lines (wc/mokei), speed (mojo-bench), numbers in commits.
- Commit on your branch by pathspec with conventional subjects and a why body. No remote, no push.
- Every gate script: set -euo pipefail, prints PASS/FAIL <step>: <reason>, exits non-zero on failure. A mutant that breaks the core must make the gate fail: show it.
- Long runs under `timeout`; builds `timeout 300`. Nothing in /tmp: use .work/.
- End: write .work/report-<lane>.md (what works, gate output, lines, speed, open items, interface changes). Claims only with the command output that proves them.
