//! Minimal sample DVUI app rendered into Blender.
//!
//! The integrator owns the dvui.Window; this module just provides a
//! `frame()` callable each tick.

const std = @import("std");
const dvui = @import("dvui");

var click_count: u32 = 0;
var slider_val: f32 = 0.5;

pub fn frame() !void {
    var float = dvui.floatingWindow(@src(), .{}, .{
        .max_size_content = .{ .w = 320, .h = 240 },
    });
    defer float.deinit();

    float.dragAreaSet(dvui.windowHeader("DVUI in Blender", "", null));

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .all(6),
    });
    defer box.deinit();

    dvui.label(@src(), "'ello from DVUI!", .{}, .{});

    var click_buf: [64]u8 = undefined;
    const click_text = std.fmt.bufPrint(&click_buf, "Clicks: {d}", .{click_count}) catch "Clicks: ?";
    dvui.label(@src(), "{s}", .{click_text}, .{});

    if (dvui.button(@src(), "Click me", .{}, .{})) {
        click_count += 1;
    }

    _ = dvui.slider(@src(), .{ .dir = .horizontal, .fraction = &slider_val }, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 100, .h = 20 },
    });
}
