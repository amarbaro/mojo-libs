#!/usr/bin/env python3
"""Deterministic CPython 3.14 vectors; tab-separated, byte fields hex."""
import base64
import itertools
import random
from pathlib import Path

OPS = ('b64encode', 'b64decode', 'standard_b64encode', 'standard_b64decode',
       'urlsafe_b64encode', 'urlsafe_b64decode', 'b32encode', 'b32decode',
       'b32hexencode', 'b32hexdecode', 'b16encode', 'b16decode')


def evaluate(op, data, flag=False, extra=b''):
    call = getattr(base64, op)
    kwargs = {}
    if op == 'b64decode':
        kwargs = dict(validate=flag, altchars=extra or None)
    elif op == 'standard_b64decode':
        call, kwargs = base64.b64decode, dict(validate=flag)
    elif op == 'urlsafe_b64decode' and flag:
        call, kwargs = base64.b64decode, dict(validate=True, altchars=b'-_')
    elif op == 'b32decode':
        kwargs = dict(casefold=flag, map01=extra or None)
    elif op in ('b32hexdecode', 'b16decode'):
        kwargs = dict(casefold=flag)
    try:
        return 'ok', call(data, **kwargs).hex()
    except (ValueError, AssertionError) as error:
        return 'err', str(error)


def vectors():
    for n in range(65):
        data = bytes((i * 73 + n) % 256 for i in range(n))
        for enc, dec in zip(OPS[::2], OPS[1::2]):
            yield enc, data, False, b''
            yield dec, getattr(base64, enc)(data), False, b''
    for n in range(5):
        for chars in itertools.product(b'A=!\xff', repeat=n):
            for strict in (False, True):
                yield 'b64decode', bytes(chars), strict, b''
    for data in (b'AAAA=', b'YQ==A', b'YQ=Q', b'YQ===', b'A!A!A!AA', b'=!',
                 b'YQ==!', b'AA=!', b'AA==!', b'AA==A', b'A=!A', b'!AAA='):
        for strict in (False, True):
            yield 'b64decode', data, strict, b''
    for extra in (b'!', b'abc', b'\x00\xff\n', b"'", b'"', b'-_', b'==', b'AA',
                  b'\\', b'\t', b'\r', b'\'"', b'\'"\\', b'\'"\t\r\\', b':,'):
        for data in (b'', b'-w==', b'__8=', b'AAAA'):
            for strict in (False, True):
                yield 'b64decode', data, strict, extra
    for op in ('b32decode', 'b32hexdecode'):
        for pad in range(17):
            for char in (b'A', b'!', b'a'):
                for fold in (False, True):
                    yield op, char * (16-pad) + b'=' * pad, fold, b''
        for data in (b'A', b'=AAAAAAA', b'aa======', b'\xffAAAAAAA', b'', b'!======='):
            for fold in (False, True):
                yield op, data, fold, b''
    for data in (b'01AAAAAA', b'01======', b'A', b'', b'!!!!!!!!'):
        for extra in (b'I', b'L', b'i', b'!', b'IL', b'\x00\xff', b"'", b'"',
                      b'\\\\', b'\t\t', b'\r\r', b'\'"', b'\'"\\', b'\'"\t\r\\'):
            for fold in (False, True):
                yield 'b32decode', data, fold, extra
    for data in (b'A', b'Z', b'AA!', b'aa', b'\xff0', b'A A', b'', b'0123456789ABCDEF', b'GG', b'AG'):
        for fold in (False, True):
            yield 'b16decode', data, fold, b''
    rng = random.Random(42)
    for _ in range(500):
        yield rng.choice(OPS[1::2]), rng.randbytes(rng.randrange(65)), bool(rng.randrange(2)), b''


def main():
    rows = []
    for index, (op, data, flag, extra) in enumerate(vectors()):
        status, result = evaluate(op, data, flag, extra)
        rows.append('\t'.join((str(index), op, data.hex(), str(int(flag)), extra.hex(), status, result)))
    Path('tests/golden/basic.txt').write_text('\n'.join(rows) + '\n')
    print(f'goldens: {len(rows)} CPython vectors')


if __name__ == '__main__':
    main()
