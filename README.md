# blender-dvui

Render a [DVUI](https://github.com/david-vanderson/dvui) UI directly into
Blender's 3D viewport via a Zig backend that defers draw commands to a
small Python addon. Inspired by
[BlenderImgui](https://github.com/eliemichel/BlenderImgui), but for DVUI
and without exposing UI calls to Python — your UI is written in Zig and
compiled into a shared library.

The repo is a single Zig workspace with two sub-packages and a Python
addon that ties them together:

```
backend/      zig pkg: deferred-render dvui Backend (no GL calls of its own)
sample_app/   zig pkg: a minimal dvui app exposing `frame()`
src/lib.zig   integrator: builds a cdylib with the C ABI Python uses
addon/        Blender Python addon (ctypes + bpy.gpu rendering)
scripts/      test_blender.py for one-shot iterate-and-screenshot runs
```

The Zig side records `(vertices, indices, draw_commands, textures)` per
frame; the Python side pulls them out and submits them to Blender's
`gpu` module each redraw. No raw OpenGL is called from Zig — Blender owns
the GL context.

## Prerequisites

- Zig 0.15.2+
- Blender 4.x or 5.x (tested on 5.1.1)
- Linux (tested). macOS/Windows not yet exercised; the ctypes loader
  picks the right `dylib`/`dll` suffix but nothing else has been verified

## Build

```bash
zig build
```

This produces `zig-out/lib/libblender_dvui.so` (the addon resolves it
via `BLENDER_DVUI_LIB` env var or by falling back to that path).

## Run inside Blender

The addon lives at `addon/` and isn't installed into Blender's user
addons directory — instead the test script puts the repo on `sys.path`
and imports it. Open Blender with the script:

```bash
zig build && blender --python scripts/test_blender.py
```

Then in Blender:

1. The script auto-runs `bpy.ops.dvui.start()` after ~1.5s, attaching a
   `SpaceView3D` draw handler that runs your DVUI app each frame and
   draws the result into the viewport.
2. To stop: `bpy.ops.dvui.stop()` (also unregisters automatically when
   the addon does, e.g. when Blender quits).

If you'd rather drive it manually, start Blender normally and from the
Python console:

```python
import sys; sys.path.insert(0, "/path/to/blender-dvui")
from addon import overlay
overlay.register()
overlay.start()      # = bpy.ops.dvui.start()
# ... interact ...
overlay.stop()
overlay.unregister()
```

### Headless smoke test

```bash
blender --background --python scripts/import_check.py
```

Loads the cdylib, registers/unregisters the addon, and exits. Useful to
catch ctypes signature drift after editing the C ABI.

### Iterate-and-screenshot loop

```bash
zig build && blender --python scripts/test_blender.py -- --auto-quit
```

After ~4s the script writes `scripts/out/dvui_overlay.png` (using
`bpy.ops.screen.screenshot_area` so popups/splash don't appear) and
quits Blender. Useful while tweaking the UI.

If Blender's splash window blocks the viewport during testing, disable
it once:

```bash
blender --background --python -c \
  "import bpy; bpy.context.preferences.view.show_splash = False; bpy.ops.wm.save_userpref()"
```

## Edit the DVUI app

The sample UI is one file:

```
sample_app/src/app.zig
```

It exports a single `pub fn frame() !void`, which is called once per
frame between `Window.begin` / `Window.end` by the integrator. Inside
`frame()` you write normal DVUI code:

```zig
pub fn frame() !void {
    var float = dvui.floatingWindow(@src(), .{}, .{});
    defer float.deinit();
    float.dragAreaSet(dvui.windowHeader("Hello", "", null));

    if (dvui.button(@src(), "Click me", .{}, .{})) {
        // handle click
    }
}
```

After editing, rebuild and restart the running session:

```bash
zig build
# in Blender:
bpy.ops.dvui.stop()
bpy.ops.dvui.start()
```

> Hot-reload of the cdylib mid-session isn't supported — Python's
> `ctypes.CDLL` keeps the library mapped for the life of the process.
> Restart Blender (or `dvui.stop` then re-import the addon module after
> evicting it from `sys.modules`) to pick up a new build.

For DVUI's full widget vocabulary (layouts, themes, scrolling, etc.),
see <https://david-vanderson.github.io/> and the examples under
`~/opensource/dvui/examples/` if you have it cloned.

## Edit the backend

`backend/src/backend.zig` implements DVUI's `Backend` interface in a
deferred style:

- `drawClippedTriangles` appends to in-memory `vertices`/`indices`/
  `commands` lists (indices are rewritten to be global to the merged
  vertex buffer)
- `textureCreate` allocates a CPU-side RGBA buffer, hands DVUI a
  monotonic id as the opaque texture pointer, and queues the id for
  Python to upload as a `gpu.types.GPUTexture`
- `textureDestroy` queues the id for Python to drop its `GPUTexture`

If you change the layout of `Vertex` / `DrawCmd` / `TextureInfo`, also
update the matching `ctypes.Structure`s in `addon/dvui_native.py`. The
module asserts struct sizes against the Zig-side `dvui_*_size` exports
at import time, so a mismatch fails loudly.

## Edit the addon / rendering

`addon/overlay.py` owns the per-frame render loop on the Python side:

- One `gpu.types.GPUShader` built via `GPUShaderCreateInfo` (vertex
  uses an ortho `ProjMtx` mapping dvui's top-left pixel space to clip
  space; fragment is `frag = v_col * texture(tex, v_uv)`)
- A 1×1 white `GPUTexture` is bound when DVUI emits `texture_id == 0`
- Texture creates/destroys are drained each frame; pixel data goes
  through a one-time `ctypes.string_at` -> `Buffer("FLOAT", ...)`
  conversion (current Blender's `GPUTexture` constructor only accepts
  float buffers)
- Scissor rect from each `DrawCmd` is mapped from dvui's top-left
  origin to GL's bottom-left origin

## Input events (not wired yet)

The C ABI exposes `dvui_event_mouse_motion`, `dvui_event_mouse_button`,
`dvui_event_mouse_wheel`, and `dvui_event_text`, but the addon currently
registers a draw handler only — it doesn't forward Blender events to
DVUI yet. Adding it means promoting `dvui.start` to a modal operator
that calls those functions in its `modal()` callback (see BlenderImgui's
`ImguiBasedOperator` for the same pattern).

## Architecture notes

- DVUI's `Backend` interface is duck-typed; we implement the methods on
  a plain struct and pass `dvui.Backend.init(&self)` to `Window.init`
- The `dvui` dependency is taken with `.backend = .custom` so the bare
  `dvui` module is exposed; the root `build.zig` does `linkBackend`
  manually (`backend_mod.addImport("dvui", dvui_mod); dvui_mod.addImport("backend", backend_mod);`)
- Premultiplied alpha all the way through — `Color.PMA` is what DVUI
  hands us, blender's `gpu.state.blend_set("ALPHA_PREMULT")` matches
- A render-target texture path (`textureCreateTarget` etc.) is stubbed
  out with `error.NotImplemented` / `error.TextureCreate`; widgets that
  rely on it (e.g. `dvui.Picture`) won't work until that's added
