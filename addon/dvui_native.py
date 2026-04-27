"""ctypes wrapper around libblender_dvui.so.

The shared library is loaded from the same directory as this module, or
from the path given by the ``BLENDER_DVUI_LIB`` env var.
"""

from __future__ import annotations

import ctypes as C
import os
import sys
from pathlib import Path


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


def _candidate_paths() -> list[Path]:
    here = Path(__file__).resolve().parent
    suffix = {
        "linux": "so",
        "darwin": "dylib",
        "win32": "dll",
    }.get(sys.platform, "so")

    out = []
    if "BLENDER_DVUI_LIB" in os.environ:
        out.append(Path(os.environ["BLENDER_DVUI_LIB"]))
    # alongside this file
    out.append(here / f"libblender_dvui.{suffix}")
    # repo zig-out (development)
    out.append(here.parent / "zig-out" / "lib" / f"libblender_dvui.{suffix}")
    return out


def _load() -> C.CDLL:
    last_err = None
    for p in _candidate_paths():
        if p.exists():
            return C.CDLL(str(p))
        last_err = p
    raise OSError(f"could not locate libblender_dvui shared library; tried last: {last_err}")


lib = _load()


# Bind signatures.
lib.dvui_create.argtypes = [C.c_uint32, C.c_uint32]
lib.dvui_create.restype = C.c_void_p

lib.dvui_destroy.argtypes = [C.c_void_p]
lib.dvui_destroy.restype = None

lib.dvui_resize.argtypes = [C.c_void_p, C.c_uint32, C.c_uint32]
lib.dvui_resize.restype = None

lib.dvui_event_mouse_motion.argtypes = [C.c_void_p, C.c_float, C.c_float]
lib.dvui_event_mouse_motion.restype = None

lib.dvui_event_mouse_button.argtypes = [C.c_void_p, C.c_int, C.c_int]
lib.dvui_event_mouse_button.restype = None

lib.dvui_event_mouse_wheel.argtypes = [C.c_void_p, C.c_float, C.c_float]
lib.dvui_event_mouse_wheel.restype = None

lib.dvui_event_text.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32]
lib.dvui_event_text.restype = None

lib.dvui_frame.argtypes = [C.c_void_p]
lib.dvui_frame.restype = C.c_int

lib.dvui_vertex_size.argtypes = []
lib.dvui_vertex_size.restype = C.c_uint32

lib.dvui_command_size.argtypes = []
lib.dvui_command_size.restype = C.c_uint32

lib.dvui_texture_info_size.argtypes = []
lib.dvui_texture_info_size.restype = C.c_uint32

lib.dvui_vertices.argtypes = [C.c_void_p, C.POINTER(C.c_uint32)]
lib.dvui_vertices.restype = C.POINTER(Vertex)

lib.dvui_indices.argtypes = [C.c_void_p, C.POINTER(C.c_uint32)]
lib.dvui_indices.restype = C.POINTER(C.c_uint32)

lib.dvui_commands.argtypes = [C.c_void_p, C.POINTER(C.c_uint32)]
lib.dvui_commands.restype = C.POINTER(DrawCmd)

lib.dvui_drain_texture_creates.argtypes = [
    C.c_void_p,
    C.POINTER(TextureInfo),
    C.c_uint32,
]
lib.dvui_drain_texture_creates.restype = C.c_uint32

lib.dvui_drain_texture_destroys.argtypes = [
    C.c_void_p,
    C.POINTER(C.c_uint32),
    C.c_uint32,
]
lib.dvui_drain_texture_destroys.restype = C.c_uint32


# Sanity-check struct sizes match the Zig side.
assert C.sizeof(Vertex) == lib.dvui_vertex_size(), (
    f"Vertex size mismatch: py={C.sizeof(Vertex)} zig={lib.dvui_vertex_size()}"
)
assert C.sizeof(DrawCmd) == lib.dvui_command_size(), (
    f"DrawCmd size mismatch: py={C.sizeof(DrawCmd)} zig={lib.dvui_command_size()}"
)
assert C.sizeof(TextureInfo) == lib.dvui_texture_info_size(), (
    f"TextureInfo size mismatch: py={C.sizeof(TextureInfo)} zig={lib.dvui_texture_info_size()}"
)
