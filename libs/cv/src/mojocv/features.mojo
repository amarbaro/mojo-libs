# features: binary-descriptor matching and ORB. Descriptors are rows of an (n, 32, 1) uint8 Mat.
from std.bit import pop_count
from max.algorithm import parallelize
from mojocv.mat import Mat, load, save
from mojocv.core import Args


def hamming(a: Mat[DType.uint8], ia: Int, b: Mat[DType.uint8], ib: Int) -> Int:
    var d = 0
    for k in range(a.cols):
        d += Int(pop_count(a.data[ia * a.cols + k] ^ b.data[ib * b.cols + k]))
    return d


def knn2(q: Mat[DType.uint8], t: Mat[DType.uint8]) -> Mat[DType.int32]:
    """For every query row the two nearest train rows by Hamming distance: (n, 4) = train1, dist1, train2, dist2.
    Equal distances keep the lower train index first, as cv2's brute-force matcher does."""
    var o = Mat[DType.int32](q.rows, 4, 1)
    var po = o.ptr()

    def row(i: Int) {imm}:
        var b1 = 1 << 30
        var b2 = 1 << 30
        var i1 = -1
        var i2 = -1
        for j in range(t.rows):
            var d = hamming(q, i, t, j)
            if d < b1:
                b2 = b1
                i2 = i1
                b1 = d
                i1 = j
            elif d < b2:
                b2 = d
                i2 = j
        po[unsafe_offset=4 * i] = Int32(i1)
        po[unsafe_offset=4 * i + 1] = Int32(b1)
        po[unsafe_offset=4 * i + 2] = Int32(i2)
        po[unsafe_offset=4 * i + 3] = Int32(b2)

    parallelize(row, q.rows)
    return o^


def ratio_test(k: Mat[DType.int32], ratio: Float64) -> Mat[DType.int32]:
    """Lowe's test on knn2 output: keep (query, train, dist) where d1 < ratio * d2."""
    var keep = List[Int32]()
    for i in range(k.rows):
        if Float64(k.at(i, 1)) < ratio * Float64(k.at(i, 3)):
            keep.append(Int32(i))
            keep.append(k.at(i, 0))
            keep.append(k.at(i, 1))
    var o = Mat[DType.int32](len(keep) // 3, 3, 1)
    for i in range(len(keep)):
        o.data[i] = keep[i]
    return o^


def run(mut a: Args) raises -> Bool:
    if a.op == "bfmatch":
        var q = load[DType.uint8](a.ins[0])
        var t = load[DType.uint8](a.ins[1])
        var k = Mat[DType.int32](0, 0)
        while a.again():
            k = knn2(q, t)
        var o = Mat[DType.int32](q.rows, 2, 1)
        for i in range(q.rows):
            o.set(i, 0, 0, k.at(i, 0))
            o.set(i, 1, 0, k.at(i, 1))
        save(o, a.out)
    elif a.op == "knnmatch":
        var q = load[DType.uint8](a.ins[0])
        var t = load[DType.uint8](a.ins[1])
        var k = Mat[DType.int32](0, 0)
        var g = Mat[DType.int32](0, 0)
        while a.again():
            k = knn2(q, t)
            g = ratio_test(k, a.f("ratio", 0.75))
        save(k, a.out)
        save(g, a.out + ".1")
    else:
        return False
    return True
