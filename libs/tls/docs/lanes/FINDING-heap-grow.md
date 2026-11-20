# FINDING heap-grow (tls-pub, 2026-11-12): use-after-free in RecordReader.next, library bug

**Verdict: library bug** (src/tls/tls13/record.mojo:190-192, present at HEAD, not caused by the uncommitted lane edits).
heaptide is not at fault: it only makes the bug visible, because under its preload a 256 KiB+ block is a glibc mmap
chunk that `free` unmaps at once, while natively the freed block stays readable. UNVERIFIED: why the native run never
unmaps (same `aligned_alloc` symbol; MALLOC_MMAP_THRESHOLD_/PERTURB_ pinned natively change nothing; native block
addresses look like 0x509f..., not glibc heap). Open question for heaptide: does its shim profile the same allocator
production uses? Not chased (out of scope).

## Mechanism
```
elif self.pos > 65536:                                    # compaction, after 4 records of 16406 bytes: pos = 65624
    var rest = List[UInt8](length=len(self.buf) - self.pos, fill=0)
    _cp(Int(rest.unsafe_ptr()), Int(self.buf.unsafe_ptr()) + self.pos, len(rest))   # reads the OLD buffer
    self.buf = rest^                                      # drops the OLD buffer
```
The old buffer's address goes through `Int(...)`, so the compiler sees no dependency between the memcpy and the
drop of the old `self.buf`. In the built code the drop is scheduled **before** the memcpy:
`Conn::step` +0x1379: `_unchecked_grow` (rest) -> `KGEN_CompilerRT_AlignedFree(old buf)` -> `memcpy(rest, old+pos, n)`
(objdump of `.work/hx/hx`; tests/rr_grow shows the same free -> memcpy order at main+0x580..0x5a0).
Under glibc with the block mmapped, the memcpy source page is already unmapped: SIGSEGV. If the freed block is
reused instead (the earlier "bad_record_mac on the last record" run, before the send_app capacity change), the copy
reads foreign bytes: bad_record_mac. Natively the block is still intact, so every gate passes: **latent UAF in
production builds too**; the bytes are right only by luck.

## Evidence
- gdb, heap_xfer 1 262144 under heaptide: SIGSEGV in `memcpy` (dst 0x7ffdb41b6010 = rest, src 0x7ffdb41f7068, n 196872 =
  262496 - 65624). `catch syscall munmap` with `rdi == 0x7ffdb41e7000, rsi == 0x41000`: hit from `free` called in
  `Conn::step` 0x16 bytes before the faulting memcpy; src = old buf (0x7ffdb41e7010) + pos 65624. `info proc mappings`: gap there.
- Native, same binary, MALLOC_PERTURB_=165 under gdb: the FREE breakpoint fires before the MEMCPY breakpoint, same order.
- Sizes under heaptide: 64 KiB passes (pos never > 65536); 256 KiB, 512 KiB, 768 KiB, 1 MiB all SIGSEGV.
- Scratch fix (NOT in src/; copy in `.work/hx/fix/src`): replace the three lines by
  `self.buf = List[UInt8](Span(self.buf)[self.pos:])` (the Span borrows the buffer until the new list is built):
  rr_grow PASS and heap_xfer 1 MiB passes under heaptide.

## Minimal repro
`tests/rr_grow.mojo`: RecordReader only, 16 records pushed at once, bytes checked.
```
.venv/bin/mojo build -I src tests/rr_grow.mojo -o .work/hx/rr
.work/hx/rr                                                                 # PASS rr_grow (latent)
~/Projects/tools/heaptide/heaptide run --out .work/hx/ht-rr -- .work/hx/rr  # Segmentation fault
```
The input list is built with exact capacity on purpose: a big `List` grown by doubling frees mapped blocks, which
raises glibc's mmap threshold and hides the bug. Full-stack repro: `tests/heap_xfer.mojo` (`heap_xfer 1 262144`).
Native-only detection does not exist yet (valgrind dies with SIGILL on Mojo's AVX-512); heaptide is the detector.

## Same hazard, other sites (not touched: src/tls waits for the owner's fix)
- `src/tls/tls12/realcrypto.mojo:132` (uncommitted lane edit): `memcpy(buf+start, Int(body.unsafe_ptr()), len(body))`.
  `body`'s last use is inside that statement, so Mojo may drop it before the call. Same class. Fix: copy with an index loop,
  or use `body` again after the call.
- `src/tls/tls13/record.mojo:184` reads `self.buf` into a fresh list: safe (self.buf is live).
- Rule line for docs/rules.md once the fix lands: `a pointer laundered through Int() does not keep its List alive: Mojo drops
  a List at its last use and the free can be ordered before the memcpy -> memcpy only from a Span or pointer whose owner is used again after the call`.

## Regression test (to add with the fix)
rr_grow natively plus under `heaptide run`; wire both into the gate when the fix lands.
