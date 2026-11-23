"""gpunet smoke: the public names resolve with only gpunet, mmap and MAX on the include path (no faces), the GPU runner type-checks
for gfx1100, and the CPU tensor type does what its name says."""
from gpunet.onnx import Model, Node, Tensor
from gpunet.nn import Arr, run, needed
from gpunet.gpu.net import GpuNet
from gpunet.text import SiglipText
from gpunet.decode import Det, decode_scrfd


def main() raises:
    var a = Arr([2, 3, 4])
    if a.numel() != 24:
        raise Error("FAIL smoke: Arr numel " + String(a.numel()))
    print("PASS smoke gpunet: Arr numel", a.numel())
