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
    b.modules.put(b.allocator, b.dupe("blender_backend"), backend_mod) catch @panic("OOM");

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

    const self_dep = b.allocator.create(std.Build.Dependency) catch @panic("OOM");
    self_dep.* = .{ .builder = b };
    const sample_addon = buildBlenderAddon(b, .{
        .blender_dvui_dep = self_dep,
        .dvui_module = dvui_mod,
        .app_module = app_mod,
        .app_name = "DVUI Sample",
        .target = target,
        .optimize = optimize,
    });
    b.step("blender-addon", "Build the sample app as a Blender addon").dependOn(sample_addon.step);

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

    /// Optional caller-supplied files that ride along inside the
    /// generated addon directory. Each entry is installed at
    /// `<install_root>/<slug>/<name>`. If `name` matches one of the
    /// files this helper would otherwise install — `"__init__.py"`,
    /// `"dvui_native.py"`, `"overlay.py"`, or
    /// `"lib<slug>_dvui.{so,dylib,dll}"` — the caller's file wins and
    /// the default is omitted. Use this to swap the Python addon
    /// implementation for one tailored to your app (e.g. a layer that
    /// spawns a Node.js host).
    extra_files: []const ExtraFile = &.{},

    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const ExtraFile = struct {
    /// Path *inside* `<install_root>/<slug>/`. Use forward slashes
    /// even on Windows.
    name: []const u8,
    /// File contents.
    source: std.Build.LazyPath,
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

    /// The produced zip, also installed as
    /// `<install_root>/<slug>-blender.zip`. The zip contains a single
    /// top-level `<slug>/` directory, which is the layout Blender's
    /// "Install from Disk..." expects.
    zip: std.Build.LazyPath,
};

/// Build a complete Blender addon for a DVUI app.
///
/// Produces, under `zig-out/<install_root>/<slug>/`:
///   - `__init__.py` (templated for the app's name / slug / space_type)
///   - `dvui_native.py` (verbatim copy of this package's ctypes wrapper)
///   - `overlay.py` (verbatim copy of the rendering / modal-operator code)
///   - `lib<slug>_dvui.{so,dylib,dll}` (the cdylib)
///
/// And also bundles that directory into
/// `zig-out/<install_root>/<slug>-blender.zip` for use with Blender's
/// *Install from Disk...* workflow.
///
/// To install the resulting addon in Blender, either point *Install
/// from Disk...* at the zip, or copy the produced directory into
/// Blender's `addons/` folder. Then enable "<App Name>" in
/// Edit > Preferences > Add-ons.
///
/// Returns a `BlenderAddon` whose `step` builds the addon when
/// invoked. The function does NOT auto-attach to `b.getInstallStep()`
/// — the caller decides whether to build by default or only via a
/// dedicated step.
pub fn buildBlenderAddon(b: *std.Build, opts: BlenderAddonOptions) BlenderAddon {
    const dep = opts.blender_dvui_dep;
    const pkg = dep.builder;
    const backend_mod = dep.module("blender_backend");

    // Idempotent if the caller already wired things; addImport just
    // overwrites.
    linkBackend(opts.dvui_module, backend_mod);
    opts.app_module.addImport("dvui", opts.dvui_module);

    const slug = opts.slug orelse slugify(b, opts.app_name);
    const lib_name = b.fmt("{s}_dvui", .{slug});
    const subdir = b.fmt("{s}/{s}", .{ opts.install_root, slug });

    const lib_mod = b.createModule(.{
        .root_source_file = pkg.path("src/lib.zig"),
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

    const addon_dir = b.addWriteFiles();
    const defaults = [_]ExtraFile{
        .{ .name = "dvui_native.py", .source = pkg.path("addon/dvui_native.py") },
        .{ .name = "overlay.py", .source = pkg.path("addon/overlay.py") },
        .{ .name = lib.out_filename, .source = lib.getEmittedBin() },
    };
    if (!isOverridden(opts.extra_files, "__init__.py")) _ = addon_dir.add("__init__.py", init_py);
    for (defaults) |def| {
        if (!isOverridden(opts.extra_files, def.name)) _ = addon_dir.addCopyFile(def.source, def.name);
    }
    for (opts.extra_files) |ef| _ = addon_dir.addCopyFile(ef.source, ef.name);

    const install_dir = b.addInstallDirectory(.{
        .source_dir = addon_dir.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = subdir,
    });

    // `<slug>/...` is the zip's top-level entry, which is what
    // Blender's "Install from Disk..." expects.
    const zip_dir = pkg.addExecutable(.{
        .name = "zip_dir",
        .root_module = pkg.createModule(.{
            .root_source_file = pkg.path("tools/zip_dir.zig"),
            .target = pkg.graph.host,
        }),
    });
    const zip_run = b.addRunArtifact(zip_dir);
    zip_run.addDirectoryArg(addon_dir.getDirectory());
    zip_run.addArg(slug);
    const zip_name = b.fmt("{s}-blender.zip", .{slug});
    const zip = zip_run.addOutputFileArg(zip_name);

    const install_zip = b.addInstallFile(zip, b.fmt("{s}/{s}", .{ opts.install_root, zip_name }));
    install_zip.step.dependOn(&install_dir.step);

    return .{
        .step = &install_zip.step,
        .lib = lib,
        .install_subdir = subdir,
        .slug = slug,
        .zip = zip,
    };
}

fn isOverridden(extra_files: []const ExtraFile, name: []const u8) bool {
    for (extra_files) |ef| {
        if (std.mem.eql(u8, ef.name, name)) return true;
    }
    return false;
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
