import csv
import os
out_dir = os.path.join(os.path.dirname(__file__), "..", "tests", "golden")
os.makedirs(out_dir, exist_ok=True)
path = os.path.join(out_dir, "vectors.txt")
with open(path, "w", newline="") as f:
    w = csv.writer(f)
    for i in range(50):
        w.writerow(["a", f"b{i}"])
    for i in range(10):
        f.write(f"plain {i}\n")
print("wrote", path)