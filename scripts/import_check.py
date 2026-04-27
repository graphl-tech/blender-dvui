"""Headless import sanity check: imports the addon, registers it, then
exits. Use to quickly catch ctypes/signature/syntax issues."""

import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
os.environ.setdefault(
    "BLENDER_DVUI_LIB",
    str(REPO / "zig-out" / "lib" / "libblender_dvui.so"),
)

import bpy  # noqa: E402,F401
from addon import overlay  # noqa: E402

overlay.register()
print("[ok] addon registered")
overlay.unregister()
print("[ok] addon unregistered")
