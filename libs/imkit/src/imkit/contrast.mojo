"""WCAG 2 contrast of packed rgba colours (r | g << 8 | b << 16 | a << 24, alpha ignored) and the theme gate the style
presets must pass: text/panel and on_accent/accent >= 4.5, muted/panel >= 3."""
from std.math import pow
from .theme import Theme


def lin(c: UInt32) -> Float64:
    var s = Float64(c & 255) / 255.0
    return s / 12.92 if s <= 0.04045 else pow((s + 0.055) / 1.055, 2.4)


def lum(c: UInt32) -> Float64:
    return 0.2126 * lin(c) + 0.7152 * lin(c >> 8) + 0.0722 * lin(c >> 16)


def contrast(a: UInt32, b: UInt32) -> Float64:
    var x = lum(a)
    var y = lum(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)


def r2(x: Float64) -> String:
    return String(Float64(Int(x * 100)) / 100)


def theme_faults(t: Theme) -> String:
    """Empty when the theme passes, else one `role a/b ratio` entry per failed pair."""
    var out = String()
    if contrast(t.text, t.panel | 0xFF000000) < 4.5:
        out += "text/panel " + r2(contrast(t.text, t.panel)) + " "
    if contrast(t.on_accent, t.accent) < 4.5:
        out += "on_accent/accent " + r2(contrast(t.on_accent, t.accent)) + " "
    if contrast(t.muted, t.panel) < 3.0:
        out += "muted/panel " + r2(contrast(t.muted, t.panel)) + " "
    return out
