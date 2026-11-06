# Verification rules

- Placeholder replay, oracle and benchmark output passed the old shape gate -> compare real codec bytes and full errors, compute throughput from timed calls, and run a compiling behavioral mutant.
- A noncompiling mutant was counted as killed -> invalid mutants are failures and never kills; use the fresh scaffold runner.
- CLI help was treated as a recall query, and missing paths stopped batched reads -> use the discovered recall schema and check optional paths before reading.
- A combined delete/add patch was rejected -> update existing paths or write their complete contents once.
- A truncated pipeline stopped at SIGPIPE under pipefail -> use bounded reads without an early-closing pipe.
- Imported open and block-local text failed Mojo compilation -> use prelude open and declare shared values before the with block.
- Tuple iteration failed Mojo compilation -> iterate an Array or List for runtime loops.
- Error counts used source length, and duplicate altchars used the first translation -> count valid quanta and test duplicate translation keys against CPython.
- CPython 3.14 maintenance versions changed padding semantics -> name the oracle patch versions and check the corresponding upstream branch order.
- A reserved case loop variable failed parsing -> use trial or an unnamed loop variable.
- A scenario runner exit code was ignored -> both oracle and runner must exit zero as well as match output.
- The prose-edit gate did not recognize a skill read through exec -> read the named skill, preserve its writing rules, and use the available file-writing path without changing global gate state.
