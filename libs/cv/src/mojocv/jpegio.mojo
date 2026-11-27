"""In-process BGR JPEG decode for the stock CLI."""
from ._jpeg_baseline import load_baseline_jpeg
from .mat import Mat


def load_jpeg(path: String) raises -> Mat[DType.uint8]:
    """Load a baseline JPEG, or request the stock CLI's existing decode fallback."""
    try:
        return load_baseline_jpeg(path)
    except e:
        raise Error("jpeg-fallback: " + String(e))
