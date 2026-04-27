"""DVUI overlay drawn on top of the 3D viewport.

Pulls the deferred draw stream out of the Zig backend each frame and
renders it using Blender's `gpu` module.
"""

from __future__ import annotations

import ctypes as C

import bpy
import gpu
from bpy.types import Operator, SpaceView3D
from gpu_extras.batch import batch_for_shader
from mathutils import Matrix

from . import dvui_native as native


VERTEX_SOURCE = """
void main() {
    v_uv = uv;
    v_col = col;
    gl_Position = ProjMtx * vec4(pos, 0.0, 1.0);
}
"""

FRAGMENT_SOURCE = """
void main() {
    frag = v_col * texture(tex, v_uv);
}
"""


_shader: gpu.types.GPUShader | None = None
_white_tex: gpu.types.GPUTexture | None = None


def _build_shader() -> gpu.types.GPUShader:
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
    return gpu.shader.create_from_info(info)


def _get_shader() -> gpu.types.GPUShader:
    global _shader
    if _shader is None:
        _shader = _build_shader()
    return _shader


def _get_white_texture() -> gpu.types.GPUTexture:
    global _white_tex
    if _white_tex is None:
        # 1x1 opaque white, used when DVUI emits a draw call without a texture.
        buf = gpu.types.Buffer("FLOAT", 4, [1.0, 1.0, 1.0, 1.0])
        _white_tex = gpu.types.GPUTexture(size=(1, 1), format="RGBA8", data=buf)
    return _white_tex


class DvuiSession:
    """Owns one dvui context + its draw handler + its texture cache."""

    def __init__(self) -> None:
        self.ctx: int | None = None
        self.draw_handler = None
        self.textures: dict[int, gpu.types.GPUTexture] = {}
        self.width = 0
        self.height = 0
        self.region = None

    # --- lifecycle ---

    def start(self) -> None:
        # Initial size; will be updated each draw from the region.
        self.ctx = native.lib.dvui_create(800, 600)
        if not self.ctx:
            raise RuntimeError("dvui_create failed")
        self.draw_handler = SpaceView3D.draw_handler_add(
            self._draw, (), "WINDOW", "POST_PIXEL"
        )

    def stop(self) -> None:
        if self.draw_handler is not None:
            SpaceView3D.draw_handler_remove(self.draw_handler, "WINDOW")
            self.draw_handler = None
        if self.ctx:
            native.lib.dvui_destroy(self.ctx)
            self.ctx = None
        self.textures.clear()

    # --- texture cache ---

    def _sync_textures(self) -> None:
        # Drain creates.
        cap = 32
        creates = (native.TextureInfo * cap)()
        while True:
            n = native.lib.dvui_drain_texture_creates(self.ctx, creates, cap)
            for i in range(n):
                info = creates[i]
                size = info.width * info.height * 4
                # GPUTexture data buffer must be FLOAT in current Blender.
                pixel_bytes = C.string_at(info.pixels, size)
                floats = [b / 255.0 for b in pixel_bytes]
                buf = gpu.types.Buffer("FLOAT", size, floats)
                tex = gpu.types.GPUTexture(
                    size=(info.width, info.height),
                    format="RGBA8",
                    data=buf,
                )
                # If we already had a texture with this id (re-upload after
                # textureUpdate), the dict overwrite drops the old GPUTexture.
                self.textures[info.id] = tex
            if n < cap:
                break

        # Drain destroys.
        destroys = (C.c_uint32 * cap)()
        while True:
            n = native.lib.dvui_drain_texture_destroys(self.ctx, destroys, cap)
            for i in range(n):
                self.textures.pop(destroys[i], None)
            if n < cap:
                break

    # --- draw ---

    def _draw(self) -> None:
        ctx = bpy.context
        region = ctx.region
        if region is None:
            return

        self.region = region
        w, h = region.width, region.height

        if (w, h) != (self.width, self.height):
            self.width, self.height = w, h
            native.lib.dvui_resize(self.ctx, w, h)

        rc = native.lib.dvui_frame(self.ctx)
        if rc != 0:
            print(f"[dvui] frame error: {rc}")
            return

        self._sync_textures()
        self._render()

    def _render(self) -> None:
        n_v = C.c_uint32()
        n_i = C.c_uint32()
        n_c = C.c_uint32()
        verts = native.lib.dvui_vertices(self.ctx, C.byref(n_v))
        inds = native.lib.dvui_indices(self.ctx, C.byref(n_i))
        cmds = native.lib.dvui_commands(self.ctx, C.byref(n_c))

        if n_c.value == 0:
            return

        shader = _get_shader()
        white = _get_white_texture()

        w, h = self.width, self.height

        # Snapshot vertex/index data once into Python-managed lists.
        v_count = n_v.value
        positions = [None] * v_count
        uvs = [None] * v_count
        colors = [None] * v_count
        for k in range(v_count):
            v = verts[k]
            positions[k] = (v.x, v.y)
            uvs[k] = (v.u, v.v)
            colors[k] = (v.r / 255.0, v.g / 255.0, v.b / 255.0, v.a / 255.0)

        # Ortho mapping: dvui top-left pixel space -> clip space.
        proj = Matrix((
            (2.0 / w, 0.0, 0.0, -1.0),
            (0.0, -2.0 / h, 0.0, 1.0),
            (0.0, 0.0, -1.0, 0.0),
            (0.0, 0.0, 0.0, 1.0),
        ))

        # Save / set GL state via gpu module wrappers.
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
            for k in range(n_c.value):
                cmd = cmds[k]
                if cmd.idx_count == 0:
                    continue

                if cmd.has_clip:
                    cx, cy, cw, ch = cmd.clip_x, cmd.clip_y, cmd.clip_w, cmd.clip_h
                    gpu.state.scissor_set(cx, h - (cy + ch), max(0, cw), max(0, ch))
                else:
                    gpu.state.scissor_set(0, 0, w, h)

                tex = self.textures.get(cmd.texture_id, white)
                shader.uniform_sampler("tex", tex)

                start = cmd.idx_offset
                end = start + cmd.idx_count
                indices = [(inds[start + 3 * t],
                            inds[start + 3 * t + 1],
                            inds[start + 3 * t + 2])
                           for t in range((end - start) // 3)]

                batch = batch_for_shader(
                    shader,
                    "TRIS",
                    {"pos": positions, "uv": uvs, "col": colors},
                    indices=indices,
                )
                batch.draw(shader)
        finally:
            gpu.state.blend_set(prev_blend)
            gpu.state.depth_test_set(prev_depth)
            gpu.state.scissor_test_set(False)


_session: DvuiSession | None = None


class DVUI_OT_start(Operator):
    bl_idname = "dvui.start"
    bl_label = "Start DVUI overlay"

    def execute(self, context):
        global _session
        if _session is not None:
            self.report({"WARNING"}, "DVUI already running")
            return {"CANCELLED"}
        _session = DvuiSession()
        _session.start()
        # Force redraw of all 3D views so the overlay appears immediately.
        for area in context.window.screen.areas:
            if area.type == "VIEW_3D":
                area.tag_redraw()
        return {"FINISHED"}


class DVUI_OT_stop(Operator):
    bl_idname = "dvui.stop"
    bl_label = "Stop DVUI overlay"

    def execute(self, context):
        global _session
        if _session is None:
            self.report({"WARNING"}, "DVUI not running")
            return {"CANCELLED"}
        _session.stop()
        _session = None
        for area in context.window.screen.areas:
            if area.type == "VIEW_3D":
                area.tag_redraw()
        return {"FINISHED"}


classes = (DVUI_OT_start, DVUI_OT_stop)


def register():
    for c in classes:
        bpy.utils.register_class(c)


def unregister():
    global _session
    if _session is not None:
        _session.stop()
        _session = None
    for c in reversed(classes):
        bpy.utils.unregister_class(c)


def start():
    """Convenience entry point for scripts."""
    bpy.ops.dvui.start()


def stop():
    bpy.ops.dvui.stop()
