"""mcv-labels: SigLIP zero-shot labels on the CPU runner of mojo-faces. A separate binary like stockfaces.mojo
(mojo-faces imports mojocv).  `mcv-labels tok TOK.json TEXTS.txt OUT.ids` writes the 64 ids of each text line,
the way transformers' SiglipTokenizer(padding="max_length", max_length=64, truncation=True) does."""
from std.sys import argv
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
    else:
        raise Error("FAIL usage: unknown mode " + String(a[1]))
