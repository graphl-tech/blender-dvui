# blender-dvui

> [!WARNING]
> This project has to this point been mostly written by AI coding tools,
> and while I plan to personally vet every line, I haven't gotten around to doing so!

Render a [DVUI](https://github.com/david-vanderson/dvui) UI directly into
Blender via a Zig backend that defers draw commands to a small Python
addon. Inspired by
[BlenderImgui](https://github.com/eliemichel/BlenderImgui), but for DVUI
and without exposing UI calls to Python — your UI is written in Zig and
compiled into a shared library.

The repo is a single Zig workspace with two sub-packages, a Python
addon, and a build helper that lets external projects package their own
DVUI app as a Blender addon:

```
backend/        zig pkg: deferred-render dvui Backend (no GL calls of its own)
sample_app/     zig pkg: a minimal dvui app exposing `frame()`
src/lib.zig     integrator: cdylib with the C ABI (mouse + keyboard + render)
addon/          Blender Python addon (ctypes wrapper + bpy.gpu rendering +
                  modal operator forwarding events to DVUI)
build.zig       buildBlenderAddon() helper for external projects
scripts/        test_blender.py for one-shot iterate-and-screenshot runs
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

The bundled sample addon lives at `addon/`. The test scripts put the
repo on `sys.path` so the addon imports as a package without needing to
be installed into Blender's user addons folder:

```bash
zig build && blender --python scripts/test_blender.py
```

When Blender finishes loading:

1. The script invokes `bpy.ops.dvui_sample.start("INVOKE_DEFAULT")`,
   which is a *modal operator* — it converts the largest area to
   `NODE_EDITOR` (the sample's configured space), attaches a draw
   handler, and forwards mouse / wheel / keyboard / text events to
   DVUI.
2. The Node Editor's N-panel gains a `DVUI Sample` tab with
   start/stop buttons (also: `bpy.ops.dvui_sample.stop()`).
3. `bpy.ops.dvui_sample.start()` is automatically invoked from the test
   script ~1.5s after launch.

To drive it manually, start Blender normally and from the Python
console:

```python
import sys; sys.path.insert(0, "/path/to/blender-dvui")
import addon as dvui_addon
dvui_addon.register()
dvui_addon.start()      # modal operator picks up cursor events
# ... interact ...
dvui_addon.stop()
dvui_addon.unregister()
```

### Headless smoke test

```bash
blender --background --python scripts/import_check.py
```

Loads the cdylib, registers/unregisters the addon, and exits. Useful to
catch ctypes-signature drift after editing the C ABI; the wrapper
asserts struct sizes match the Zig side at import time.

### Iterate-and-screenshot loop

```bash
zig build && blender --python scripts/test_blender.py -- --auto-quit
```

After ~4s the script writes `scripts/out/dvui_overlay.png` (using
`bpy.ops.screen.screenshot_area` so popups/splash don't appear) and
quits Blender. Useful while tweaking the UI.

Add `--click` to also drive a synthesized click sweep over the floating
window through the C ABI; the sample app prints `[sample_app] click #N`
when its button registers a press, which is a quick way to confirm the
input pipeline still works after backend / Python changes.

If Blender's splash window blocks the viewport during testing, disable
it once:

```bash
blender --background --python -c \
  "import bpy; bpy.context.preferences.view.show_splash = False; bpy.ops.wm.save_userpref()"
```

## Edit the DVUI app

The sample UI lives in:

```
sample_app/src/app.zig
```

A DVUI app exposes:

```zig
pub fn frame() !void;                  // required
pub fn init(win: *dvui.Window) !void;  // optional, called once after Window.init
pub fn deinit() void;                  // optional, called once before Window.deinit
                                       //  (deinit may also be `!void`)
```

`frame()` is called once per overlay redraw between `Window.begin` and
`Window.end`. `init` / `deinit` run outside any begin/end window pair —
use them for any setup that allocates resources, parses CLI args, or
otherwise can't be done inside a frame. Inside `frame()` you write
normal DVUI code:

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
bpy.ops.dvui_sample.stop()
bpy.ops.dvui_sample.start()
```

> Hot-reload of the cdylib mid-session isn't supported — Python's
> `ctypes.CDLL` keeps the library mapped for the life of the process.
> Restart Blender (or stop, evict from `sys.modules`, re-import) to pick
> up a new build.

For DVUI's full widget vocabulary (layouts, themes, scrolling, etc.),
see <https://david-vanderson.github.io/> and the examples under
`~/opensource/dvui/examples/` if you have it cloned.

## Package an external DVUI app as a Blender addon

`build.zig` exposes a `buildBlenderAddon` helper. From the build.zig of
your own project that already has a DVUI app module:

```zig
// build.zig
const std = @import("std");
const blender_dvui = @import("blender_dvui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,           // required
        .libc = true,
        .freetype = false,
        .@"stb-image" = true,
    });
    const dvui_mod = dvui_dep.module("dvui");

    // Your DVUI app: must expose `pub fn frame() !void` and import dvui.
    const my_app = b.addModule("my_app", .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .imports = &.{ .{ .name = "dvui", .module = dvui_mod } },
    });

    const blender_dep = b.dependency("blender_dvui", .{
        .target = target,
        .optimize = optimize,
    });

    const addon = blender_dvui.buildBlenderAddon(b, .{
        .blender_dvui_dep = blender_dep,
        .dvui_module = dvui_mod,
        .app_module = my_app,
        .app_name = "My Awesome UI",
        .space_type = "VIEW_3D",      // any Blender editor enum
        .target = target,
        .optimize = optimize,
    });
    // Make `zig build` build the addon by default…
    b.getInstallStep().dependOn(addon.step);
    // …or gate it behind a custom step:
    //   const blender_step = b.step("blender-addon", "Build addon");
    //   blender_step.dependOn(addon.step);
}
```

`buildBlenderAddon` returns a `BlenderAddon` whose `.step` is the
top-level step that triggers cdylib + Python file installation, and
`.lib` is the cdylib `Compile` step (handy if you need to add C
sources, link extra system libraries, etc.).

`build.zig.zon` should pull in both `dvui` (with the same hash this
repo uses; see `build.zig.zon`) and `blender_dvui` (path or url):

```zig
.dependencies = .{
    .dvui = .{ .url = "...", .hash = "..." },
    .blender_dvui = .{ .path = "../blender-dvui" },
},
```

`zig build` then writes a self-contained addon directory:

```
zig-out/
  blender_addon/
    my_awesome_ui/
      __init__.py        (templated for app_name / slug / space_type)
      dvui_native.py     (verbatim copy)
      overlay.py         (verbatim copy)
      libmy_awesome_ui_dvui.so
```

Drop that directory into Blender's `addons/` folder, then enable
"My Awesome UI" in *Edit > Preferences > Add-ons*. The N-panel of the
configured editor will gain a tab labeled with `app_name` and a
start/stop button. `bpy.ops.<slug>.start()` / `<slug>.stop()` are the
operator names.

> **Note: there is no truly new editor type.** Blender's Editor-Type
> dropdown is C-registered and `bpy.types.Space` is not subclassable
> from Python, so any Python addon — this one included — has to host
> its UI inside an existing Space (`VIEW_3D`, `IMAGE_EDITOR`, …) via a
> `draw_handler_add` POST_PIXEL hook plus a modal operator for
> input. `space_type` selects which one.

### Run a built addon without installing

Blender will pick up addons from any `<scripts>/addons/<name>/` layout
referenced via `BLENDER_USER_SCRIPTS`. If you set
`install_root = "scripts/addons"` in the helper, the build output is
already in that shape:

```bash
zig build blender-addon

# Tell Blender where to find addons, enable for this session, run it:
BLENDER_USER_SCRIPTS=$PWD/zig-out/scripts \
    blender --addons my_awesome_ui

# Auto-start in the existing 3D viewport (or whichever space_type
# was passed to buildBlenderAddon):
BLENDER_USER_SCRIPTS=$PWD/zig-out/scripts \
    blender --addons my_awesome_ui \
    --python-expr "
import bpy
def _start():
    win = bpy.context.window_manager.windows[0]
    area = next(a for a in win.screen.areas if a.type == 'VIEW_3D')
    region = next(r for r in area.regions if r.type == 'WINDOW')
    with bpy.context.temp_override(window=win, area=area, region=region):
        bpy.ops.my_awesome_ui.start('INVOKE_DEFAULT')
bpy.app.timers.register(_start, first_interval=1.0)
"
```

`bpy.context.preferences.addons.keys()` only lists *persistently*
enabled addons (saved in user prefs); `--addons` enables for the
current session only. Confirm enable-state with
`addon_utils.check('my_awesome_ui')` returning `(True, True)`. To make
the enable persist across launches:

```bash
blender -b --python-expr "import bpy; \
    bpy.ops.preferences.addon_enable(module='my_awesome_ui'); \
    bpy.ops.wm.save_userpref()"
```

The `space_type` parameter is one of the standard Blender editor enums
(`"VIEW_3D"`, `"IMAGE_EDITOR"`, `"NODE_EDITOR"`, `"GRAPH_EDITOR"`,
`"PROPERTIES"`, `"INFO"`, `"TEXT_EDITOR"`, etc.) — pick whichever
Editor you'd like the overlay to take over. Blender doesn't allow
registering brand-new editor types from Python, but configuring an
existing area to host a DVUI overlay is the next-best thing.

## Input handling

The bundled `addon/overlay.py` defines a *modal operator* per app. Once
started, it forwards every Blender event to DVUI:

| Blender event              | DVUI call                                                  |
|----------------------------|------------------------------------------------------------|
| `MOUSEMOVE`                | `dvui_event_mouse_motion(x, y)` (top-left origin)         |
| `LEFTMOUSE` / `RIGHT` / `MIDDLEMOUSE` | `dvui_event_mouse_button(button, pressed)`      |
| `WHEELUP/DOWNMOUSE`        | `dvui_event_mouse_wheel(0, ±dvui.scroll_speed)` (default 80) |
| Special keys (TAB, RET, BACK_SPACE, arrows, PAGE_UP/DOWN, HOME, END, INSERT, SPACE, modifiers, A–Z) | `dvui_event_key(code, pressed, mods)` |
| `event.unicode` on PRESS   | `dvui_event_text(utf8 bytes)`                              |
| `bpy.app.handlers.load_pre` | `dvui_event_app_quit` then `dvui_event_window_close`      |
| `Addon.unregister`          | `dvui_event_app_quit` then `dvui_event_window_close`      |

Each event function returns whether DVUI consumed it; when it did, the
modal operator returns `RUNNING_MODAL` (event swallowed); otherwise it
passes through so Blender's regular handling still applies. The Y axis
is flipped inside the operator so DVUI sees top-left origin pixel
coordinates.

The C ABI also exposes everything else DVUI accepts, callable directly
from Python via the loaded library handle on `session.native.lib` (or
through helper methods on `DvuiSession`):

| C function                             | Python helper                  | DVUI API                          |
|----------------------------------------|--------------------------------|-----------------------------------|
| `dvui_event_text_select(start, end)`   | `session.text_select(s, e)`    | `Window.addEventTextSelect`       |
| `dvui_event_focus(x, y, button)`       | `session.focus_at(x, y, b)`    | `Window.addEventFocus`            |
| `dvui_event_touch_motion(finger, x, y, dx, dy)` | `session.touch_motion(...)` | `Window.addEventTouchMotion`     |
| `dvui_event_window_close(ctx)`         | (auto on `session.stop`)       | `Window.addEventWindow(.close)`   |
| `dvui_event_app_quit(ctx)`             | `session.app_quit()`           | `Window.addEventApp(.quit)`       |
| `dvui_cursor_over_floating(ctx)`       | `lib.dvui_cursor_over_floating(ctx)` | `Window.cursorRequestedFloating` |

Blender exposes no native source for touch / pen-tip events at the
modal-operator level, so `dvui_event_touch_motion` is wired only as a
convenience entry point — call it from your own code if you obtain
touch state another way.

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
  uses an ortho `ProjMtx` mapping DVUI's top-left pixel space to clip
  space; fragment is `frag = v_col * texture(tex, v_uv)`)
- A 1×1 white `GPUTexture` is bound when DVUI emits `texture_id == 0`
- Texture creates/destroys are drained each frame; pixel data goes
  through a one-time `ctypes.string_at` -> `Buffer("FLOAT", ...)`
  conversion (current Blender's `GPUTexture` constructor only accepts
  float buffers)
- Scissor rect from each `DrawCmd` is mapped from DVUI's top-left
  origin to GL's bottom-left origin

`overlay.make_addon(app_name, space_type, slug=, lib_basename=)` is the
factory that produces the per-app `Operator` / `Panel` classes; the
auto-generated addons from `buildBlenderAddon` call it from their
templated `__init__.py`.

## Architecture notes

- DVUI's `Backend` interface is duck-typed; we implement the methods on
  a plain struct and pass `dvui.Backend.init(&self)` to `Window.init`
- The `dvui` dependency is taken with `.backend = .custom` so the bare
  `dvui` module is exposed; the root `build.zig` does `linkBackend`
  manually (`backend_mod.addImport("dvui", dvui_mod); dvui_mod.addImport("backend", backend_mod);`)
- Premultiplied alpha all the way through — `Color.PMA` is what DVUI
  hands us, Blender's `gpu.state.blend_set("ALPHA_PREMULT")` matches
- For the data-flow diagram, struct layouts, and the rationale behind
  the deferred-render split see [ARCHITECTURE.md](ARCHITECTURE.md)

## Limitations

* **No new editor type.** `bpy.types.Space` is C-registered and cannot
  be subclassed from Python; the addon hosts dvui inside an existing
  Space (`VIEW_3D`, `NODE_EDITOR`, `IMAGE_EDITOR`, …) selected by
  `space_type`. In `NODE_EDITOR` we register a custom `NodeTree`
  subclass so the area is at least recognizable in the tree-type
  dropdown.
* **Cdylib is not hot-reloadable.** Python's `ctypes.CDLL` keeps the
  `.so` mapped for the life of the Blender process. Restart Blender
  after `zig build`.
* **One DVUI session per addon, one area per session.** The modal picks
  the first matching area; multi-viewport setups only render in one of
  them.
* **Linux-tested only.** ctypes loader picks the right `dylib`/`dll`
  suffix for macOS/Windows but nothing else has been exercised.
* **Cdylib only — no staticlib path.**

## Missing DVUI backend features

| DVUI API                       | Status                                        |
|--------------------------------|-----------------------------------------------|
| `textureCreateTarget`          | stub returns `error.TextureCreate`            |
| `textureClearTarget`           | no-op                                         |
| `textureReadTarget`            | stub returns `error.TextureRead`              |
| `textureFromTarget` / `textureFromTargetTemp` | stub returns `error.NotImplemented` |
| `textureDestroyTarget`         | no-op                                         |
| `renderTarget`                 | no-op (rendering always goes to Blender's framebuffer) |
| `textureUpdateSubRect`         | not exposed                                   |
| AccessKit                      | disabled (`.accesskit = .off`)                |
| FreeType font rendering        | disabled — uses bundled `stb_truetype`        |
| `tiny-file-dialogs`            | disabled — use `dvui.dialogNativeFile*` paths through Blender's own dialogs instead |
| `tree-sitter`                  | disabled                                      |

Widgets that rely on render-target textures (`dvui.Picture`, anything
that does an offscreen pass) won't work until those backend hooks are
implemented.
