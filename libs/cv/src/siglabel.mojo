"""mcv-labels: SigLIP zero-shot labels on the CPU runner of mojo-faces. A separate binary like stockfaces.mojo
(mojo-faces imports mojocv).  `mcv-labels tok TOK.json TEXTS.txt OUT.ids` writes the 64 ids of each text line,
the way transformers' SiglipTokenizer(padding="max_length", max_length=64, truncation=True) does."""
from std.collections import Dict
from std.math import exp, sqrt
from std.os import getenv, stat
from std.os.path import exists
from std.sys import argv
from gpunet.gpu.net import GpuNet
from gpunet.nn import Arr, run
from gpunet.onnx import Model
from max.gpu.host import DeviceContext
from tokenizers import Tokenizer

comptime SEQ = 64
comptime EOS = 1
comptime IMG = 224


def lower_cp(c: Int) -> Int:
    """Python str.lower() for Latin-1, Latin Extended-A, Romanian comma letters, Greek and Cyrillic capitals."""
    if (c >= 0xC0 and c <= 0xDE and c != 0xD7) or (c >= 0x391 and c <= 0x3AB and c != 0x3A2) or (c >= 0x410 and c <= 0x42F):
        return c + 32
    if c >= 0x400 and c <= 0x40F:
        return c + 80
    if c == 0x178:
        return 0xFF
    if (c >= 0x100 and c <= 0x137) or (c >= 0x14A and c <= 0x177) or (c >= 0x218 and c <= 0x21B):
        return c | 1
    if (c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E):
        return c + 1 if c % 2 == 1 else c
    return c


def canon(text: String) -> String:
    """SiglipTokenizer.canonicalize_text: lower case (lower_cp beyond ASCII), drop the 32 punctuation marks, one space between words."""
    var low = String()
    for ch in text.codepoints():
        var cp = Int(ch.to_u32())
        low += "i̇" if cp == 0x130 else chr(lower_cp(cp))  # İ: Python lower() keeps the dot as U+0307
    var out = List[UInt8]()
    var gap = False
    for b in low.as_bytes():
        var c = b
        if c >= 65 and c <= 90:
            c += 32
        var punct = (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126)
        if punct:
            continue
        if c == 32 or c == 9 or c == 10 or c == 13 or c == 11 or c == 12:
            gap = len(out) > 0
        else:
            if gap:
                out.append(32)
                gap = False
            out.append(c)
    return String(from_utf8_lossy=out)


def encode64(mut t: Tokenizer, text: String) raises -> List[Int]:
    """Ids of `text` then EOS (id 1), cut to 64 with EOS last, padded with 1."""
    var ids = t.encode(canon(text))
    var out = List[Int]()
    for i in range(min(len(ids), SEQ - 1)):
        out.append(Int(ids[i]))
    out.append(EOS)
    while len(out) < SEQ:
        out.append(EOS)
    return out^


def load_ppm(path: String) raises -> List[Float32]:
    """A binary 224x224 P6 file as CHW float32, SiglipImageProcessor's rescale 1/255 and mean 0.5 / std 0.5."""
    var b = open(path, "r").read_bytes()
    var p = 0
    var tok = 0
    while tok < 4:  # magic, width, height, maxval; '#' comments run to the line end
        while p < len(b) and (b[p] <= 32 or b[p] == 35):
            if b[p] == 35:
                while p < len(b) and b[p] != 10:
                    p += 1
            p += 1
        while p < len(b) and b[p] > 32:
            p += 1
        tok += 1
    p += 1
    if len(b) - p != 3 * IMG * IMG or b[0] != 80 or b[1] != 54:
        raise Error(path + ": not a P6 file of " + String(IMG) + "x" + String(IMG))
    var d = List[Float32](length=3 * IMG * IMG, fill=0)
    for q in range(IMG * IMG):
        for c in range(3):
            d[c * IMG * IMG + q] = (Float32(b[p + q * 3 + c]) / 255.0 - 0.5) / 0.5
    return d^


def load_f32(path: String) raises -> List[Float32]:
    var b = open(path, "r").read_bytes()
    var p = b.unsafe_ptr().bitcast[Float32]()
    var d = List[Float32](length=len(b) // 4, fill=0)
    for i in range(len(d)):
        d[i] = p[i]
    return d^


def lines(path: String) raises -> List[String]:
    var out = List[String]()
    for line in open(path, "r").read().split("\n"):
        if line.byte_length() > 0:
            out.append(String(line))
    return out^


def main() raises:
    var a = argv()
    if len(a) < 2:
        raise Error("usage: mcv-labels tok TOK.json TEXTS.txt OUT.ids")
    if String(a[1]) == "tok":
        var t = Tokenizer(String(a[2]))
        var s = String()
        for text in lines(String(a[3])):
            for i in encode64(t, text):
                s += String(i) + " "
            s += "\n"
        with open(String(a[4]), "w") as f:
            f.write(s)
    elif String(a[1]) == "image":  # image MODEL PPMS.txt OUT.f32: image_embeds, 768 float32 per 224x224 P6 file, appended per image
        var m = Model(String(a[2]))
        var done = 0
        if exists(String(a[4])):  # resume: the embeddings already in OUT are skipped
            done = Int(stat(String(a[4])).st_size) // (768 * 4)
        var todo = lines(String(a[3]))
        for i in range(done, len(todo)):
            var feeds = Dict[String, Arr]()
            feeds["pixel_values"] = Arr([1, 3, IMG, IMG], load_ppm(todo[i]))
            var r = run(m, feeds^, ["image_embeds"])
            ref e = r["image_embeds"]
            with open(String(a[4]), "a") as f:
                f.write_bytes(Span[UInt8](unsafe_ptr=e.d.unsafe_ptr().bitcast[UInt8](), length=e.numel() * 4))
    elif String(a[1]) == "gimage":  # gimage MODEL PPMS.txt OUT.f32: the same on GpuNet (fp32), GBATCH (16) pictures per run, under `gpu-wait run --timeout S`
        var m = Model(String(a[2]))
        var net = GpuNet(DeviceContext(), m, getenv("GARM", "16") == "16", ["image_embeds"])
        var nb = Int(getenv("GBATCH", "16"))
        var done = 0
        if exists(String(a[4])):
            done = Int(stat(String(a[4])).st_size) // (768 * 4)
        var todo = lines(String(a[3]))
        var i = done
        while i < len(todo):
            var b = min(nb, len(todo) - i)
            var px = List[Float32](capacity=b * 3 * IMG * IMG)
            for q in range(b):
                px.extend(load_ppm(todo[i + q]))
            var feeds = Dict[String, Arr]()
            feeds["pixel_values"] = Arr([b, 3, IMG, IMG], px^)
            var r = net.run(feeds^)
            ref e = r["image_embeds"]
            with open(String(a[4]), "a") as f:  # one append per batch: a killed run resumes at a batch edge
                f.write_bytes(Span[UInt8](unsafe_ptr=e.d.unsafe_ptr().bitcast[UInt8](), length=e.numel() * 4))
            i += b
    elif String(a[1]) == "top":  # top MODEL IMG.f32 TXT.f32 K OUT.tsv: per picture its K best labels as `index:cosine:probability`
        var m = Model(String(a[2]))
        var scale = exp(m.inits[m.init("onnx::Exp_3336")].f[0])  # SigLIP's learned logit scale and bias, read from the graph
        var bias = m.inits[m.init("onnx::Add_3337")].f[0]
        var im = load_f32(String(a[3]))
        var tx = load_f32(String(a[4]))
        var k = Int(String(a[5]))
        var ni = len(im) // 768
        var nt = len(tx) // 768
        var s = String()
        for i in range(ni):
            var cs = List[Float32](length=nt, fill=0)
            for j in range(nt):
                var d = Float32(0)
                for q in range(768):
                    d += im[i * 768 + q] * tx[j * 768 + q]
                cs[j] = d
            for _ in range(min(k, nt)):
                var best = 0
                for j in range(nt):
                    if cs[j] > cs[best]:
                        best = j
                s += String(best) + ":" + String(cs[best]) + ":" + String(1.0 / (1.0 + exp(-(scale * cs[best] + bias)))) + "\t"
                cs[best] = -2.0
            s += "\n"
        with open(String(a[6]), "w") as f:
            f.write(s)
    elif String(a[1]) == "text":  # text MODEL TOK TEXTS OUT.f32: text_embeds, 768 float32 per line
        var m = Model(String(a[2]))
        var t = Tokenizer(String(a[3]))
        var out = List[Float32]()
        for text in lines(String(a[4])):
            var d = List[Float32](capacity=SEQ)
            for i in encode64(t, text):
                d.append(Float32(i))  # ids are exact in float32 (< 2^24); the runner keeps tensors as float
            var feeds = Dict[String, Arr]()
            feeds["input_ids"] = Arr([1, SEQ], d^)
            # faces.nn has no Gather along axis 1, which the graph uses to pick the last token: stop at the final
            # LayerNorm and finish here (last position, head Linear, L2 norm), checked against text_embeds by siglip_text.sh
            var ln = "/text_model/final_layer_norm/LayerNormalization_output_0"
            var r = run(m, feeds^, [ln])
            ref h = r[ln]
            var width = h.shape[2]
            ref w = m.inits[m.init("text_model.head.weight")]
            ref bias = m.inits[m.init("text_model.head.bias")]
            var e = List[Float32](capacity=width)
            var ss = Float32(0)
            for j in range(width):
                var s = bias.f[j]
                for k in range(width):
                    s += h.d[(SEQ - 1) * width + k] * w.f[j * width + k]
                e.append(s)
                ss += s * s
            var inv = 1.0 / sqrt(ss)
            for j in range(width):
                out.append(e[j] * inv)
        with open(String(a[5]), "w") as f:
            f.write_bytes(Span[UInt8](unsafe_ptr=out.unsafe_ptr().bitcast[UInt8](), length=len(out) * 4))
    else:
        raise Error("FAIL usage: unknown mode " + String(a[1]))
