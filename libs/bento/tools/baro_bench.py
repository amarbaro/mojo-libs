"""HTTP clients for baro_serve: greedy identity and throughput of /generate (batched) against /generate_serial (one at a time).

usage: baro_bench.py PORT PROMPT_FILE REF_FILE N REPS [--clients 1,8,32] [--per 8,2,2] [--fake] [--chat GGUF_OK]
  PROMPT_FILE, REF_FILE: a pack's prompt-tokens.txt and ref-tokens-64.txt (`GENERATED: t t ...`); every request is that
  prompt with n=N. The reference answer is the engine's own: one /generate_serial request made first, alone. Every
  later answer, batched or not, must equal it; the file REF_FILE is only compared with it (its first K tokens agree: the
  mojo-baro engines of 2026-10-17 and 2026-10-22 both depart from it at token 31, so it is stale, not the adapter). --fake: tests/fake_engine instead; prompts differ per request and
  the answer is its formula, which proves each answer reaches the right client.
Each (clients, mode) cell runs REPS times, the modes rotating so none always goes first. Output: `cell` lines, then per
client count the medians and `row clients C: batched >= serial: PASS|FAIL (ratio R)`. Exit 1 on a wrong token or a failed request.
"""
import http.client
import json
import statistics
import sys
import threading
import time

MODES = ["generate_serial", "generate"]


def post(conn, path, body):
    conn.request("POST", path, json.dumps(body), {"content-type": "application/json"})
    r = conn.getresponse()
    data = r.read()
    return r.status, data


def expected_fake(prompt, n):
    s = sum(prompt)
    return [(s * 31 + i * 17 + 7) % 50021 for i in range(n)]


def run_cell(port, mode, clients, per, prompt, ref, n, fake):
    bad = [0] * clients
    toks = [0] * clients
    errs = []

    def client(ci):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3600)
        for k in range(per):
            p = prompt + [1000 + ci * 100 + k] if fake else prompt
            want = expected_fake(p, n) if fake else ref[:n]
            st, data = post(conn, "/" + mode, {"prompt": p, "n": n})
            if st != 200:
                errs.append(f"client {ci}: HTTP {st} {data[:200]!r}")
                bad[ci] += 1
                continue
            got = json.loads(data)["tokens"]
            toks[ci] += len(got)
            if got != want:
                bad[ci] += 1
        conn.close()

    ts = [threading.Thread(target=client, args=(i,)) for i in range(clients)]
    t0 = time.perf_counter()
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    wall = time.perf_counter() - t0
    return sum(toks), sum(bad), wall, errs


def main():
    a = sys.argv[1:]
    port, pfile, rfile, n, reps = int(a[0]), a[1], a[2], int(a[3]), int(a[4])
    opt = {a[i]: a[i + 1] for i in range(5, len(a) - 1, 2) if a[i].startswith("--")}
    fake = "--fake" in a
    clients_list = [int(x) for x in opt.get("--clients", "1,8,32").split(",")]
    per_list = [int(x) for x in opt.get("--per", "8,2,2").split(",")]
    prompt = [int(x) for x in open(pfile).read().split()]
    ref = [int(x) for x in open(rfile).read().replace("GENERATED:", " ").split()]
    ok = True
    summary = []
    if not fake:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3600)
        st, data = post(conn, "/generate_serial", {"prompt": prompt, "n": n})
        assert st == 200, (st, data)
        ref_self = json.loads(data)["tokens"]
        k = next((i for i in range(min(len(ref_self), len(ref))) if ref_self[i] != ref[i]), min(len(ref_self), len(ref)))
        print(f"reference: the engine's own {len(ref_self)} tokens; stored ref file agrees on the first {k}")
        ref = ref_self
    # The Batcher is BentoML's dispatcher: its first ~11 requests are training phases that cork on purpose and its
    # estimates start pessimistic. Take it through them before timing anything (the serial path has nothing to learn).
    run_cell(port, "generate", 4, 3, prompt, ref, min(n, 8), fake)
    for clients, per in zip(clients_list, per_list):
        run_cell(port, "generate", 1, 1, prompt, ref, n, fake)  # first request on a cold pipe
        rates = {m: [] for m in MODES}
        for rep in range(reps):
            for j in range(len(MODES)):
                mode = MODES[(j + rep) % len(MODES)]
                toks, bad, wall, errs = run_cell(port, mode, clients, per, prompt, ref, n, fake)
                print(f"cell {clients} {mode} {rep} {toks} {wall:.3f} {toks / wall:.2f} bad {bad}", flush=True)
                for e in errs[:3]:
                    print("  " + e)
                if bad:
                    ok = False
                rates[mode].append(toks / wall)
        med = {m: statistics.median(v) for m, v in rates.items()}
        ratio = med["generate"] / med["generate_serial"]
        summary.append((clients, med, ratio))
    for clients, med, ratio in summary:
        print(
            f"median clients {clients}: serial {med['generate_serial']:.2f} tok/s, batched {med['generate']:.2f} tok/s, "
            f"ratio {ratio:.4f}"
        )
    for clients, med, ratio in summary:
        print(f"row clients {clients}: batched >= serial: {'PASS' if ratio >= 1.0 else 'FAIL'} (ratio {ratio:.4f})")
    print("identity:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


main()
