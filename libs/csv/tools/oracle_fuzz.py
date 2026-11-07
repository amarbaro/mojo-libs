"""R differential: random bytes x random dialects; CPython csv.reader (latin-1 = 1 byte : 1 char)."""
import csv, io, random, struct, sys
sys.stdout.reconfigure(line_buffering=True)
rnd = random.Random(int(sys.argv[2])); n = int(sys.argv[3])
alpha = b'ab,;"\\ \r\n\x00\xc3\xa9'
cases, exp = bytearray(), []
for _ in range(n):
    d = rnd.choice(b',;'); q = 34; esc = rnd.choice([0, 92]); dq = rnd.random() < .7
    sk = rnd.random() < .3; st = rnd.random() < .3; qu = rnd.choice([0, 1, 3, 5])
    data = bytes(rnd.choice(alpha) for _ in range(rnd.randrange(0, 24)))
    cases += struct.pack('<8BI', d, q, esc, 1 if esc else 0, dq, sk, st, qu, len(data)) + data
    try:
        r = csv.reader(io.StringIO(data.decode('latin-1'), newline=''), delimiter=chr(d), quotechar='"',
                       escapechar=chr(esc) if esc else None, doublequote=dq, skipinitialspace=sk,
                       strict=st, quoting=qu)
        rows = list(r)
        exp.append('|'.join(','.join('N' if f is None else 'h' + f.encode('latin-1').hex() for f in row) for row in rows))
    except csv.Error:
        exp.append('ERR')
open(sys.argv[1] + '.bin', 'wb').write(cases)
open(sys.argv[1] + '.exp', 'w').write('\n'.join(exp) + '\n')
