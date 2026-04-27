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
/// The user's DVUI app module. Must export `pub fn frame() !void`.
const app = @import("app");

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

/// Returns 1 if dvui considered the event handled, 0 otherwise.
export fn dvui_event_mouse_button(ctx: *Ctx, button: c_int, pressed: c_int) c_int {
    const b = mapMouseButton(button) orelse return 0;
    const action: dvui.Event.Mouse.Action = if (pressed != 0) .press else .release;
    const handled = ctx.window.addEventMouseButton(b, action) catch return 0;
    return if (handled) 1 else 0;
}

export fn dvui_event_mouse_wheel(ctx: *Ctx, dx: f32, dy: f32) c_int {
    var handled: bool = false;
    if (dy != 0) {
        if (ctx.window.addEventMouseWheel(dy, .vertical)) |h| {
            handled = handled or h;
        } else |_| {}
    }
    if (dx != 0) {
        if (ctx.window.addEventMouseWheel(dx, .horizontal)) |h| {
            handled = handled or h;
        } else |_| {}
    }
    return if (handled) 1 else 0;
}

export fn dvui_event_text(ctx: *Ctx, ptr: [*]const u8, len: u32) c_int {
    const handled = ctx.window.addEventText(.{ .text = ptr[0..len] }) catch return 0;
    return if (handled) 1 else 0;
}

/// Stable integer key codes that Python forwards. Kept independent of
/// dvui.enums.Key so we don't pin the addon to a specific dvui version.
pub const KeyCode = enum(c_int) {
    none = 0,
    backspace = 1,
    delete = 2,
    enter = 3,
    escape = 4,
    tab = 5,
    home = 6,
    end_ = 7,
    page_up = 8,
    page_down = 9,
    left = 10,
    right = 11,
    up = 12,
    down = 13,
    insert = 14,
    space = 15,
    left_shift = 20,
    right_shift = 21,
    left_control = 22,
    right_control = 23,
    left_alt = 24,
    right_alt = 25,
    a = 100, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    _,
};

fn mapKeyCode(code: c_int) ?dvui.enums.Key {
    const k: KeyCode = @enumFromInt(code);
    return switch (k) {
        .none => null,
        .backspace => .backspace,
        .delete => .delete,
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .home => .home,
        .end_ => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .insert => .insert,
        .space => .space,
        .left_shift => .left_shift,
        .right_shift => .right_shift,
        .left_control => .left_control,
        .right_control => .right_control,
        .left_alt => .left_alt,
        .right_alt => .right_alt,
        .a => .a, .b => .b, .c => .c, .d => .d, .e => .e, .f => .f,
        .g => .g, .h => .h, .i => .i, .j => .j, .k => .k, .l => .l,
        .m => .m, .n => .n, .o => .o, .p => .p, .q => .q, .r => .r,
        .s => .s, .t => .t, .u => .u, .v => .v, .w => .w, .x => .x,
        .y => .y, .z => .z,
        _ => null,
    };
}

const C_MOD_SHIFT: c_int = 1 << 0;
const C_MOD_CTRL: c_int = 1 << 1;
const C_MOD_ALT: c_int = 1 << 2;
const C_MOD_CMD: c_int = 1 << 3;

fn mapMod(mods: c_int) dvui.enums.Mod {
    var out: u16 = 0;
    if (mods & C_MOD_SHIFT != 0) out |= @intFromEnum(dvui.enums.Mod.lshift);
    if (mods & C_MOD_CTRL != 0) out |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if (mods & C_MOD_ALT != 0) out |= @intFromEnum(dvui.enums.Mod.lalt);
    if (mods & C_MOD_CMD != 0) out |= @intFromEnum(dvui.enums.Mod.lcommand);
    return @enumFromInt(out);
}

/// `pressed`: 0 = up, 1 = down, 2 = repeat. Returns 1 if dvui handled.
export fn dvui_event_key(ctx: *Ctx, code: c_int, pressed: c_int, mods: c_int) c_int {
    const key = mapKeyCode(code) orelse return 0;
    const action: @TypeOf(@as(dvui.Event.Key, undefined).action) = switch (pressed) {
        0 => .up,
        2 => .repeat,
        else => .down,
    };
    const handled = ctx.window.addEventKey(.{
        .code = key,
        .action = action,
        .mod = mapMod(mods),
    }) catch return 0;
    return if (handled) 1 else 0;
}

/// 1 if cursor is over a dvui floating window (so events should be
/// consumed instead of passed through to the underlying area).
export fn dvui_cursor_over_floating(ctx: *Ctx) c_int {
    return if (ctx.window.cursorRequestedFloating() != null) 1 else 0;
}

/// Tell DVUI that text from `start` to `end` should be selected in the
/// currently focused widget. `start` and `end` are byte offsets.
export fn dvui_event_text_select(ctx: *Ctx, start: u32, end: u32) c_int {
    const handled = ctx.window.addEventTextSelect(.{
        .start = @intCast(start),
        .end = @intCast(end),
    }) catch return 0;
    return if (handled) 1 else 0;
}

/// Focus the dvui widget under (`x`, `y`) without moving the mouse
/// position. Use to forward an OS-level "click to focus" signal.
/// `button` follows the same mapping as `dvui_event_mouse_button` but
/// may also be -1 (no button, just a focus event).
export fn dvui_event_focus(ctx: *Ctx, x: f32, y: f32, button: c_int) c_int {
    const b: dvui.enums.Button = if (button < 0)
        .none
    else
        mapMouseButton(button) orelse .none;
    const handled = ctx.window.addEventFocus(.{
        .pt = .{ .x = x, .y = y },
        .button = b,
    }) catch return 0;
    return if (handled) 1 else 0;
}

/// Notify DVUI that the host window is closing.
export fn dvui_event_window_close(ctx: *Ctx) void {
    ctx.window.addEventWindow(.{ .action = .close }) catch {};
}

/// Notify DVUI that the host application is quitting.
export fn dvui_event_app_quit(ctx: *Ctx) void {
    ctx.window.addEventApp(.{ .action = .quit }) catch {};
}

/// Forward a touch / stylus motion event. Coordinates are normalized to
/// `[0, 1]` over the area; `dx`/`dy` are normalized deltas. `finger`
/// is a touch slot id (0..3) — passed through to dvui via
/// `enums.Button.touch0..touch3`.
export fn dvui_event_touch_motion(
    ctx: *Ctx,
    finger: c_int,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
) c_int {
    const f: dvui.enums.Button = switch (finger) {
        0 => .touch0,
        1 => .touch1,
        2 => .touch2,
        3 => .touch3,
        else => return 0,
    };
    const handled = ctx.window.addEventTouchMotion(f, x, y, dx, dy) catch return 0;
    return if (handled) 1 else 0;
}

export fn dvui_frame(ctx: *Ctx) c_int {
    ctx.window.begin(std.time.nanoTimestamp()) catch return -1;
    app.frame() catch return -2;
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
