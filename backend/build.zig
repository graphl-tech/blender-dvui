const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    // The backend module is exposed for the root project to wire up with
    // its `dvui` import. The root build is responsible for calling
    // dvui.linkBackend(dvui_mod, this_module).
    _ = b.addModule("blender_backend", .{
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
    });
}
