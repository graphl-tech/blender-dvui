bl_info = {
    "name": "DVUI Examples",
    "author": "blender-dvui",
    "version": (0, 0, 1),
    "blender": (4, 0, 0),
    "location": "View3D > Sidebar",
    "description": "DVUI rendered into Blender via a Zig backend",
    "category": "3D view",
}

from . import dvui_native  # noqa: F401
from . import overlay


def register():
    overlay.register()


def unregister():
    overlay.unregister()
