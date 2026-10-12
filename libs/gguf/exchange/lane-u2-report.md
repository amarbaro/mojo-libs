# U2 report: table generator (`lane-u2`)

Result: **PASS 7/7**, `tests/u2-gate.sh` exit 0. Code commits `00279d7` (generator + tables), `498d99c` (lookup, dump, checks, README). Report commit: see `git log`.

## Gate output (`tests/u2-gate.sh`, final run)

```
ok   gate-files-untouched
ok   llama-cpp-pinned
ok   generator-runs
ok   generator-deterministic
ok   committed-equals-generated
ok   build
ok   dump-equals-gguf-py
PASS 7/7
exit 0
```

Companion check, `tests/u2-lookup-check.sh` (added by this lane):

```
PASS 18527/18527 lookups equal gguf-py TensorNameMap
```

## Wall and RSS

- `u2-dump` (five arches, n=2): 0.01 s, 24 MB peak RSS.
- `u2-lookup` on the 18527 cases: 0.08 s, 25 MB peak RSS (about 4 us per `map_tensor_name` call).
- Build: `u2_dump` about 60 s, `u2_lookup` about 12 s. The literal tables are large, so the Mojo front-end pays for them.

## Files and LOC

| file | kind | lines |
|---|---|---|
| `tools/gen-tables.py` | generator (Python, oracle-side) | 188 |
| `src/gguf/consts.mojo` | generated | 5160 |
| `src/gguf/tensor_map.mojo` | generated | 1772 |
| `src/gguf/tensor_lookup.mojo` | hand-written | 53 |
| `src/u2_dump.mojo` | hand-written | 105 |
| `src/u2_lookup.mojo` | hand-written verifier CLI | 25 |
| `tests/u2-lookup-check.py`, `.sh` | verifier | 51, 8 |

Hand-written `src/` is 183 lines (`wc -l`, blanks and docstrings included).

## What was hard

- **gguf-py state.** `TensorNameMap.__init__` does `self.block_mappings_cfg.update(...)`, which mutates the class dict. The generator starts every arch from a pristine copy. For the five oracle arches, a fresh process and the oracle's shared-process order give identical maps (667/557/686/672/639 keys), so the oracle is unaffected.
- **Block rows.** A key with `{bid}` can map to a constant value (`encoder.layers.{bid}.self_attention.rotary_emb.inv_freq` to `rope_freqs`), and a constant key can be block-independent. Rows carry an `out_bid` flag. The generator rejects any key-to-two-values collision for block ids 0..127, so the first-match lookup equals gguf-py's dict overwrite.
- **Mojo 1.1 literals.** Bare inner `[...]` lists in a `List[Tuple[..., List[String]]]` infer as `Array`, and `List` has no variadic constructor. `arch_tensors` is therefore one row per (arch, tensor), regrouped in the dump. Returning a `List` needed `^`.
- **Trailing newline.** `json.dump` writes none, so the dump writes none (`print(..., end="")`).

## Deviations from the brief

- `map_tensor_name` lives in a hand-written `src/gguf/tensor_lookup.mojo`, not in the generated `tensor_map.mojo`, so the generated file stays pure data.
- Added `src/u2_lookup.mojo` and `tests/u2-lookup-check.{sh,py}`: the gate does not exercise `map_tensor_name`, so a separate differential was needed.
- The lookup takes base names (no `.weight`), as gguf-py's `mapping` does. The caller strips suffixes.
- Only the five oracle arches are generated. Other arches need a list change in `MAPPED_ARCHS`.

## Repair count

- Compile repairs: 2 (nested list literal to flat rows; `return out^`).
- Generator repairs: 3 (block key without `{bid}` treated as block; block key with constant value; out_bid flag).
- Cosmetic: 1 (docstring capitalisation warning).

## Notes for the next lane

- `tests/u2-gate.sh` deletes `.work/u2` on start, so keep gate logs outside that directory.
- Survey (CLAUDE.md §11): `~/iTools/INDEX.md` and `~/Brain/Skills/_index.md` had nothing that generates gguf-py tables into Mojo. `gguf-kv` and `gguf-sweep` read files, they do not codegen. Candidate for an iTool later if a second port needs it.
