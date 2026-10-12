"""Gguf-latent bake IN OUT --wa W.f32 --beta B --row-median M, or show FILE.

Bakes the LatentMAS data of one model into its GGUF as KV: llama.cpp rejects unknown tensors but ignores unknown
KV, so the file stays loadable. Header and KV are rewritten, the tensor infos are re-serialized, and the data section
is streamed from IN through the writer's one CHUNK-byte buffer. Failures print `FAIL gguf-latent: <reason>`, exit 1.
"""
from std.ffi import external_call
from std.math import sqrt
from std.memory import bitcast
from std.sys import argv, exit
from gguf.fmt import np_float32
from gguf.model import MAGIC, Gguf, Out, open_fd, T_ARRAY
from gguf.values import uint_at

comptime T_U32 = 4
comptime T_F32 = 6
comptime USAGE = "usage: gguf-latent bake IN OUT --wa W.f32 --beta B --row-median M | gguf-latent show FILE"


def is_latent(key: String) -> Bool:
    return (
        key == "latent.version"
        or key == "latent.beta"
        or key == "latent.embd_row_median"
        or key == "latent.w_a"
        or key == "latent.w_a.shape"
    )


def bake(inp: String, out_path: String, wa: String, beta: Float32, med: Float32) raises:
    if inp == out_path:
        raise Error("OUT must differ from IN")
    var g = Gguf(inp)
    if g.big:
        raise Error("big-endian input is not supported")
    var wfd = open_fd(wa, 0)
    var nbytes = Int(external_call["lseek", Int](wfd, Int64(0), Int32(2)))
    var n = nbytes // 4
    var d = Int(sqrt(Float64(n)))
    if nbytes % 4 != 0 or d == 0 or d * d != n:
        raise Error(wa + ": " + String(nbytes) + " bytes is not a square f32 matrix")
    var keep = List[Int]()
    for i in range(len(g.kvs)):
        if not is_latent(g.kvs[i].key):
            keep.append(i)
    var out = Out(out_path)
    out.put(MAGIC, 4)
    out.put(3, 4)
    out.put(len(g.tensors), 8)
    out.put(len(keep) + 5, 8)
    for i in keep:
        ref kv = g.kvs[i]
        out.put_str(kv.key)
        out.put(kv.vtype, 4)
        out.copy(g.fd, kv.start, kv.end - kv.start)
    out.put_str("latent.version")
    out.put(T_U32, 4)
    out.put(1, 4)
    out.put_str("latent.beta")
    out.put(T_F32, 4)
    out.put(Int(bitcast[DType.uint32](beta)), 4)
    out.put_str("latent.embd_row_median")
    out.put(T_F32, 4)
    out.put(Int(bitcast[DType.uint32](med)), 4)
    out.put_str("latent.w_a")
    out.put(T_ARRAY, 4)
    out.put(T_F32, 4)
    out.put(n, 8)
    out.copy(wfd, 0, nbytes)
    out.put_str("latent.w_a.shape")
    out.put(T_ARRAY, 4)
    out.put(T_U32, 4)
    out.put(2, 8)
    out.put(d, 4)
    out.put(d, 4)
    for t in range(len(g.tensors)):
        ref info = g.tensors[t]
        out.put_str(info.name)
        out.put(len(info.dims), 4)
        for dim in info.dims:
            out.put(dim, 8)
        out.put(info.ttype, 4)
        out.put(info.offset, 8)
    out.pad(g.alignment)
    out.copy(g.fd, g.data_offset, g.fsize - g.data_offset)
    out.close()
    _ = external_call["close", Int32](wfd)
    print("baked", out_path, "kv", len(keep) + 5, "tensors", len(g.tensors), "w_a", d, "x", d)


def find_kv(g: Gguf, key: String, vtype: Int) raises -> Int:
    var k = g.find(key)
    if k < 0:
        raise Error("missing " + key)
    if g.kvs[k].vtype != vtype:
        raise Error(key + " has value type " + String(g.kvs[k].vtype))
    return k


def show(path: String) raises:
    var g = Gguf(path)
    var v = find_kv(g, "latent.version", T_U32)
    if uint_at(g, g.kvs[v].start, 4) != 1:
        raise Error("latent.version is not 1")
    var b = find_kv(g, "latent.beta", T_F32)
    var m = find_kv(g, "latent.embd_row_median", T_F32)
    var s = find_kv(g, "latent.w_a.shape", T_ARRAY)
    var s_at = g.kvs[s].start
    if uint_at(g, s_at, 4) != T_U32 or uint_at(g, s_at + 4, 8) != 2:
        raise Error("latent.w_a.shape is not a u32 array of 2")
    var rows = Int(uint_at(g, s_at + 12, 4))
    var cols = Int(uint_at(g, s_at + 16, 4))
    var w = find_kv(g, "latent.w_a", T_ARRAY)
    var w_at = g.kvs[w].start
    if uint_at(g, w_at, 4) != T_F32 or uint_at(g, w_at + 4, 8) != UInt64(rows * cols):
        raise Error("latent.w_a is not an f32 array of " + String(rows * cols))
    var beta = bitcast[DType.float32](UInt32(uint_at(g, g.kvs[b].start, 4)))
    var med = bitcast[DType.float32](UInt32(uint_at(g, g.kvs[m].start, 4)))
    print("latent beta", np_float32(beta), "median", np_float32(med), "w_a", String(rows) + "x" + String(cols))


def run() raises:
    var a = argv()
    if len(a) == 3 and a[1] == "show":
        show(String(a[2]))
    elif len(a) >= 4 and a[1] == "bake":
        var wa = String()
        var beta = String()
        var med = String()
        var i = 4
        while i + 1 < len(a):
            if a[i] == "--wa":
                wa = String(a[i + 1])
            elif a[i] == "--beta":
                beta = String(a[i + 1])
            elif a[i] == "--row-median":
                med = String(a[i + 1])
            else:
                raise Error("unknown argument " + String(a[i]))
            i += 2
        if i != len(a) or wa.byte_length() == 0 or beta.byte_length() == 0 or med.byte_length() == 0:
            raise Error(USAGE)
        bake(String(a[2]), String(a[3]), wa, Float32(Float64(beta)), Float32(Float64(med)))
    else:
        raise Error(USAGE)


def main():
    try:
        run()
    except e:
        print("FAIL gguf-latent:", e)
        exit(1)
