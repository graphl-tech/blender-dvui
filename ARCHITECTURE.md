# Architecture

## Layers

```
 ┌─ Zig ──────────────────────────────────────────────────────────┐
 │  app frame()  ─►  dvui  ─►  Backend (deferred)                 │
 │                              ├─ vertices  []Vertex             │
 │                              ├─ indices   []u32                │
 │                              ├─ commands  []DrawCmd            │
 │                              └─ textures  HashMap(u32 → bytes) │
 │                                                                │
 │  src/lib.zig: C ABI (cdylib)                                   │
 └────────────────────────────────────────────────────────────────┘
                          ▲ ctypes
 ┌─ Python (Blender) ─────────────────────────────────────────────┐
 │  dvui_native.py: ctypes Structures + signature bindings        │
 │  overlay.py:                                                   │
 │     • modal operator   forwards events  ──► dvui_event_*       │
 │     • draw_handler     pulls buffers    ──► numpy view         │
 │                        builds 1 shared GPUVertBuf              │
 │                        per cmd: GPUIndexBuf + GPUBatch.draw    │
 │                        cursor_set from dvui_cursor_requested   │
 └────────────────────────────────────────────────────────────────┘
                          ▼
                   Blender gpu module
```

The split is deliberate: Zig never touches the GL context. Blender owns
it; Python submits draw calls each frame using buffers Zig prepared.

## Serialization

Every cross-language value crosses as a `pub const` `extern struct` in
`backend/src/backend.zig`, mirrored as `ctypes.Structure` in
`dvui_native.py`. Sizes are asserted equal at addon load time
(`dvui_vertex_size`, `dvui_command_size`, `dvui_texture_info_size`).

| Type        | Layout                                                                    | Bytes |
|-------------|---------------------------------------------------------------------------|------:|
| `Vertex`    | `f32 x, y, u, v; u8 r, g, b, a`                                           |    20 |
| `DrawCmd`   | `u32 texture_id, vtx_offset, idx_offset, idx_count, has_clip; i32 cx,cy,cw,ch` |    36 |
| `Index`     | `u32` (global to the merged vertex buffer — Zig rewrites locals at append) |     4 |
| `TextureInfo` | `u32 id, w, h, interpolation, format; u8* pixels`                       |    24 |

Buffers are pulled with raw-pointer accessors (`dvui_vertices`,
`dvui_indices`, `dvui_commands`) and length-out parameters; Python
wraps them in numpy arrays via `np.frombuffer(... .from_address(...))`
for zero-copy reads. Pointers are valid until the next `dvui_frame`.

Textures use a different lifetime. Zig assigns monotonic `u32` IDs and
keeps RGBA pixel buffers CPU-side. `pending_creates` / `pending_destroys`
queues are drained by Python each frame; on the Python side a
`dict[id → GPUTexture]` mirrors the cache.

Events serialize as positional primitives (`f32`, `c_int`) — no struct
crossings. Modifier flags are a packed bitmask
(`MOD_SHIFT|MOD_CTRL|MOD_ALT|MOD_CMD`); key codes use a stable integer
table independent of `dvui.enums.Key`'s internal layout.

## Performance

| Cost                                | Mitigation                                        |
|-------------------------------------|---------------------------------------------------|
| Per-vertex byte→float conversion    | numpy structured-dtype view + vectorized cast     |
| N vertex uploads per frame (one per draw command) | 1 shared `GPUVertBuf` per frame; per-cmd has only a small `GPUIndexBuf` referencing it |
| Vertex format calc per batch        | Cached `GPUVertFormat` (one-time)                 |
| Texture byte→float (FLOAT-only Buffer in Blender) | numpy `astype(float32) * 1/255` instead of list comp |
| Python in the critical path         | numpy keeps hot loops out of pure Python; idle frames are timer-driven (60 Hz) and skip if no events |

Steady-state on the sample app: ~1.5 ms / frame draw. Earlier
list-of-tuples + per-cmd `batch_for_shader` was ~7.8 ms.

## Tradeoffs taken

* **Deferred rendering instead of GL-from-Zig.** Simpler ABI, no GL
  function-pointer bridging, no shared-context bugs; in exchange Python
  has to do one extra vertex-data upload per frame and Zig can't use
  GPU compute or render-target textures (see limitations).
* **Single dynamic library.** No staticlib option; `ctypes` pins the
  `.so` for the life of the Blender process so cdylib hot-reload is
  unsupported.
* **Single dvui instance per cdylib.** `app` is a comptime import in
  `src/lib.zig`. Multiple DVUI apps in one Blender session means
  multiple addons, each with its own cdylib.
* **No GPU-side texture writes.** Textures land in Zig RAM and are
  re-uploaded to GPU on Python's drain. `textureUpdateSubRect` and the
  whole render-target pipeline are not exposed.
* **One area per session.** The modal picks the first area of
  `space_type`; multi-viewport-of-the-same-kind setups will only have
  one of them rendered.
* **Premultiplied-alpha sRGB stream.** dvui hands us byte PMA sRGB; we
  blend with `ALPHA_PREMULT` and convert sRGB→linear in the fragment
  shader because Blender's draw-handler framebuffer is scene-linear.

## Limitations

See [`README.md` § Limitations](README.md#limitations).
