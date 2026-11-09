"""Colors by role. Three presets share the roles: glass (dark translucent, indigo accent), neon (near black, cyan and
magenta), flat (opaque light). rgba packs r | g << 8 | b << 16 | a << 24; the glass values are the module constants the
widgets use.
"""
from .draw import rgba


@fieldwise_init
struct Theme(Copyable, Movable):
    var panel: UInt32
    var surface: UInt32
    var hover: UInt32
    var accent: UInt32
    var good: UInt32
    var warn: UInt32
    var bad: UInt32
    var text: UInt32
    var muted: UInt32
    var shadow: UInt32


def glass() -> Theme:
    return Theme(rgba(17, 19, 26, 214), rgba(36, 40, 52, 255), rgba(52, 57, 74, 255), rgba(99, 102, 241, 255),
                 rgba(52, 211, 153, 255), rgba(251, 191, 36, 255), rgba(248, 113, 113, 255), rgba(229, 231, 235, 255),
                 rgba(148, 155, 172, 255), rgba(0, 0, 0, 120))


def neon() -> Theme:
    return Theme(rgba(6, 4, 14, 224), rgba(20, 14, 38, 255), rgba(36, 24, 66, 255), rgba(0, 240, 255, 255),
                 rgba(57, 255, 136, 255), rgba(255, 214, 10, 255), rgba(255, 45, 120, 255), rgba(235, 240, 255, 255),
                 rgba(150, 130, 200, 255), rgba(0, 240, 255, 90))


def flat() -> Theme:
    return Theme(rgba(246, 247, 249, 255), rgba(226, 229, 234, 255), rgba(208, 213, 222, 255), rgba(37, 99, 235, 255),
                 rgba(22, 163, 74, 255), rgba(217, 119, 6, 255), rgba(220, 38, 38, 255), rgba(17, 24, 39, 255),
                 rgba(100, 108, 122, 255), rgba(0, 0, 0, 40))


comptime PANEL = glass().panel
comptime SURFACE = glass().surface
comptime HOVER = glass().hover
comptime ACCENT = glass().accent
comptime GOOD = glass().good
comptime WARN = glass().warn
comptime BAD = glass().bad
comptime TEXT = glass().text
comptime MUTED = glass().muted
comptime SHADOW = glass().shadow
