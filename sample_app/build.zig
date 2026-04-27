const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    _ = b.addModule("sample_app", .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
    });
}
