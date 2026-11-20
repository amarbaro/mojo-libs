import semver, time
vs = [l for l in open("tests/data/random.txt").read().split("\n") if l]
R = 20; t = time.perf_counter()
for _ in range(R):
    for s in vs: semver.Version.parse(s)
p = (time.perf_counter() - t) / (R * len(vs)) * 1e9
ps = [semver.Version.parse(s) for s in vs]; t = time.perf_counter()
for _ in range(R):
    for a, b in zip(ps, ps[1:]): a.compare(b)
print("python parse ns", round(p), " compare ns", round((time.perf_counter() - t) / (R * (len(ps) - 1)) * 1e9))
