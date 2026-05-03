bl_info = {
    "name": "DVUI Sample",
    "author": "blender-dvui",
    "version": (0, 0, 1),
    "blender": (4, 0, 0),
    "location": "Node Editor > Sidebar > DVUI Sample",
    "description": "DVUI rendered into Blender via a Zig backend",
    "category": "Node",
}

from . import overlay


_addon = None


def register():
    global _addon
    _addon = overlay.make_addon(
        app_name="DVUI Sample",
        # Node Editor avoids the 3D viewport's gizmo / click-drag
        # modals that fight with dvui's drag tracking, and gets a
        # registered tree-type entry in the editor's dropdown.
        space_type="NODE_EDITOR",
        slug="dvui_sample",
        lib_basename="libblender_dvui",
    )
    _addon.register()


def unregister():
    global _addon
    if _addon is not None:
        _addon.unregister()
        _addon = None


# Convenience for ad-hoc scripting.
def start():
    if _addon is not None:
        _addon.start()


def stop():
    if _addon is not None:
        _addon.stop()
