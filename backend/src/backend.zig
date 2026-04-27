//! Deferred-rendering DVUI backend for Blender.
//!
//! Implements the dvui Backend interface but, instead of issuing GL calls,
//! records the draw stream into CPU-side buffers that the Python side reads
//! and submits via Blender's `gpu` module.
//!
//! Ownership: the backend keeps live texture pixel buffers around until
//! dvui calls textureDestroy. Vertices/indices/commands are reset every
//! frame.

const std = @import("std");
const dvui = @import("dvui");

pub const kind: dvui.enums.Backend = .custom;

const Self = @This();

/// Mirrors dvui.Vertex layout but is `extern` so the C ABI sees a stable
/// 20-byte stride (8 bytes pos, 8 bytes uv, 4 bytes color).
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const DrawCmd = extern struct {
    /// Texture id, 0 = no texture (white).
    texture_id: u32,
    vtx_offset: u32,
    idx_offset: u32,
    idx_count: u32,
    /// 1 if clip is set, 0 otherwise.
    has_clip: u32,
    clip_x: i32,
    clip_y: i32,
    clip_w: i32,
    clip_h: i32,
};

pub const TextureInfo = extern struct {
    id: u32,
    width: u32,
    height: u32,
    /// 0 = nearest, 1 = linear
    interpolation: u32,
    /// 0 = rgba, all our textures use rgba pre-multiplied alpha
    format: u32,
    pixels: [*]const u8,
};

const TextureEntry = struct {
    id: u32,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation,
    format: dvui.enums.TexturePixelFormat,
    pixels: []u8,
};

gpa: std.mem.Allocator,
arena: std.mem.Allocator = undefined,

size: dvui.Size.Natural,
size_pixels: dvui.Size.Physical,
content_scale: f32 = 1.0,

vertices: std.ArrayListUnmanaged(Vertex) = .{},
indices: std.ArrayListUnmanaged(u32) = .{},
commands: std.ArrayListUnmanaged(DrawCmd) = .{},

textures: std.AutoArrayHashMapUnmanaged(u32, TextureEntry) = .{},
next_texture_id: u32 = 1,
pending_creates: std.ArrayListUnmanaged(u32) = .{},
pending_destroys: std.ArrayListUnmanaged(u32) = .{},

clipboard: std.ArrayListUnmanaged(u8) = .{},

start_time_ns: i128 = 0,

pub const InitOptions = struct {
    gpa: std.mem.Allocator,
    size: dvui.Size.Natural,
    size_pixels: dvui.Size.Physical,
};

pub fn init(opts: InitOptions) Self {
    return .{
        .gpa = opts.gpa,
        .size = opts.size,
        .size_pixels = opts.size_pixels,
        .start_time_ns = std.time.nanoTimestamp(),
    };
}

pub fn deinit(self: *Self) void {
    self.vertices.deinit(self.gpa);
    self.indices.deinit(self.gpa);
    self.commands.deinit(self.gpa);
    var it = self.textures.iterator();
    while (it.next()) |entry| {
        self.gpa.free(entry.value_ptr.pixels);
    }
    self.textures.deinit(self.gpa);
    self.pending_creates.deinit(self.gpa);
    self.pending_destroys.deinit(self.gpa);
    self.clipboard.deinit(self.gpa);
    self.* = undefined;
}

pub fn backend(self: *Self) dvui.Backend {
    return dvui.Backend.init(self);
}

pub fn setSize(self: *Self, w: u32, h: u32) void {
    self.size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    self.size_pixels = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

// --- dvui.Backend interface implementation ----------------------------------

pub fn nanoTime(self: *Self) i128 {
    _ = self;
    return std.time.nanoTimestamp();
}

pub fn sleep(_: *Self, ns: u64) void {
    std.Thread.sleep(ns);
}

pub fn begin(self: *Self, arena: std.mem.Allocator) !void {
    self.arena = arena;
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.commands.clearRetainingCapacity();
}

pub fn end(_: *Self) !void {}

pub fn pixelSize(self: *Self) dvui.Size.Physical {
    return self.size_pixels;
}

pub fn windowSize(self: *Self) dvui.Size.Natural {
    return self.size;
}

pub fn contentScale(self: *Self) f32 {
    return self.content_scale;
}

pub fn drawClippedTriangles(
    self: *Self,
    texture: ?dvui.Texture,
    vtx: []const dvui.Vertex,
    idx: []const dvui.Vertex.Index,
    clipr: ?dvui.Rect.Physical,
) !void {
    const vtx_offset: u32 = @intCast(self.vertices.items.len);
    const idx_offset: u32 = @intCast(self.indices.items.len);

    try self.vertices.ensureUnusedCapacity(self.gpa, vtx.len);
    for (vtx) |v| {
        self.vertices.appendAssumeCapacity(.{
            .x = v.pos.x,
            .y = v.pos.y,
            .u = v.uv[0],
            .v = v.uv[1],
            .r = v.col.r,
            .g = v.col.g,
            .b = v.col.b,
            .a = v.col.a,
        });
    }

    try self.indices.ensureUnusedCapacity(self.gpa, idx.len);
    for (idx) |i| {
        // Make indices global to the merged vertex buffer.
        self.indices.appendAssumeCapacity(@as(u32, @intCast(i)) + vtx_offset);
    }

    const tex_id: u32 = if (texture) |t|
        @intCast(@intFromPtr(t.ptr))
    else
        0;

    var cmd: DrawCmd = .{
        .texture_id = tex_id,
        .vtx_offset = vtx_offset,
        .idx_offset = idx_offset,
        .idx_count = @intCast(idx.len),
        .has_clip = 0,
        .clip_x = 0,
        .clip_y = 0,
        .clip_w = 0,
        .clip_h = 0,
    };
    if (clipr) |c| {
        cmd.has_clip = 1;
        cmd.clip_x = @intFromFloat(c.x);
        cmd.clip_y = @intFromFloat(c.y);
        cmd.clip_w = @intFromFloat(c.w);
        cmd.clip_h = @intFromFloat(c.h);
    }
    try self.commands.append(self.gpa, cmd);
}

pub fn textureCreate(
    self: *Self,
    pixels: [*]const u8,
    width: u32,
    height: u32,
    interpolation: dvui.enums.TextureInterpolation,
    format: dvui.enums.TexturePixelFormat,
) !dvui.Texture {
    const size: usize = @as(usize, width) * @as(usize, height) * 4;
    const buf = try self.gpa.alloc(u8, size);
    @memcpy(buf, pixels[0..size]);

    const id = self.next_texture_id;
    self.next_texture_id += 1;
    try self.textures.put(self.gpa, id, .{
        .id = id,
        .width = width,
        .height = height,
        .interpolation = interpolation,
        .format = format,
        .pixels = buf,
    });
    try self.pending_creates.append(self.gpa, id);

    return .{
        .ptr = @ptrFromInt(@as(usize, id)),
        .width = width,
        .height = height,
        .format = format,
    };
}

pub fn textureUpdate(
    self: *Self,
    texture: dvui.Texture,
    pixels: [*]const u8,
) !void {
    const id: u32 = @intCast(@intFromPtr(texture.ptr));
    const entry = self.textures.getPtr(id) orelse return error.TextureUpdate;
    const size: usize = @as(usize, entry.width) * @as(usize, entry.height) * 4;
    @memcpy(entry.pixels, pixels[0..size]);
    // Mark for re-upload.
    try self.pending_creates.append(self.gpa, id);
}

pub fn textureDestroy(self: *Self, texture: dvui.Texture) void {
    const id: u32 = @intCast(@intFromPtr(texture.ptr));
    if (self.textures.fetchSwapRemove(id)) |kv| {
        self.gpa.free(kv.value.pixels);
        self.pending_destroys.append(self.gpa, id) catch {};
    }
}

pub fn textureCreateTarget(
    _: *Self,
    _: u32,
    _: u32,
    _: dvui.enums.TextureInterpolation,
    _: dvui.enums.TexturePixelFormat,
) !dvui.TextureTarget {
    return error.TextureCreate;
}

pub fn textureClearTarget(_: *Self, _: dvui.TextureTarget) void {}

pub fn textureReadTarget(_: *Self, _: dvui.TextureTarget, _: [*]u8) !void {
    return error.TextureRead;
}

pub fn textureDestroyTarget(_: *Self, _: dvui.Texture.Target) void {}

pub fn textureFromTarget(_: *Self, _: dvui.TextureTarget) !dvui.Texture {
    return error.NotImplemented;
}

pub fn textureFromTargetTemp(_: *Self, _: dvui.TextureTarget) !dvui.Texture {
    return error.NotImplemented;
}

pub fn renderTarget(_: *Self, _: ?dvui.TextureTarget) !void {}

pub fn clipboardText(self: *Self) ![]const u8 {
    return try self.arena.dupe(u8, self.clipboard.items);
}

pub fn clipboardTextSet(self: *Self, text: []const u8) !void {
    self.clipboard.clearRetainingCapacity();
    try self.clipboard.appendSlice(self.gpa, text);
}

pub fn openURL(_: *Self, _: []const u8, _: bool) !void {}

pub fn preferredColorScheme(_: *Self) ?dvui.enums.ColorScheme {
    return null;
}

pub fn prefersReducedMotion(_: *Self) bool {
    return false;
}

pub fn refresh(_: *Self) void {}

// --- accessors used by the C ABI shim ---------------------------------------

pub fn drainPendingCreatesInto(
    self: *Self,
    out: []TextureInfo,
) usize {
    const n = @min(self.pending_creates.items.len, out.len);
    for (self.pending_creates.items[0..n], 0..) |id, i| {
        const e = self.textures.get(id) orelse continue;
        out[i] = .{
            .id = e.id,
            .width = e.width,
            .height = e.height,
            .interpolation = if (e.interpolation == .linear) 1 else 0,
            .format = 0,
            .pixels = e.pixels.ptr,
        };
    }
    // Drain (we assume caller consumed everything; for a partial drain a
    // more sophisticated API would be required, but textures are rare).
    self.pending_creates.clearRetainingCapacity();
    return n;
}

pub fn drainPendingDestroysInto(self: *Self, out: []u32) usize {
    const n = @min(self.pending_destroys.items.len, out.len);
    @memcpy(out[0..n], self.pending_destroys.items[0..n]);
    self.pending_destroys.clearRetainingCapacity();
    return n;
}

test {
    std.testing.refAllDecls(@This());
}
