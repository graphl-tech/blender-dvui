"""Per-app DVUI overlay infrastructure.

Setting the env var ``BLENDER_DVUI_EVENT_LOG=/path/to/log`` causes the
modal operator to write every Blender event it processes to that file
(type, value, mouse_x/y, region-relative coords, modifier state, and
whether dvui consumed it). Useful to debug drag/click problems where
the events flowing through the bridge differ from expectation.

Use :func:`make_addon` to build a self-contained set of Blender classes
(operators + panel) bound to a particular DVUI app and target editor
(space) type. The same module backs both the bundled sample app and the
addons produced by ``buildBlenderAddon``.

Each app gets:

* A modal operator ``<slug>.start`` that sets up rendering and forwards
  Blender events to DVUI.
* A stop operator ``<slug>.stop``.
* A sidebar panel in the chosen editor with start / stop buttons and a
  small status readout.
* A draw handler that renders DVUI commands using Blender's ``gpu``
  module.

The DVUI rendering is deferred: each frame the C library populates
vertex / index / command buffers, and the draw handler dispatches them
through a custom ``GPUShader``.
"""

from __future__ import annotations

import ctypes as C
import os
import re
from dataclasses import dataclass, field
from typing import Optional

import bpy
import gpu
import numpy as np
from bpy.types import Operator, Panel
from mathutils import Matrix

from . import dvui_native


# Numpy structured dtype matching the layout of `Vertex` in
# backend/src/backend.zig (8 bytes pos, 8 bytes uv, 4 bytes RGBA).
_VTX_DTYPE = np.dtype([
    ("x", "<f4"), ("y", "<f4"),
    ("u", "<f4"), ("v", "<f4"),
    ("r", "u1"), ("g", "u1"), ("b", "u1"), ("a", "u1"),
])


_EVENT_LOG_PATH = os.environ.get("BLENDER_DVUI_EVENT_LOG")
_event_log_file = None


def _event_log(line: str) -> None:
    global _event_log_file
    if _EVENT_LOG_PATH is None:
        return
    if _event_log_file is None:
        try:
            _event_log_file = open(_EVENT_LOG_PATH, "w", buffering=1)
        except Exception:
            return
    try:
        _event_log_file.write(line + "\n")
    except Exception:
        pass


VERTEX_SOURCE = """
void main() {
    v_uv = uv;
    v_col = col;
    gl_Position = ProjMtx * vec4(pos, 0.0, 1.0);
}
"""

FRAGMENT_SOURCE = """
// DVUI hands us premultiplied-alpha sRGB byte colors and an sRGB
// texture. Blender's draw_handler framebuffer however expects scene-
// linear, so writing the sRGB values directly produces washed-out
// (too-bright) output. Convert to linear before writing. Mirrors the
// same conversion BlenderImgui uses for the same reason.
vec4 srgb_to_linear(vec4 c) {
    vec3 lo = c.rgb / 12.92;
    vec3 hi = pow((c.rgb + 0.055) / 1.055, vec3(2.4));
    vec3 cutoff = step(c.rgb, vec3(0.04045));
    return vec4(mix(hi, lo, cutoff), c.a);
}

void main() {
    vec4 c = v_col * texture(tex, v_uv);
    frag = srgb_to_linear(c);
}
"""


_shader_cache: dict[int, gpu.types.GPUShader] = {}
_vbo_format_cache: dict[int, gpu.types.GPUVertFormat] = {}
_white_cache: dict[int, gpu.types.GPUTexture] = {}


def _get_shader() -> gpu.types.GPUShader:
    key = 0
    cached = _shader_cache.get(key)
    if cached is not None:
        return cached
    info = gpu.types.GPUShaderCreateInfo()
    info.push_constant("MAT4", "ProjMtx")
    info.sampler(0, "FLOAT_2D", "tex")
    info.vertex_in(0, "VEC2", "pos")
    info.vertex_in(1, "VEC2", "uv")
    info.vertex_in(2, "VEC4", "col")

    iface = gpu.types.GPUStageInterfaceInfo("dvui_iface")
    iface.smooth("VEC2", "v_uv")
    iface.smooth("VEC4", "v_col")
    info.vertex_out(iface)

    info.fragment_out(0, "VEC4", "frag")
    info.vertex_source(VERTEX_SOURCE)
    info.fragment_source(FRAGMENT_SOURCE)
    sh = gpu.shader.create_from_info(info)
    _shader_cache[key] = sh
    return sh


def _get_vbo_format(shader) -> gpu.types.GPUVertFormat:
    """Manually built VertFormat that matches the shader's vertex_in
    declarations. ``shader.format_calc()`` returns a format whose
    attribute names don't always match the source ('pos'/'uv'/'col'),
    so we construct one ourselves and use the same names we wrote in
    the shader info.
    """
    key = 0
    cached = _vbo_format_cache.get(key)
    if cached is not None:
        return cached
    fmt = gpu.types.GPUVertFormat()
    fmt.attr_add(id="pos", comp_type="F32", len=2, fetch_mode="FLOAT")
    fmt.attr_add(id="uv", comp_type="F32", len=2, fetch_mode="FLOAT")
    fmt.attr_add(id="col", comp_type="F32", len=4, fetch_mode="FLOAT")
    _vbo_format_cache[key] = fmt
    _ = shader  # kept for future caching by shader id
    return fmt


def _get_white() -> gpu.types.GPUTexture:
    key = 0
    cached = _white_cache.get(key)
    if cached is not None:
        return cached
    buf = gpu.types.Buffer("FLOAT", 4, [1.0, 1.0, 1.0, 1.0])
    tex = gpu.types.GPUTexture(size=(1, 1), format="RGBA8", data=buf)
    _white_cache[key] = tex
    return tex


def _resolve_space_class(space_type: str) -> type:
    """Map a Blender editor enum like 'VIEW_3D' to its bpy.types.Space* class."""
    name = "Space" + "".join(part.capitalize() for part in space_type.split("_"))
    cls = getattr(bpy.types, name, None)
    if cls is None:
        # Common aliases that don't follow the simple pattern.
        fallback = {
            "VIEW_3D": "SpaceView3D",
            "IMAGE_EDITOR": "SpaceImageEditor",
            "NODE_EDITOR": "SpaceNodeEditor",
            "SEQUENCE_EDITOR": "SpaceSequenceEditor",
            "FILE_BROWSER": "SpaceFileBrowser",
            "TEXT_EDITOR": "SpaceTextEditor",
            "GRAPH_EDITOR": "SpaceGraphEditor",
            "DOPESHEET_EDITOR": "SpaceDopeSheetEditor",
            "NLA_EDITOR": "SpaceNLA",
            "INFO": "SpaceInfo",
            "PROPERTIES": "SpaceProperties",
            "OUTLINER": "SpaceOutliner",
            "PREFERENCES": "SpacePreferences",
            "CONSOLE": "SpaceConsole",
        }.get(space_type)
        if fallback:
            cls = getattr(bpy.types, fallback, None)
    if cls is None:
        raise ValueError(f"unknown space type {space_type!r}")
    return cls


@dataclass
class DvuiSession:
    app_name: str
    space_type: str
    native: dvui_native.Native

    ctx: Optional[int] = None
    draw_handler: object = None
    space_class: object = None
    textures: dict[int, gpu.types.GPUTexture] = field(default_factory=dict)
    width: int = 0
    height: int = 0
    last_pixel: tuple[int, int] = (0, 0)
    running: bool = False
    stop_requested: bool = False

    # Set of mouse button indices (0=left, 1=middle, 2=right) whose
    # PRESS we've forwarded to dvui. Tracked so we can also forward
    # the matching RELEASE — even if it happens after the cursor has
    # left our area — without forwarding off-area presses that don't
    # belong to dvui.
    _buttons_held: set = field(default_factory=set)

    # --- lifecycle ---

    def start(self) -> None:
        if self.running:
            return
        self.space_class = _resolve_space_class(self.space_type)
        self.ctx = self.native.lib.dvui_create(800, 600)
        if not self.ctx:
            raise RuntimeError("dvui_create failed")
        self.draw_handler = self.space_class.draw_handler_add(
            self._draw, (), "WINDOW", "POST_PIXEL"
        )
        self.running = True
        self.stop_requested = False

    def stop(self) -> None:
        if not self.running:
            return
        if self.draw_handler is not None and self.space_class is not None:
            self.space_class.draw_handler_remove(self.draw_handler, "WINDOW")
            self.draw_handler = None
        if self.ctx:
            # Let DVUI know the host window is going away before we tear
            # down the context so widgets can react (close handlers etc).
            self.native.lib.dvui_event_window_close(self.ctx)
            self.native.lib.dvui_destroy(self.ctx)
            self.ctx = None
        self.textures.clear()
        self.running = False
        self.stop_requested = True

    # --- explicit DVUI event helpers ---

    def text_select(self, start: int, end: int) -> bool:
        if not self.running or self.ctx is None:
            return False
        return bool(self.native.lib.dvui_event_text_select(self.ctx, start, end))

    def focus_at(self, x: float, y: float, button: int = -1) -> bool:
        if not self.running or self.ctx is None:
            return False
        return bool(self.native.lib.dvui_event_focus(self.ctx, x, y, button))

    def touch_motion(
        self, finger: int, xnorm: float, ynorm: float, dxnorm: float, dynorm: float
    ) -> bool:
        if not self.running or self.ctx is None:
            return False
        return bool(self.native.lib.dvui_event_touch_motion(
            self.ctx, finger, xnorm, ynorm, dxnorm, dynorm
        ))

    def app_quit(self) -> None:
        if self.running and self.ctx is not None:
            self.native.lib.dvui_event_app_quit(self.ctx)

    # --- texture cache ---

    def _sync_textures(self) -> None:
        cap = 32
        creates = (self.native.TextureInfo * cap)()
        while True:
            n = self.native.lib.dvui_drain_texture_creates(self.ctx, creates, cap)
            for i in range(n):
                info = creates[i]
                size = info.width * info.height * 4
                # Vectorized byte → float; the old list-comprehension
                # path was ~50ms for a 512² font atlas.
                src = np.frombuffer(
                    (C.c_ubyte * size).from_address(
                        C.cast(info.pixels, C.c_void_p).value
                    ),
                    dtype=np.uint8,
                )
                floats = src.astype(np.float32) * np.float32(1.0 / 255.0)
                buf = gpu.types.Buffer("FLOAT", size, floats.tolist())
                tex = gpu.types.GPUTexture(
                    size=(info.width, info.height), format="RGBA8", data=buf
                )
                self.textures[info.id] = tex
            if n < cap:
                break

        destroys = (C.c_uint32 * cap)()
        while True:
            n = self.native.lib.dvui_drain_texture_destroys(self.ctx, destroys, cap)
            for i in range(n):
                self.textures.pop(destroys[i], None)
            if n < cap:
                break

    # --- per-frame draw ---

    def _draw(self) -> None:
        ctx = bpy.context
        region = ctx.region
        if region is None:
            return
        w, h = region.width, region.height
        if (w, h) != (self.width, self.height):
            self.width, self.height = w, h
            self.native.lib.dvui_resize(self.ctx, w, h)

        rc = self.native.lib.dvui_frame(self.ctx)
        if rc != 0:
            print(f"[dvui:{self.app_name}] frame error: {rc}")
            return

        self._sync_textures()
        self._render()

    def _render(self) -> None:
        n_v = C.c_uint32()
        n_i = C.c_uint32()
        n_c = C.c_uint32()
        verts_ptr = self.native.lib.dvui_vertices(self.ctx, C.byref(n_v))
        inds_ptr = self.native.lib.dvui_indices(self.ctx, C.byref(n_i))
        cmds_ptr = self.native.lib.dvui_commands(self.ctx, C.byref(n_c))
        v_count = n_v.value
        i_count = n_i.value
        c_count = n_c.value
        if c_count == 0 or v_count == 0:
            return

        shader = _get_shader()
        white = _get_white()
        w, h = self.width, self.height

        # Wrap the C vertex/index buffers as numpy views (zero-copy).
        # Valid only until the next dvui_frame call; we consume them
        # within this draw handler so that's fine.
        vtx_addr = C.cast(verts_ptr, C.c_void_p).value
        vtx_arr = np.frombuffer(
            (C.c_ubyte * (v_count * _VTX_DTYPE.itemsize)).from_address(vtx_addr),
            dtype=_VTX_DTYPE,
        )

        # Per-attribute float arrays. Vectorized byte→float beats the
        # old per-vertex Python loop by ~100×.
        positions = np.empty((v_count, 2), dtype=np.float32)
        positions[:, 0] = vtx_arr["x"]
        positions[:, 1] = vtx_arr["y"]

        uvs = np.empty((v_count, 2), dtype=np.float32)
        uvs[:, 0] = vtx_arr["u"]
        uvs[:, 1] = vtx_arr["v"]

        colors = np.empty((v_count, 4), dtype=np.float32)
        colors[:, 0] = vtx_arr["r"]
        colors[:, 1] = vtx_arr["g"]
        colors[:, 2] = vtx_arr["b"]
        colors[:, 3] = vtx_arr["a"]
        colors *= np.float32(1.0 / 255.0)

        inds_addr = C.cast(inds_ptr, C.c_void_p).value
        indices_flat = np.frombuffer(
            (C.c_ubyte * (i_count * 4)).from_address(inds_addr),
            dtype=np.uint32,
        )

        # Build the shared vertex buffer once per frame. All draw
        # commands below reference this same VBO via their own (small)
        # IndexBuf — we avoid re-uploading the vertex stream N times.
        fmt = _get_vbo_format(shader)
        vbo = gpu.types.GPUVertBuf(fmt, v_count)
        vbo.attr_fill("pos", positions)
        vbo.attr_fill("uv", uvs)
        vbo.attr_fill("col", colors)

        proj = Matrix((
            (2.0 / w, 0.0, 0.0, -1.0),
            (0.0, -2.0 / h, 0.0, 1.0),
            (0.0, 0.0, -1.0, 0.0),
            (0.0, 0.0, 0.0, 1.0),
        ))

        prev_blend = gpu.state.blend_get()
        prev_depth = gpu.state.depth_test_get()
        gpu.state.blend_set("ALPHA_PREMULT")
        gpu.state.depth_test_set("NONE")
        gpu.state.depth_mask_set(False)
        gpu.state.face_culling_set("NONE")
        gpu.state.scissor_test_set(True)

        shader.bind()
        shader.uniform_float("ProjMtx", proj)

        try:
            for k in range(c_count):
                cmd = cmds_ptr[k]
                if cmd.idx_count == 0:
                    continue
                if cmd.has_clip:
                    cx, cy, cw, ch = cmd.clip_x, cmd.clip_y, cmd.clip_w, cmd.clip_h
                    gpu.state.scissor_set(cx, h - (cy + ch), max(0, cw), max(0, ch))
                else:
                    gpu.state.scissor_set(0, 0, w, h)

                tex = self.textures.get(cmd.texture_id, white)
                shader.uniform_sampler("tex", tex)

                cmd_indices = indices_flat[
                    cmd.idx_offset : cmd.idx_offset + cmd.idx_count
                ].reshape(-1, 3)
                ibo = gpu.types.GPUIndexBuf(type="TRIS", seq=cmd_indices)
                batch = gpu.types.GPUBatch(type="TRIS", buf=vbo, elem=ibo)
                batch.draw(shader)
        finally:
            gpu.state.blend_set(prev_blend)
            gpu.state.depth_test_set(prev_depth)
            gpu.state.scissor_test_set(False)

    # --- input forwarding ---

    def forward_event(self, region, event, cursor_in_area: bool) -> bool:
        """Push a Blender event to DVUI. Returns True if dvui consumed it.

        Coordinates are computed from `event.mouse_x/y - region.x/y`
        rather than `event.mouse_region_x/y`, so they remain correct
        when the cursor leaves the region during a drag (otherwise
        `mouse_region_x` reflects whatever region the event happened to
        come from, breaking ongoing drags).

        ``cursor_in_area`` lets us gate button presses (we only want to
        feed dvui presses that originated inside our area, otherwise
        clicks on Blender's own UI — workspace tabs, the Outliner, etc.
        — get hijacked by dvui's focus/capture machinery).
        """
        if not self.running or self.ctx is None:
            return False

        # DVUI uses top-left origin pixel coords; Blender's window/region
        # coordinates use bottom-left origin. Compute relative to the
        # provided region without trusting Blender's per-event region.
        rx = event.mouse_x - region.x
        ry = event.mouse_y - region.y
        x = float(rx)
        y = float(region.height - 1 - ry)
        self.last_pixel = (int(x), int(y))

        et = event.type
        ev = event.value
        mods = dvui_native.blender_event_mods(event)

        if et == "MOUSEMOVE":
            self.native.lib.dvui_event_mouse_motion(self.ctx, x, y)
            return False  # always pass through

        # Mouse-button events from Blender carry several `value`s:
        # PRESS, RELEASE, CLICK, CLICK_DRAG, DOUBLE_CLICK. Only forward
        # PRESS and RELEASE — the synthetic CLICK / CLICK_DRAG /
        # DOUBLE_CLICK fire IN ADDITION to the underlying PRESS/RELEASE,
        # and treating CLICK_DRAG as "not press" would send dvui a
        # spurious RELEASE that kills any in-progress drag.
        if et in {"LEFTMOUSE", "RIGHTMOUSE", "MIDDLEMOUSE"}:
            button = {"LEFTMOUSE": 0, "MIDDLEMOUSE": 1, "RIGHTMOUSE": 2}[et]
            if ev == "PRESS":
                # Don't hand dvui presses that started outside our
                # area (workspace tabs / Outliner / Properties etc.)
                # — let Blender handle them.
                if not cursor_in_area:
                    return False
                self._buttons_held.add(button)
                self.native.lib.dvui_event_mouse_motion(self.ctx, x, y)
                handled = self.native.lib.dvui_event_mouse_button(
                    self.ctx, button, 1
                )
                return bool(handled)
            if ev == "RELEASE":
                # Forward the release if we forwarded the matching
                # press — even when the cursor has since left our
                # area, so a drag that started inside dvui can finish
                # cleanly anywhere.
                if button not in self._buttons_held:
                    return False
                self._buttons_held.discard(button)
                handled = self.native.lib.dvui_event_mouse_button(
                    self.ctx, button, 0
                )
                return bool(handled)
            return False  # CLICK / CLICK_DRAG / DOUBLE_CLICK

        if et == "WHEELUPMOUSE":
            if not cursor_in_area:
                return False
            handled = self.native.lib.dvui_event_mouse_wheel(self.ctx, 0.0, 1.0)
            return bool(handled)
        if et == "WHEELDOWNMOUSE":
            if not cursor_in_area:
                return False
            handled = self.native.lib.dvui_event_mouse_wheel(self.ctx, 0.0, -1.0)
            return bool(handled)

        # Special key?
        code = dvui_native.BLENDER_KEY_TO_CODE.get(et)
        if code is not None:
            pressed = 1 if ev == "PRESS" else (0 if ev == "RELEASE" else 2)
            handled = self.native.lib.dvui_event_key(self.ctx, code, pressed, mods)
        else:
            handled = 0

        # Printable text via event.unicode (only on PRESS).
        if ev == "PRESS" and event.unicode:
            data = event.unicode.encode("utf-8")
            handled |= self.native.lib.dvui_event_text(
                self.ctx, data, len(data)
            )

        # While DVUI has a text-input widget asking for keyboard focus,
        # consume *every* key/text event so Blender hotkeys (Q, G, R,
        # etc.) don't fire for keystrokes the user is typing. Without
        # this dvui's per-event "handled" return is too narrow — it
        # only marks events that landed in a focused subwindow, not
        # ones consumed by the focused widget itself.
        if self.native.lib.dvui_text_input_active(self.ctx):
            handled = 1

        return bool(handled)


def _slugify(name: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "_", name).strip("_").lower()
    if not s:
        s = "dvui_app"
    if not s[0].isalpha():
        s = "a_" + s
    return s


@dataclass
class Addon:
    """The bundle returned by :func:`make_addon`."""

    app_name: str
    slug: str
    space_type: str
    classes: tuple
    session: DvuiSession
    _load_pre_handler: object = None

    def register(self) -> None:
        for c in self.classes:
            bpy.utils.register_class(c)

        # Tell DVUI the app is quitting before Blender swaps the
        # current scene out from under us, so close handlers can run.
        def _on_load_pre(_a, _b):
            if self.session.running:
                self.session.app_quit()
                self.session.stop()

        self._load_pre_handler = _on_load_pre
        bpy.app.handlers.load_pre.append(_on_load_pre)

    def unregister(self) -> None:
        if self.session.running:
            self.session.app_quit()
            self.session.stop()
        if self._load_pre_handler is not None:
            try:
                bpy.app.handlers.load_pre.remove(self._load_pre_handler)
            except ValueError:
                pass
            self._load_pre_handler = None
        for c in reversed(self.classes):
            try:
                bpy.utils.unregister_class(c)
            except Exception:
                pass

    def start(self) -> None:
        bpy.ops.__getattr__(self.slug).start("INVOKE_DEFAULT")

    def stop(self) -> None:
        bpy.ops.__getattr__(self.slug).stop()


def make_addon(
    app_name: str,
    space_type: str = "VIEW_3D",
    *,
    slug: Optional[str] = None,
    native: Optional[dvui_native.Native] = None,
    lib_basename: str = "libblender_dvui",
) -> Addon:
    """Build the operator + panel classes for a DVUI app.

    Parameters
    ----------
    app_name:
        Human-readable label used in operator labels, the sidebar tab
        and panel header.
    space_type:
        Editor enum like ``"VIEW_3D"`` or ``"IMAGE_EDITOR"`` where the
        DVUI overlay should render.
    slug:
        Operator namespace; lowercased / sanitized from ``app_name`` if
        omitted. Becomes the ``bpy.ops.<slug>.start`` / ``stop`` prefix.
    native:
        A pre-loaded :class:`dvui_native.Native` to share across calls;
        loads ``lib_basename`` if not supplied.
    lib_basename:
        Used to discover the shared library on disk.
    """
    slug = slug or _slugify(app_name)
    if native is None:
        native = dvui_native.load(lib_basename)

    session = DvuiSession(
        app_name=app_name,
        space_type=space_type,
        native=native,
    )

    cap_slug = "".join(part.capitalize() for part in slug.split("_"))

    # When hosting in a Node Editor, register a custom NodeTree
    # subclass. It shows up in the Node Editor's tree-type dropdown
    # alongside Shader / Geometry Nodes / Compositor, giving the area
    # visible identity as "the <app_name> editor". Blender doesn't let
    # Python register a true new Space type, but a NodeTree subclass is
    # the closest approximation in NODE_EDITOR.
    node_tree_idname = f"{cap_slug}NodeTree"
    _NodeTree: Optional[type] = None
    if space_type == "NODE_EDITOR":
        from bpy.types import NodeTree

        class _NodeTreeImpl(NodeTree):
            bl_idname = node_tree_idname
            bl_label = app_name
            bl_icon = "NODETREE"

        _NodeTreeImpl.__name__ = f"{cap_slug.upper()}_NodeTree"
        _NodeTree = _NodeTreeImpl

    class _Start(Operator):
        bl_idname = f"{slug}.start"
        bl_label = f"Start {app_name}"
        bl_description = f"Begin rendering the {app_name} DVUI overlay in this editor"

        _timer = None

        def invoke(self, ctx, event):
            if session.running:
                self.report({"WARNING"}, f"{app_name} already running")
                return {"CANCELLED"}

            # Make sure we have at least one area of the right type.
            # If not, convert the area the operator was invoked from
            # (or, failing that, the largest area in the window).
            target_area = None
            for area in ctx.window.screen.areas:
                if area.type == space_type:
                    target_area = area
                    break
            if target_area is None:
                target_area = ctx.area or max(
                    ctx.window.screen.areas,
                    key=lambda a: a.width * a.height,
                )
                try:
                    target_area.type = space_type
                except Exception as exc:
                    self.report(
                        {"ERROR"},
                        f"could not switch area to {space_type}: {exc}",
                    )
                    return {"CANCELLED"}

            try:
                session.start()
            except Exception as exc:
                self.report({"ERROR"}, f"failed to start: {exc}")
                return {"CANCELLED"}

            # If running in a Node Editor with our custom NodeTree
            # registered, switch the active node space to use it so the
            # area is visibly the "<app_name>" editor.
            if space_type == "NODE_EDITOR" and _NodeTree is not None:
                for area in ctx.window.screen.areas:
                    if area.type != "NODE_EDITOR":
                        continue
                    space = area.spaces.active
                    try:
                        space.tree_type = node_tree_idname
                    except Exception:
                        pass

            wm = ctx.window_manager
            self._timer = wm.event_timer_add(1.0 / 60.0, window=ctx.window)
            wm.modal_handler_add(self)

            for area in ctx.window.screen.areas:
                if area.type == space_type:
                    area.tag_redraw()
            return {"RUNNING_MODAL"}

        def modal(self, ctx, event):
            if session.stop_requested or not session.running:
                self._cleanup(ctx)
                return {"CANCELLED"}

            if event.type == "TIMER":
                for area in ctx.window.screen.areas:
                    if area.type == space_type:
                        area.tag_redraw()
                return {"PASS_THROUGH"}

            # Pick the first area of our type. We forward events to it
            # unconditionally — even when the cursor is currently in a
            # different area — so an in-progress drag doesn't starve
            # when the user pulls the floating window title past the
            # area boundary.
            area = next(
                (a for a in ctx.window.screen.areas if a.type == space_type),
                None,
            )
            if area is None:
                return {"PASS_THROUGH"}
            region = next(
                (r for r in area.regions if r.type == "WINDOW"), None
            )
            if region is None:
                return {"PASS_THROUGH"}

            cursor_in_area = (
                area.x <= event.mouse_x <= area.x + area.width
                and area.y <= event.mouse_y <= area.y + area.height
            )

            handled = session.forward_event(region, event, cursor_in_area)
            area.tag_redraw()

            if _EVENT_LOG_PATH is not None:
                _event_log(
                    f"{event.type:<14} {event.value:<8} "
                    f"win=({event.mouse_x},{event.mouse_y}) "
                    f"region=({event.mouse_x - region.x},"
                    f"{event.mouse_y - region.y}) "
                    f"in_area={cursor_in_area} handled={handled}"
                )

            # While the cursor is over our area, swallow right-click
            # entirely so Blender's WM_OT_call_menu (the standard 3D
            # viewport context menu) doesn't fire on top of dvui.
            if event.type == "RIGHTMOUSE" and cursor_in_area:
                return {"RUNNING_MODAL"}

            if handled:
                return {"RUNNING_MODAL"}
            return {"PASS_THROUGH"}

        def _cleanup(self, ctx):
            if self._timer is not None:
                ctx.window_manager.event_timer_remove(self._timer)
                self._timer = None
            session.stop()
            for area in ctx.window.screen.areas:
                if area.type == space_type:
                    area.tag_redraw()

    _Start.__name__ = f"{cap_slug.upper()}_OT_start"

    class _Stop(Operator):
        bl_idname = f"{slug}.stop"
        bl_label = f"Stop {app_name}"

        def execute(self, ctx):
            if not session.running:
                return {"CANCELLED"}
            session.stop_requested = True
            return {"FINISHED"}

    _Stop.__name__ = f"{cap_slug.upper()}_OT_stop"

    class _Panel(Panel):
        bl_idname = f"{cap_slug.upper()}_PT_panel"
        bl_label = app_name
        bl_space_type = space_type
        bl_region_type = "UI"
        bl_category = app_name

        def draw(self, ctx):
            layout = self.layout
            row = layout.row(align=True)
            if session.running:
                row.label(text="Running", icon="RADIOBUT_ON")
                row.operator(_Stop.bl_idname, text="Stop", icon="PAUSE")
            else:
                row.label(text="Stopped", icon="RADIOBUT_OFF")
                row.operator(_Start.bl_idname, text="Start", icon="PLAY")
            layout.label(text=f"Editor: {space_type}")
            layout.label(text=f"slug: {slug}")

    _Panel.__name__ = f"{cap_slug.upper()}_PT_panel"

    classes: tuple = (_Start, _Stop, _Panel)
    if _NodeTree is not None:
        # Register first so the Node Editor sees the tree-type at the
        # time _Start.invoke flips area.spaces.active.tree_type.
        classes = (_NodeTree,) + classes

    return Addon(
        app_name=app_name,
        slug=slug,
        space_type=space_type,
        classes=classes,
        session=session,
    )
