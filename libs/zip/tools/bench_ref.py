#!/usr/bin/env python3
"""CPython reference for bench/zipbench.mojo: same three jobs on the same fixtures. Usage: bench_ref.py [many|stored|deflate]"""
import sys
import time
import zipfile
import zlib

which = sys.argv[1] if len(sys.argv) > 1 else 'many'
t0 = time.perf_counter_ns()
if which == 'many':
    z = zipfile.ZipFile('.work/bench/many.zip')
    total = sum(i.file_size for i in z.infolist())
    n = len(z.namelist())
    check = f'entries {n} bytes {total}'
else:
    z = zipfile.ZipFile(f'.work/bench/big_{which}.zip')
    data = z.read('big.bin')
    check = f'bytes {len(data)} crc {zlib.crc32(data):08x}'
t1 = time.perf_counter_ns()
print(f'python {which} ms {(t1 - t0) // 1_000_000} {check}')
