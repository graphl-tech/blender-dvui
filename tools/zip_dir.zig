//! Bundles a directory into a zip archive whose single top-level entry
//! is `<top_name>/`, the layout Blender's "Install from Disk..." expects.
//!
//! Usage: zip_dir <source_dir> <top_name> <output.zip>
//!
//! Uses the "stored" (no compression) ZIP method. Output is
//! deterministic: entries are sorted by name and timestamps are pinned
//! to 1980-01-01.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        std.log.err("usage: {s} <source_dir> <top_name> <output.zip>", .{args[0]});
        return error.InvalidArgs;
    }
    try writeZipOfDir(init.io, init.gpa, args[1], args[3], args[2]);
}

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
    source_dir: []const u8,
    output_path: []const u8,
    top_name: []const u8,
) !void {
    var src = try std.Io.Dir.cwd().openDir(io, source_dir, .{ .iterate = true });
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

    var out = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
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
