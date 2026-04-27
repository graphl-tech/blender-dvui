const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .custom,
        .libc = true,
        .freetype = false,
        .@"tiny-file-dialogs" = false,
        .@"stb-image" = true,
        .@"tree-sitter" = false,
    });
    const dvui_mod = dvui_dep.module("dvui");

    const backend_dep = b.dependency("blender_dvui_backend", .{
        .target = target,
        .optimize = optimize,
    });
    const backend_mod = backend_dep.module("blender_backend");

    backend_mod.addImport("dvui", dvui_mod);
    dvui_mod.addImport("backend", backend_mod);

    const app_dep = b.dependency("blender_dvui_sample_app", .{
        .target = target,
        .optimize = optimize,
    });
    const app_mod = app_dep.module("sample_app");
    app_mod.addImport("dvui", dvui_mod);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_mod },
            .{ .name = "blender_backend", .module = backend_mod },
            .{ .name = "sample_app", .module = app_mod },
        },
    });

    const lib = b.addLibrary(.{
        .name = "blender_dvui",
        .linkage = .dynamic,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run tests");
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}
