"""mcv-labels: SigLIP zero-shot labels on the CPU runner of mojo-faces. A separate binary like stockfaces.mojo
(mojo-faces imports mojocv).  `mcv-labels tok TOK.json TEXTS.txt OUT.ids` writes the 64 ids of each text line,
the way transformers' SiglipTokenizer(padding="max_length", max_length=64, truncation=True) does."""
from std.collections import Dict
from std.math import sqrt
from std.sys import argv
from faces.nn import Arr, run
from faces.onnx import Model
from tokenizers import Tokenizer

comptime SEQ = 64
comptime EOS = 1


def canon(text: String) -> String:
    """SiglipTokenizer.canonicalize_text for ASCII: lower case, drop the 32 punctuation marks, one space between words."""
    var out = List[UInt8]()
    var gap = False
    for b in text.as_bytes():
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
