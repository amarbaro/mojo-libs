"""Usage: zoo_text MODEL IDS OUTDIR ARM BATCH: the SigLIP v1 text tower on GpuNet (arm 16 = fp16 weights, 32 = fp32) for the ids in IDS (64 per
line), BATCH texts per run. Writes OUTDIR/{hidden,proj,emb}.f32, 768 floats per text. Run under `gpu-wait run --shared`."""
from std.sys import argv
from max.gpu.host import DeviceContext
from gpunet.onnx import Model
from gpunet.text import SiglipText


def put(path: String, v: List[Float32]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span[UInt8](unsafe_ptr=v.unsafe_ptr().unsafe_bitcast[UInt8](), length=len(v) * 4))


def main() raises:
    var a = argv()
    if len(a) < 6:
        raise Error("usage: zoo_text MODEL IDS OUTDIR ARM BATCH")
    var ids = List[Int]()
    for line in open(String(a[2]), "r").read().split("\n"):
        if line.byte_length() == 0:
            continue
        for tok in line.split(" "):
            if tok.byte_length() > 0:
                ids.append(Int(String(tok)))
    var n = len(ids) // 64
    if n * 64 != len(ids):
        raise Error("FAIL input: id count " + String(len(ids)) + " is not a multiple of 64")
    var net = SiglipText(DeviceContext(), Model(String(a[1])), String(a[4]) == "16")
    var nb = Int(String(a[5]))
    var h = List[Float32]()
    var p = List[Float32]()
    var e = List[Float32]()
    var i = 0
    while i < n:
        var b = min(nb, n - i)
        net.forward(ids, i, b, h, p, e)
        i += b
    put(String(a[3]) + "/hidden.f32", h)
    put(String(a[3]) + "/proj.f32", p)
    put(String(a[3]) + "/emb.f32", e)
    print("ok zoo_text:", n, "texts, arm", String(a[4]), "batch", nb)
