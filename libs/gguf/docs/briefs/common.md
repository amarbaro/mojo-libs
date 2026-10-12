# Rules for every mojo-gguf lane (read first)

You own one unit. Work only in your worktree on branch `lane-<unit>`. Do not wait for prompts: read, build, gate,
commit, report. The gate scores you; nothing else does.

## Read before writing code

- Mojo 1.1 syntax: `/home/mario/Brain/Skills/imported/modular/_vendor/modular/mojo-syntax/SKILL.md`
- Compile-error classes and fixes: `/home/mario/Brain/Skills/own/mojo-nightly-lane-builder/SKILL.md`
- The merged U1 reader/writer you build on: `src/gguf/model.mojo`, `src/gguf_rewrite.mojo`, `README.md`.
- Reference implementation, pinned, read-only: `~/Projects/imports/llama.cpp-master` at `1744c6bde`.
  Port ideas, structure and exact semantics; write your own Mojo (no copied comments, no transliteration noise).

## Toolchain

- Compiler `/home/mario/Projects/mojo/mojo-gguf/.venv/bin/mojo` (Mojo 1.1.0); build with `-I src` as your gate does.
- Python is the ORACLE only (gates, generators where your brief says so). The product is Mojo.
- CPU only unless your brief says GPU. No network.

## Hard rules

- `tests/`, `tools/oracle.sh`, `tools/mkoracle.sh`, `tools/gguf-cmp.py`, `docs/PLAN.md` are frozen: editing or
  deleting any of them fails your gate. You may ADD files anywhere.
- Never write under `.work/oracle` or `~/Models`. Scratch goes to `.work/<unit>/`.
- Memory is budget: stream or mmap tensor data, never load a whole model; your gate prints wall + peak RSS.
- Commit each working step: conventional subject + why-body, no Co-Authored-By, no model or tool attribution.
- Same error after three repair attempts: write `.work/<unit>-failure.md` (error, what you tried) and stop.

## Report

`exchange/lane-<unit>-report.md`: the full gate output pasted, final commit sha, files + LOC under `src/`,
wall + RSS lines, what was hard, repair count. Commit it. Last line of your session output: `DONE <sha>` or
`BLOCKED <reason>`.
