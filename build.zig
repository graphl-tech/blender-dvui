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

    // Re-export the backend module under our own builder so external
    // users can do `b.dependency("blender_dvui").module("blender_backend")`
    // without also depending directly on the sub-package.
    b.modules.put(b.dupe("blender_backend"), backend_mod) catch @panic("OOM");

    linkBackend(dvui_mod, backend_mod);

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
            .{ .name = "app", .module = app_mod },
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

/// Mirrors `dvui.linkBackend` so external users don't have to import
/// dvui's build.zig just to wire a custom backend.
pub fn linkBackend(dvui_mod: *std.Build.Module, backend_mod: *std.Build.Module) void {
    backend_mod.addImport("dvui", dvui_mod);
    dvui_mod.addImport("backend", backend_mod);
}

pub const BlenderAddonOptions = struct {
    /// Reference back to this package, obtained by the caller via
    /// `b.dependency("blender_dvui", .{ .target = ..., .optimize = ... })`.
    blender_dvui_dep: *std.Build.Dependency,

    /// Module exposing `pub fn frame() !void`. Must already have a
    /// `dvui` import (it should be the same module passed in
    /// `dvui_module`).
    app_module: *std.Build.Module,

    /// The dvui module the app was built against. Same module is wired
    /// into the deferred-render backend so types match.
    dvui_module: *std.Build.Module,

    /// Human-readable label, shown in the operator labels and sidebar
    /// tab.
    app_name: []const u8,

    /// Operator namespace; `bpy.ops.<slug>.start` / `<slug>.stop`. If
    /// null, derived from `app_name` (lowercased, non-alnum -> `_`).
    slug: ?[]const u8 = null,

    /// Blender editor enum where the overlay should render. Common
    /// values: `"VIEW_3D"`, `"IMAGE_EDITOR"`, `"NODE_EDITOR"`,
    /// `"GRAPH_EDITOR"`, `"PROPERTIES"`, `"INFO"`.
    space_type: []const u8 = "VIEW_3D",

    /// Where to place the addon directory inside the install prefix.
    /// `<install_root>/<slug>/` will hold all the addon files.
    /// Defaults to `"blender_addon"`.
    install_root: []const u8 = "blender_addon",

    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const BlenderAddon = struct {
    /// Top-level step that, once depended on, builds the cdylib and
    /// installs all four files into the addon directory. Hang it off
    /// `b.getInstallStep()` to make `zig build` build the addon by
    /// default, or off your own custom step (e.g.
    /// `b.step("blender-addon", "...")`) to gate it.
    step: *std.Build.Step,

    /// The cdylib's compile step, exposed so callers can tweak it
    /// further (extra C sources, system libraries, etc.).
    lib: *std.Build.Step.Compile,

    /// Final relative path inside the install prefix, e.g.
    /// `"blender_addon/my_app"`.
    install_subdir: []const u8,

    /// Slug used for the operator namespace and cdylib filename.
    slug: []const u8,
};

/// Build a complete Blender addon for a DVUI app.
///
/// Produces, under `zig-out/<install_root>/<slug>/`:
///   - `__init__.py` (templated for the app's name / slug / space_type)
///   - `dvui_native.py` (verbatim copy of this package's ctypes wrapper)
///   - `overlay.py` (verbatim copy of the rendering / modal-operator code)
///   - `lib<slug>_dvui.{so,dylib,dll}` (the cdylib)
///
/// To install the resulting addon in Blender, copy the produced
/// directory into Blender's `addons/` folder, then enable
/// "<App Name>" in Edit > Preferences > Add-ons.
///
/// Returns a `BlenderAddon` whose `step` builds the addon when
/// invoked. The function does NOT auto-attach to `b.getInstallStep()`
/// — the caller decides whether to build by default or only via a
/// dedicated step.
pub fn buildBlenderAddon(b: *std.Build, opts: BlenderAddonOptions) BlenderAddon {
    const dep = opts.blender_dvui_dep;
    const backend_mod = dep.module("blender_backend");

    // Idempotent if the caller already wired things; addImport just
    // overwrites in zig 0.15.
    linkBackend(opts.dvui_module, backend_mod);
    opts.app_module.addImport("dvui", opts.dvui_module);

    const slug = opts.slug orelse slugify(b, opts.app_name);
    const lib_name = b.fmt("{s}_dvui", .{slug});
    const subdir = b.fmt("{s}/{s}", .{ opts.install_root, slug });

    const lib_mod = b.createModule(.{
        .root_source_file = dep.path("src/lib.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dvui", .module = opts.dvui_module },
            .{ .name = "blender_backend", .module = backend_mod },
            .{ .name = "app", .module = opts.app_module },
        },
    });

    const lib = b.addLibrary(.{
        .name = lib_name,
        .linkage = .dynamic,
        .root_module = lib_mod,
    });

    const install_lib = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = subdir } },
    });

    // Generate the per-app __init__.py.
    const init_py = b.fmt(
        \\bl_info = {{
        \\    "name": "{[name]s}",
        \\    "author": "blender-dvui",
        \\    "version": (0, 0, 1),
        \\    "blender": (4, 0, 0),
        \\    "location": "{[space]s} > Sidebar > {[name]s}",
        \\    "description": "DVUI app rendered into Blender via a Zig backend",
        \\    "category": "User",
        \\}}
        \\
        \\from . import overlay
        \\
        \\_addon = None
        \\
        \\def register():
        \\    global _addon
        \\    _addon = overlay.make_addon(
        \\        app_name="{[name]s}",
        \\        space_type="{[space]s}",
        \\        slug="{[slug]s}",
        \\        lib_basename="lib{[slug]s}_dvui",
        \\    )
        \\    _addon.register()
        \\
        \\def unregister():
        \\    global _addon
        \\    if _addon is not None:
        \\        _addon.unregister()
        \\        _addon = None
        \\
        \\def start():
        \\    if _addon is not None:
        \\        _addon.start()
        \\
        \\def stop():
        \\    if _addon is not None:
        \\        _addon.stop()
        \\
    , .{
        .name = opts.app_name,
        .space = opts.space_type,
        .slug = slug,
    });

    const wf = b.addWriteFiles();
    const init_path = wf.add("__init__.py", init_py);
    const install_init = b.addInstallFile(
        init_path,
        b.fmt("{s}/__init__.py", .{subdir}),
    );
    const install_native = b.addInstallFile(
        dep.path("addon/dvui_native.py"),
        b.fmt("{s}/dvui_native.py", .{subdir}),
    );
    const install_overlay = b.addInstallFile(
        dep.path("addon/overlay.py"),
        b.fmt("{s}/overlay.py", .{subdir}),
    );

    const top = b.allocator.create(std.Build.Step) catch @panic("OOM");
    top.* = std.Build.Step.init(.{
        .id = .custom,
        .name = b.fmt("blender-addon ({s})", .{slug}),
        .owner = b,
    });
    top.dependOn(&install_lib.step);
    top.dependOn(&install_init.step);
    top.dependOn(&install_native.step);
    top.dependOn(&install_overlay.step);

    return .{
        .step = top,
        .lib = lib,
        .install_subdir = subdir,
        .slug = slug,
    };
}

fn slugify(b: *std.Build, name: []const u8) []const u8 {
    const buf = b.allocator.alloc(u8, name.len + 1) catch @panic("OOM");
    var len: usize = 0;
    var prev_underscore = true;
    for (name) |c| {
        const lc = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lc)) {
            buf[len] = lc;
            len += 1;
            prev_underscore = false;
        } else if (!prev_underscore and len > 0) {
            buf[len] = '_';
            len += 1;
            prev_underscore = true;
        }
    }
    while (len > 0 and buf[len - 1] == '_') : (len -= 1) {}
    if (len == 0) {
        const fallback = "dvui_app";
        @memcpy(buf[0..fallback.len], fallback);
        len = fallback.len;
    }
    if (!std.ascii.isAlphabetic(buf[0])) {
        // Prefix to ensure it's a valid python identifier.
        const prefixed = b.fmt("a_{s}", .{buf[0..len]});
        return prefixed;
    }
    return buf[0..len];
}
