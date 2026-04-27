"""Run inside Blender:

    blender --python scripts/test_blender.py

Loads the dvui addon, starts it, and after a short delay saves a
screenshot of the 3D viewport so we can iterate without a human in the
loop. Press Q to quit, or pass `--background` to run headless (note: GPU
overlays usually do not render headless).
"""

import os
import sys
from pathlib import Path

import bpy

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
os.environ.setdefault(
    "BLENDER_DVUI_LIB",
    str(REPO / "zig-out" / "lib" / "libblender_dvui.so"),
)

import addon as dvui_addon  # noqa: E402

dvui_addon.register()


def _redraw_all():
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            area.tag_redraw()
    try:
        bpy.ops.wm.redraw_timer(type="DRAW_WIN", iterations=2)
    except Exception as e:
        print(f"[test] redraw_timer failed: {e}")


def _start_dvui():
    print("[test] starting dvui...")
    # Override context to a VIEW_3D area so the modal operator sees one.
    win = bpy.context.window_manager.windows[0]
    area = next((a for a in win.screen.areas if a.type == "VIEW_3D"), None)
    if area is None:
        print("[test] no VIEW_3D area found")
        return None
    region = next((r for r in area.regions if r.type == "WINDOW"), None)
    try:
        with bpy.context.temp_override(window=win, area=area, region=region):
            bpy.ops.dvui_sample.start("INVOKE_DEFAULT")
    except Exception as e:
        print(f"[test] dvui_sample.start failed: {e}")
        return None
    _redraw_all()
    return None


def _inject_click():
    """Drive the C ABI directly to simulate a click on the 'Click me' button.

    This bypasses Blender's event loop so we can verify the C ABI + dvui
    input plumbing in a one-shot screenshot test.
    """
    session = dvui_addon._addon.session if dvui_addon._addon else None
    if session is None or not session.running:
        print("[test] dvui session not running, can't inject")
        return None
    lib = session.native.lib
    # Sweep a few likely Y positions so at least one lands on the button
    # regardless of the exact widget layout (DVUI lays out top-down).
    cx = 1040.0
    for cy in (570, 590, 610, 630, 650):
        lib.dvui_event_mouse_motion(session.ctx, cx, float(cy))
        lib.dvui_event_mouse_button(session.ctx, 0, 1)
        lib.dvui_event_mouse_button(session.ctx, 0, 0)
    print(f"[test] injected click sweep at x={cx}")
    _redraw_all()
    return None


def _take_screenshot():
    _redraw_all()
    out = REPO / "scripts" / "out"
    out.mkdir(exist_ok=True)
    target = out / "dvui_overlay.png"
    print(f"[test] saving screenshot -> {target}")

    # Find a 3D area to override the operator context with.
    target_area = None
    target_region = None
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == "VIEW_3D":
                target_area = area
                for region in area.regions:
                    if region.type == "WINDOW":
                        target_region = region
                        break
                break
        if target_area:
            break

    if target_area is None:
        print("[test] no 3D viewport found")
        return None

    try:
        with bpy.context.temp_override(area=target_area, region=target_region):
            bpy.ops.screen.screenshot_area(
                filepath=str(target), check_existing=False
            )
    except Exception as e:
        print(f"[test] screenshot_area failed: {e}; falling back to screen.screenshot")
        try:
            bpy.ops.screen.screenshot(filepath=str(target), check_existing=False)
        except Exception as e2:
            print(f"[test] screen.screenshot failed: {e2}")
    return None


# Schedule via timers so they fire after Blender's UI is up.
bpy.app.timers.register(_start_dvui, first_interval=1.5)
bpy.app.timers.register(_redraw_all, first_interval=3.0)

if "--click" in sys.argv:
    bpy.app.timers.register(_inject_click, first_interval=3.5)
    bpy.app.timers.register(_inject_click, first_interval=4.0)
    bpy.app.timers.register(_inject_click, first_interval=4.5)
    screenshot_at = 5.0
    quit_at = 6.5
else:
    screenshot_at = 4.0
    quit_at = 5.5

bpy.app.timers.register(_take_screenshot, first_interval=screenshot_at)


# Auto-quit when running with `--auto-quit` so CI-like loops can iterate.
if "--auto-quit" in sys.argv:
    def _quit():
        print("[test] quitting blender")
        bpy.ops.wm.quit_blender()
        return None

    bpy.app.timers.register(_quit, first_interval=quit_at)
