//! C ABI shim that exports the DVUI runtime to the Blender Python addon.
//!
//! The library glues a `blender_backend.Self` deferred-render backend to a
//! `dvui.Window` and the sample app's `frame()` function. Python drives:
//!
//!     ctx = dvui_create(w, h)
//!     // each draw handler invocation:
//!     dvui_event_*           // forward Blender events
//!     dvui_frame             // run dvui app, populates buffers
//!     dvui_vertices/...      // pull buffers and render with bpy.gpu
//!     dvui_destroy(ctx)

const std = @import("std");
const dvui = @import("dvui");
const blender_backend = @import("blender_backend");
const sample_app = @import("sample_app");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Ctx = struct {
    gpa_state: std.heap.GeneralPurposeAllocator(.{}),
    backend: blender_backend,
    window: dvui.Window,
};

fn allocCtx() ?*Ctx {
    const ctx = std.heap.c_allocator.create(Ctx) catch return null;
    return ctx;
}

fn freeCtx(ctx: *Ctx) void {
    std.heap.c_allocator.destroy(ctx);
}

export fn dvui_create(width: u32, height: u32) ?*Ctx {
    const ctx = allocCtx() orelse return null;
    ctx.gpa_state = .{};
    const gpa = ctx.gpa_state.allocator();

    ctx.backend = blender_backend.init(.{
        .gpa = gpa,
        .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
        .size_pixels = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
    });

    ctx.window = dvui.Window.init(@src(), gpa, ctx.backend.backend(), .{}) catch {
        ctx.backend.deinit();
        _ = ctx.gpa_state.deinit();
        freeCtx(ctx);
        return null;
    };

    return ctx;
}

export fn dvui_destroy(ctx: *Ctx) void {
    ctx.window.deinit();
    ctx.backend.deinit();
    _ = ctx.gpa_state.deinit();
    freeCtx(ctx);
}

export fn dvui_resize(ctx: *Ctx, width: u32, height: u32) void {
    ctx.backend.setSize(width, height);
}

export fn dvui_event_mouse_motion(ctx: *Ctx, x: f32, y: f32) void {
    _ = ctx.window.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } }) catch {};
}

const C_MOUSE_LEFT: c_int = 0;
const C_MOUSE_MIDDLE: c_int = 1;
const C_MOUSE_RIGHT: c_int = 2;

fn mapMouseButton(c: c_int) ?dvui.enums.Button {
    return switch (c) {
        C_MOUSE_LEFT => .left,
        C_MOUSE_MIDDLE => .middle,
        C_MOUSE_RIGHT => .right,
        else => null,
    };
}

export fn dvui_event_mouse_button(ctx: *Ctx, button: c_int, pressed: c_int) void {
    const b = mapMouseButton(button) orelse return;
    const action: dvui.Event.Mouse.Action = if (pressed != 0) .press else .release;
    _ = ctx.window.addEventMouseButton(b, action) catch {};
}

export fn dvui_event_mouse_wheel(ctx: *Ctx, dx: f32, dy: f32) void {
    if (dy != 0) _ = ctx.window.addEventMouseWheel(dy, .vertical) catch {};
    if (dx != 0) _ = ctx.window.addEventMouseWheel(dx, .horizontal) catch {};
}

export fn dvui_event_text(ctx: *Ctx, ptr: [*]const u8, len: u32) void {
    _ = ctx.window.addEventText(.{ .text = ptr[0..len] }) catch {};
}

export fn dvui_frame(ctx: *Ctx) c_int {
    ctx.window.begin(std.time.nanoTimestamp()) catch return -1;
    sample_app.frame() catch return -2;
    _ = ctx.window.end(.{}) catch return -3;
    return 0;
}

// --- buffer accessors -------------------------------------------------------

export fn dvui_vertex_size() u32 {
    return @sizeOf(blender_backend.Vertex);
}

export fn dvui_command_size() u32 {
    return @sizeOf(blender_backend.DrawCmd);
}

export fn dvui_texture_info_size() u32 {
    return @sizeOf(blender_backend.TextureInfo);
}

export fn dvui_vertices(ctx: *Ctx, count_out: *u32) [*]const blender_backend.Vertex {
    count_out.* = @intCast(ctx.backend.vertices.items.len);
    return ctx.backend.vertices.items.ptr;
}

export fn dvui_indices(ctx: *Ctx, count_out: *u32) [*]const u32 {
    count_out.* = @intCast(ctx.backend.indices.items.len);
    return ctx.backend.indices.items.ptr;
}

export fn dvui_commands(ctx: *Ctx, count_out: *u32) [*]const blender_backend.DrawCmd {
    count_out.* = @intCast(ctx.backend.commands.items.len);
    return ctx.backend.commands.items.ptr;
}

/// Drains pending texture creates into the caller's buffer. Returns count
/// written. After this call the create queue is cleared.
export fn dvui_drain_texture_creates(
    ctx: *Ctx,
    out: [*]blender_backend.TextureInfo,
    cap: u32,
) u32 {
    return @intCast(ctx.backend.drainPendingCreatesInto(out[0..cap]));
}

export fn dvui_drain_texture_destroys(
    ctx: *Ctx,
    out: [*]u32,
    cap: u32,
) u32 {
    return @intCast(ctx.backend.drainPendingDestroysInto(out[0..cap]));
}

test {
    std.testing.refAllDecls(@This());
}
