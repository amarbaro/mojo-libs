import os, base64
os.makedirs("tests/golden", exist_ok=True)
rows=[]
for n in range(65):
    data=bytes([i%256 for i in range(n)])
    enc=base64.b64encode(data)
    rows.append(f"b64 {n} {enc.decode()}")
# error rows
rows.append("err b64 strict leading =")
open("tests/golden/basic.txt","w").write("\n".join(rows)+"\n")
print(len(rows))
