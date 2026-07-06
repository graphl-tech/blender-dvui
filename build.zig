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

    /// Absolute path to the produced zip, e.g.
    /// `"<install_prefix>/blender_addon/my_app-blender.zip"`. The zip
    /// contains a single top-level `<slug>/` directory, which is the
    /// layout Blender's "Install from Disk..." expects.
    zip_path: []const u8,
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

    // Which of the default files did the caller override? We skip
    // installing the default for any name present in extra_files.
    var overrode_init = false;
    var overrode_native = false;
    var overrode_overlay = false;
    for (opts.extra_files) |ef| {
        if (std.mem.eql(u8, ef.name, "__init__.py")) overrode_init = true;
        if (std.mem.eql(u8, ef.name, "dvui_native.py")) overrode_native = true;
        if (std.mem.eql(u8, ef.name, "overlay.py")) overrode_overlay = true;
    }

    const wf = b.addWriteFiles();
    const init_path = wf.add("__init__.py", init_py);

    const top = b.allocator.create(std.Build.Step) catch @panic("OOM");
    top.* = std.Build.Step.init(.{
        .id = .custom,
        .name = b.fmt("blender-addon ({s})", .{slug}),
        .owner = b,
    });
    top.dependOn(&install_lib.step);

    // Zip the addon directory into `<install_root>/<slug>-blender.zip`,
    // with `<slug>/...` as the zip's top-level entry — that's what
    // Blender's "Install from Disk..." expects.
    const install_root_abs = b.getInstallPath(.{ .custom = opts.install_root }, "");
    const slug_dir_abs = b.getInstallPath(.{ .custom = subdir }, "");
    const zip_path = b.fmt("{s}/{s}-blender.zip", .{ install_root_abs, slug });

    const zip_step = ZipDirStep.create(b, slug_dir_abs, zip_path, slug);
    zip_step.step.dependOn(&install_lib.step);

    if (!overrode_init) {
        const install_init = b.addInstallFile(
            init_path,
            b.fmt("{s}/__init__.py", .{subdir}),
        );
        zip_step.step.dependOn(&install_init.step);
        top.dependOn(&install_init.step);
    }
    if (!overrode_native) {
        const install_native = b.addInstallFile(
            dep.path("addon/dvui_native.py"),
            b.fmt("{s}/dvui_native.py", .{subdir}),
        );
        zip_step.step.dependOn(&install_native.step);
        top.dependOn(&install_native.step);
    }
    if (!overrode_overlay) {
        const install_overlay = b.addInstallFile(
            dep.path("addon/overlay.py"),
            b.fmt("{s}/overlay.py", .{subdir}),
        );
        zip_step.step.dependOn(&install_overlay.step);
        top.dependOn(&install_overlay.step);
    }

    for (opts.extra_files) |ef| {
        const install_extra = b.addInstallFile(
            ef.source,
            b.fmt("{s}/{s}", .{ subdir, ef.name }),
        );
        zip_step.step.dependOn(&install_extra.step);
        top.dependOn(&install_extra.step);
    }

    top.dependOn(&zip_step.step);

    return .{
        .step = top,
        .lib = lib,
        .install_subdir = subdir,
        .slug = slug,
        .zip_path = zip_path,
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

/// Custom build step that bundles a directory into a zip archive.
///
/// Uses the "stored" (no compression) ZIP method, which keeps the
/// implementation small while still producing a file that Blender's
/// addon installer accepts. Output is deterministic: entries are
/// sorted by name and timestamps are pinned to 1980-01-01.
const ZipDirStep = struct {
    step: std.Build.Step,
    source_dir_abs: []const u8,
    output_path_abs: []const u8,
    top_name: []const u8,

    fn create(
        b: *std.Build,
        source_dir_abs: []const u8,
        output_path_abs: []const u8,
        top_name: []const u8,
    ) *ZipDirStep {
        const self = b.allocator.create(ZipDirStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("zip {s}", .{std.fs.path.basename(output_path_abs)}),
                .owner = b,
                .makeFn = make,
            }),
            .source_dir_abs = source_dir_abs,
            .output_path_abs = output_path_abs,
            .top_name = top_name,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *ZipDirStep = @fieldParentPtr("step", step);
        try writeZipOfDir(
            step.owner.graph.io,
            step.owner.allocator,
            self.source_dir_abs,
            self.output_path_abs,
            self.top_name,
        );
    }
};

const ZipEntry = struct {
    /// Path as it appears inside the zip, with `/` separators.
    /// Directories have a trailing `/`.
    name: []u8,
    kind: enum { file, dir },
    data: []u8,
    crc: u32,
    local_header_offset: u32 = 0,
};

fn writeZipOfDir(
    io: std.Io,
    alloc: std.mem.Allocator,
    source_dir_abs: []const u8,
    output_path_abs: []const u8,
    top_name: []const u8,
) !void {
    var src = try std.Io.Dir.cwd().openDir(io, source_dir_abs, .{ .iterate = true });
    defer src.close(io);

    var entries: std.ArrayList(ZipEntry) = .empty;
    defer {
        for (entries.items) |e| {
            alloc.free(e.name);
            alloc.free(e.data);
        }
        entries.deinit(alloc);
    }

    try entries.append(alloc, .{
        .name = try std.fmt.allocPrint(alloc, "{s}/", .{top_name}),
        .kind = .dir,
        .data = &.{},
        .crc = 0,
    });

    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                try entries.append(alloc, .{
                    .name = try std.fmt.allocPrint(alloc, "{s}/{s}/", .{ top_name, entry.path }),
                    .kind = .dir,
                    .data = &.{},
                    .crc = 0,
                });
            },
            .file => {
                const data = try src.readFileAlloc(io, entry.path, alloc, .unlimited);
                try entries.append(alloc, .{
                    .name = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ top_name, entry.path }),
                    .kind = .file,
                    .data = data,
                    .crc = std.hash.Crc32.hash(data),
                });
            },
            else => {},
        }
    }

    std.mem.sort(ZipEntry, entries.items, {}, struct {
        fn lt(_: void, a: ZipEntry, b: ZipEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Local file headers + data.
    for (entries.items) |*e| {
        e.local_header_offset = @intCast(buf.items.len);
        try writeU32Le(alloc, &buf, 0x04034b50); // local file header signature
        try writeU16Le(alloc, &buf, 20); // version needed
        try writeU16Le(alloc, &buf, 0); // flags
        try writeU16Le(alloc, &buf, 0); // method = stored
        try writeU16Le(alloc, &buf, 0); // dos time (00:00:00)
        try writeU16Le(alloc, &buf, 0x0021); // dos date (1980-01-01)
        try writeU32Le(alloc, &buf, e.crc);
        try writeU32Le(alloc, &buf, @intCast(e.data.len)); // compressed
        try writeU32Le(alloc, &buf, @intCast(e.data.len)); // uncompressed
        try writeU16Le(alloc, &buf, @intCast(e.name.len));
        try writeU16Le(alloc, &buf, 0); // extra field length
        try buf.appendSlice(alloc, e.name);
        try buf.appendSlice(alloc, e.data);
    }

    // Central directory.
    const cd_offset: u32 = @intCast(buf.items.len);
    for (entries.items) |e| {
        try writeU32Le(alloc, &buf, 0x02014b50); // central directory signature
        try writeU16Le(alloc, &buf, 0x031e); // version made by: unix, zip 3.0
        try writeU16Le(alloc, &buf, 20); // version needed
        try writeU16Le(alloc, &buf, 0); // flags
        try writeU16Le(alloc, &buf, 0); // method
        try writeU16Le(alloc, &buf, 0); // time
        try writeU16Le(alloc, &buf, 0x0021); // date
        try writeU32Le(alloc, &buf, e.crc);
        try writeU32Le(alloc, &buf, @intCast(e.data.len));
        try writeU32Le(alloc, &buf, @intCast(e.data.len));
        try writeU16Le(alloc, &buf, @intCast(e.name.len));
        try writeU16Le(alloc, &buf, 0); // extra field length
        try writeU16Le(alloc, &buf, 0); // comment length
        try writeU16Le(alloc, &buf, 0); // disk number
        try writeU16Le(alloc, &buf, 0); // internal attrs
        // External attrs: unix mode in upper 16 bits, DOS attrs in lower.
        const ext_attrs: u32 = switch (e.kind) {
            .dir => (@as(u32, 0o040755) << 16) | 0x10,
            .file => (@as(u32, 0o100644) << 16),
        };
        try writeU32Le(alloc, &buf, ext_attrs);
        try writeU32Le(alloc, &buf, e.local_header_offset);
        try buf.appendSlice(alloc, e.name);
    }
    const cd_size: u32 = @as(u32, @intCast(buf.items.len)) - cd_offset;

    // End of central directory record.
    try writeU32Le(alloc, &buf, 0x06054b50);
    try writeU16Le(alloc, &buf, 0); // this disk
    try writeU16Le(alloc, &buf, 0); // disk where CD starts
    try writeU16Le(alloc, &buf, @intCast(entries.items.len));
    try writeU16Le(alloc, &buf, @intCast(entries.items.len));
    try writeU32Le(alloc, &buf, cd_size);
    try writeU32Le(alloc, &buf, cd_offset);
    try writeU16Le(alloc, &buf, 0); // comment length

    var out = try std.Io.Dir.cwd().createFile(io, output_path_abs, .{ .truncate = true });
    defer out.close(io);
    try out.writeStreamingAll(io, buf.items);
}

fn writeU16Le(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: u16) !void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, v, .little);
    try buf.appendSlice(alloc, &tmp);
}

fn writeU32Le(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try buf.appendSlice(alloc, &tmp);
}
