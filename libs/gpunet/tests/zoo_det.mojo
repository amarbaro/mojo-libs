"""Usage: zoo_det MODEL BLOBLIST OUTDIR ARM. For each path in BLOBLIST (a 1x3x640x640 float32 blob, letterbox scale 1) runs the detector on GpuNet
(ARM 16 = fp16 weights, 32 = fp32). Writes OUTDIR/NN.raw.f32 (the nine outputs, graph order, concatenated) and OUTDIR/NN.det.tsv (decoded and
suppressed detections: score, box, five landmarks). Run under `gpu-wait run --shared`."""
from std.collections import Dict
from std.sys import argv
from max.gpu.host import DeviceContext
from gpunet.decode import decode_scrfd
from gpunet.gpu.net import GpuNet
from gpunet.nn import Arr
from gpunet.onnx import Model


def main() raises:
    var a = argv()
    if len(a) < 5:
        raise Error("usage: zoo_det MODEL BLOBLIST OUTDIR ARM")
    var net = GpuNet(DeviceContext(), Model(String(a[1])), String(a[4]) == "16")
    var idx = 0
    for path in open(String(a[2]), "r").read().split("\n"):
        if path.byte_length() == 0:
            continue
        var b = open(String(path), "r").read_bytes()
        var n = len(b) // 4
        if n != 3 * 640 * 640:
            raise Error("FAIL input: " + String(path) + " has " + String(n) + " floats, not 3x640x640")
        var p = b.unsafe_ptr().bitcast[Float32]()
        var blob = Arr([1, 3, 640, 640])
        for i in range(n):
            blob.d[i] = p[i]
        var feeds = Dict[String, Arr]()
        feeds[net.inputs[0]] = blob^
        var r = net.run(feeds^)
        var raw = List[Float32]()
        for name in net.outputs:
            ref o = r[name]
            for q in range(len(o.d)):
                raw.append(o.d[q])
        var tag = String(idx)
        while tag.byte_length() < 2:
            tag = "0" + tag
        with open(String(a[3]) + "/" + tag + ".raw.f32", "w") as f:
            f.write_bytes(Span[UInt8](unsafe_ptr=raw.unsafe_ptr().bitcast[UInt8](), length=len(raw) * 4))
        var s = String()
        for d in decode_scrfd(r, net.outputs, 1.0):
            s += String(d.score)
            for k in range(4):
                s += "\t" + String(d.box[k])
            for k in range(10):
                s += "\t" + String(d.kps[k])
            s += "\n"
        with open(String(a[3]) + "/" + tag + ".det.tsv", "w") as f:
            f.write(s)
        idx += 1
    print("ok zoo_det:", idx, "images, arm", String(a[4]))
