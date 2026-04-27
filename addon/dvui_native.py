"""ctypes wrapper around a DVUI shared library.

A single repo can host multiple DVUI apps, each compiled to its own
shared library (e.g. `libblender_dvui.so`, `libmyapp_dvui.so`). Use
:func:`load` to bind one of them; it returns a :class:`Native` object
that owns the loaded library plus its struct types.
"""

from __future__ import annotations

import ctypes as C
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


class Vertex(C.Structure):
    _fields_ = [
        ("x", C.c_float),
        ("y", C.c_float),
        ("u", C.c_float),
        ("v", C.c_float),
        ("r", C.c_uint8),
        ("g", C.c_uint8),
        ("b", C.c_uint8),
        ("a", C.c_uint8),
    ]


class DrawCmd(C.Structure):
    _fields_ = [
        ("texture_id", C.c_uint32),
        ("vtx_offset", C.c_uint32),
        ("idx_offset", C.c_uint32),
        ("idx_count", C.c_uint32),
        ("has_clip", C.c_uint32),
        ("clip_x", C.c_int32),
        ("clip_y", C.c_int32),
        ("clip_w", C.c_int32),
        ("clip_h", C.c_int32),
    ]


class TextureInfo(C.Structure):
    _fields_ = [
        ("id", C.c_uint32),
        ("width", C.c_uint32),
        ("height", C.c_uint32),
        ("interpolation", C.c_uint32),
        ("format", C.c_uint32),
        ("pixels", C.POINTER(C.c_uint8)),
    ]


# Stable integer key codes (must match KeyCode in src/lib.zig).
KEY_NONE = 0
KEY_BACKSPACE = 1
KEY_DELETE = 2
KEY_ENTER = 3
KEY_ESCAPE = 4
KEY_TAB = 5
KEY_HOME = 6
KEY_END = 7
KEY_PAGE_UP = 8
KEY_PAGE_DOWN = 9
KEY_LEFT = 10
KEY_RIGHT = 11
KEY_UP = 12
KEY_DOWN = 13
KEY_INSERT = 14
KEY_SPACE = 15
KEY_LEFT_SHIFT = 20
KEY_RIGHT_SHIFT = 21
KEY_LEFT_CTRL = 22
KEY_RIGHT_CTRL = 23
KEY_LEFT_ALT = 24
KEY_RIGHT_ALT = 25
KEY_A_BASE = 100  # 'A' + ord(c) - ord('A') for letters

MOD_SHIFT = 1 << 0
MOD_CTRL = 1 << 1
MOD_ALT = 1 << 2
MOD_CMD = 1 << 3

# Map Blender event.type for special keys.
BLENDER_KEY_TO_CODE = {
    "BACK_SPACE": KEY_BACKSPACE,
    "DEL": KEY_DELETE,
    "RET": KEY_ENTER,
    "NUMPAD_ENTER": KEY_ENTER,
    "ESC": KEY_ESCAPE,
    "TAB": KEY_TAB,
    "HOME": KEY_HOME,
    "END": KEY_END,
    "PAGE_UP": KEY_PAGE_UP,
    "PAGE_DOWN": KEY_PAGE_DOWN,
    "LEFT_ARROW": KEY_LEFT,
    "RIGHT_ARROW": KEY_RIGHT,
    "UP_ARROW": KEY_UP,
    "DOWN_ARROW": KEY_DOWN,
    "INSERT": KEY_INSERT,
    "SPACE": KEY_SPACE,
    "LEFT_SHIFT": KEY_LEFT_SHIFT,
    "RIGHT_SHIFT": KEY_RIGHT_SHIFT,
    "LEFT_CTRL": KEY_LEFT_CTRL,
    "RIGHT_CTRL": KEY_RIGHT_CTRL,
    "LEFT_ALT": KEY_LEFT_ALT,
    "RIGHT_ALT": KEY_RIGHT_ALT,
}
# Letter keys A..Z map to consecutive codes from KEY_A_BASE.
for _i, _ch in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):
    BLENDER_KEY_TO_CODE[_ch] = KEY_A_BASE + _i
del _i, _ch


def blender_event_mods(event) -> int:
    m = 0
    if event.shift:
        m |= MOD_SHIFT
    if event.ctrl:
        m |= MOD_CTRL
    if event.alt:
        m |= MOD_ALT
    if event.oskey:
        m |= MOD_CMD
    return m


@dataclass
class Native:
    lib: C.CDLL
    Vertex: type = Vertex
    DrawCmd: type = DrawCmd
    TextureInfo: type = TextureInfo


def _candidate_paths(basename: str) -> list[Path]:
    here = Path(__file__).resolve().parent
    suffix = {"linux": "so", "darwin": "dylib", "win32": "dll"}.get(sys.platform, "so")

    out: list[Path] = []
    env_key = "BLENDER_DVUI_LIB"
    if env_key in os.environ:
        out.append(Path(os.environ[env_key]))
    out.append(here / f"{basename}.{suffix}")
    out.append(here.parent / "zig-out" / "lib" / f"{basename}.{suffix}")
    return out


def load(basename: str = "libblender_dvui") -> Native:
    last: Path | None = None
    for p in _candidate_paths(basename):
        if p.exists():
            lib = C.CDLL(str(p))
            _bind(lib)
            return Native(lib=lib)
        last = p
    raise OSError(f"could not find {basename} shared library; tried last: {last}")


def _bind(lib: C.CDLL) -> None:
    def s(name: str, argtypes: list, restype) -> None:
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype

    s("dvui_create", [C.c_uint32, C.c_uint32], C.c_void_p)
    s("dvui_destroy", [C.c_void_p], None)
    s("dvui_resize", [C.c_void_p, C.c_uint32, C.c_uint32], None)

    s("dvui_event_mouse_motion", [C.c_void_p, C.c_float, C.c_float], None)
    s("dvui_event_mouse_button", [C.c_void_p, C.c_int, C.c_int], C.c_int)
    s("dvui_event_mouse_wheel", [C.c_void_p, C.c_float, C.c_float], C.c_int)
    s("dvui_event_text", [C.c_void_p, C.c_char_p, C.c_uint32], C.c_int)
    s("dvui_event_text_select", [C.c_void_p, C.c_uint32, C.c_uint32], C.c_int)
    s("dvui_event_key", [C.c_void_p, C.c_int, C.c_int, C.c_int], C.c_int)
    s("dvui_event_focus", [C.c_void_p, C.c_float, C.c_float, C.c_int], C.c_int)
    s(
        "dvui_event_touch_motion",
        [C.c_void_p, C.c_int, C.c_float, C.c_float, C.c_float, C.c_float],
        C.c_int,
    )
    s("dvui_event_window_close", [C.c_void_p], None)
    s("dvui_event_app_quit", [C.c_void_p], None)
    s("dvui_cursor_over_floating", [C.c_void_p], C.c_int)
    s("dvui_text_input_active", [C.c_void_p], C.c_int)

    s("dvui_frame", [C.c_void_p], C.c_int)

    s("dvui_vertex_size", [], C.c_uint32)
    s("dvui_command_size", [], C.c_uint32)
    s("dvui_texture_info_size", [], C.c_uint32)

    s("dvui_vertices", [C.c_void_p, C.POINTER(C.c_uint32)], C.POINTER(Vertex))
    s("dvui_indices", [C.c_void_p, C.POINTER(C.c_uint32)], C.POINTER(C.c_uint32))
    s("dvui_commands", [C.c_void_p, C.POINTER(C.c_uint32)], C.POINTER(DrawCmd))

    s(
        "dvui_drain_texture_creates",
        [C.c_void_p, C.POINTER(TextureInfo), C.c_uint32],
        C.c_uint32,
    )
    s(
        "dvui_drain_texture_destroys",
        [C.c_void_p, C.POINTER(C.c_uint32), C.c_uint32],
        C.c_uint32,
    )

    assert C.sizeof(Vertex) == lib.dvui_vertex_size(), (
        f"Vertex size mismatch: py={C.sizeof(Vertex)} zig={lib.dvui_vertex_size()}"
    )
    assert C.sizeof(DrawCmd) == lib.dvui_command_size(), (
        f"DrawCmd size mismatch: py={C.sizeof(DrawCmd)} zig={lib.dvui_command_size()}"
    )
    assert C.sizeof(TextureInfo) == lib.dvui_texture_info_size(), (
        f"TextureInfo size mismatch: py={C.sizeof(TextureInfo)} zig={lib.dvui_texture_info_size()}"
    )
