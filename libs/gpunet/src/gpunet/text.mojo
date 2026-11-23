"""SigLIP text tower on GpuNet (plan R6a). The graph is built only up to the final LayerNorm (`faces.nn` and GpuNet have no Gather along
axis 1, which the exported graph uses to pick the last token); the last position, the head Linear and the L2 norm finish on the host,
768 x 768 multiplies per text. `ids` are token ids as the tokenizer wrote them (64 per text, SigLIP v1), kept as floats like every tensor
of the runner (ids are exact below 2^24)."""
from std.collections import Dict
from std.math import sqrt
from max.gpu.host import DeviceContext
from gpunet.gpu.net import GpuNet
from gpunet.nn import Arr
from gpunet.onnx import Model

comptime FINAL_LN = "/text_model/final_layer_norm/LayerNormalization_output_0"


struct SiglipText(Movable):
    var net: GpuNet
    var w: List[Float32]  # head Linear, [out, in] row major
    var b: List[Float32]
    var seq: Int
    var width: Int

    def __init__(out self, ctx: DeviceContext, model: Model, fp16: Bool, seq: Int = 64) raises:
        self.net = GpuNet(ctx, model, fp16, [FINAL_LN])
        self.w = model.inits[model.init("text_model.head.weight")].f.copy()
        self.b = model.inits[model.init("text_model.head.bias")].f.copy()
        self.seq = seq
        self.width = len(self.b)

    def forward(mut self, ids: List[Int], first: Int, n: Int, mut hidden: List[Float32], mut proj: List[Float32], mut emb: List[Float32]) raises:
        """`ids` holds texts of `seq` ids; texts first .. first+n-1 are run. Appends per text: the final LayerNorm row of the last position, the head output, and the
        L2-normalised head output (`text_embeds`)."""
        var d = List[Float32](capacity=n * self.seq)
        for i in range(n * self.seq):
            d.append(Float32(ids[first * self.seq + i]))
        var feeds = Dict[String, Arr]()
        feeds["input_ids"] = Arr([n, self.seq], d^)
        var r = self.net.run(feeds^)
        ref h = r[FINAL_LN]
        var wd = self.width
        for t in range(n):
            var base = (t * self.seq + self.seq - 1) * wd
            var ss = Float32(0)
            var row = List[Float32](capacity=wd)
            for j in range(wd):
                var s = self.b[j]
                for k in range(wd):
                    s += h.d[base + k] * self.w[j * wd + k]
                row.append(s)
                ss += s * s
            var inv = 1.0 / sqrt(ss)
            for k in range(wd):
                hidden.append(h.d[base + k])
                proj.append(row[k])
                emb.append(row[k] * inv)
