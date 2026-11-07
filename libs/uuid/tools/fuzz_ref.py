"""R differential: random UUID-ish strings; CPython uuid.UUID(hex) value or error text."""
import random, sys, uuid
sys.stdout.reconfigure(line_buffering=True)
rnd = random.Random(int(sys.argv[2])); n = int(sys.argv[3])
parts = list('0123456789abcdefABCDEF') * 4 + ['-', '{', '}', 'urn:', 'uuid:', '_', '+', ' ', 'x', 'X', '0x', 'é', 'g']
ins, exp = [], []
for _ in range(n):
    base = uuid.UUID(int=rnd.getrandbits(128)).hex if rnd.random() < .5 else ''
    s = ''.join(rnd.choice(parts) for _ in range(rnd.randrange(0, 40))) if not base else base
    for _ in range(rnd.randrange(0, 4)):
        k = rnd.randrange(0, len(s) + 1); s = s[:k] + rnd.choice(parts) + s[k:]
    ins.append(s)
    try: exp.append('ok ' + str(uuid.UUID(s)))
    except ValueError as e: exp.append('err ValueError: ' + str(e))
open(sys.argv[1] + '.in', 'w', encoding='utf-8').write('\n'.join(ins) + '\n')
open(sys.argv[1] + '.exp', 'w', encoding='utf-8').write('\n'.join(exp) + '\n')
