//! Bottom-anchored sheet placement (W4). No Wayland types.

const std = @import("std");
const testing = @import("core").testing;
const strip = @import("strip.zig");

pub const HANDLE_HEIGHT: i32 = 24;

pub const Kind = enum { column, sheet };

pub const Classify = struct {
    has_parent: bool = false,
    is_dialog: bool = false,
    override_sheet: ?bool = null,
};

pub const Height = struct {
    parent_height: i32,
    window_geometry_height: ?i32 = null,
    min_height: i32 = 0,
    max_height: i32 = 0,
};

pub const Request = struct {
    id: u32,
    height: i32,
};

pub const Placed = struct {
    id: u32,
    geometry: strip.Geometry,
    handle: strip.Geometry,
};

pub const Result = struct {
    parent: strip.Geometry,
    sheets: std.ArrayList(Placed) = .empty,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.sheets.deinit(allocator);
    }
};

/// Classifies a toplevel as a sheet or a column.
///
/// W7 `override_sheet` wins. Otherwise a parented toplevel or `xdg_dialog_v1`
/// is a sheet. Dialogs without a parent attach to the focused column.
/// No size heuristics.
pub fn classify(input: Classify) Kind {
    if (input.override_sheet) |force_sheet| {
        return if (force_sheet) .sheet else .column;
    }
    if (input.has_parent or input.is_dialog) return .sheet;
    return .column;
}

/// Resolves sheet height: min(desired, 60% of parent).
///
/// Desired order: window geometry height, else min_size clamped by max_size,
/// else half the parent.
pub fn resolveHeight(input: Height) i32 {
    if (input.parent_height <= 0) return 0;
    const cap = @divTrunc(input.parent_height * 3, 5);
    return @min(desiredHeight(input), cap);
}

/// Places sheets bottom-up in map order and shrinks parent content.
/// Sheets never leave the parent tile; leftover height is clipped.
pub fn place(
    allocator: std.mem.Allocator,
    parent: strip.Geometry,
    requests: []const Request,
) std.mem.Allocator.Error!Result {
    var result: Result = .{ .parent = parent };
    errdefer result.deinit(allocator);

    var used: i32 = 0;
    for (requests) |request| {
        const remaining = @max(0, parent.height - used);
        const height = @min(@max(0, request.height), remaining);
        used += height;
        try result.sheets.append(allocator, placedSheet(parent, request.id, used, height));
    }

    result.parent.height = @max(0, parent.height - used);
    return result;
}

fn desiredHeight(input: Height) i32 {
    if (positive(input.window_geometry_height)) |height| return height;
    if (input.min_height > 0) return clampMin(input.min_height, input.max_height);
    return @divTrunc(input.parent_height, 2);
}

fn positive(value: ?i32) ?i32 {
    const height = value orelse return null;
    if (height <= 0) return null;
    return height;
}

fn clampMin(min_height: i32, max_height: i32) i32 {
    if (max_height <= 0) return min_height;
    return @min(min_height, max_height);
}

fn placedSheet(parent: strip.Geometry, id: u32, used: i32, height: i32) Placed {
    const y = parent.y + parent.height - used;
    const geometry = strip.Geometry{
        .x = parent.x,
        .y = y,
        .width = parent.width,
        .height = height,
    };
    return .{
        .id = id,
        .geometry = geometry,
        .handle = grabHandle(geometry),
    };
}

fn grabHandle(geometry: strip.Geometry) strip.Geometry {
    return .{
        .x = geometry.x,
        .y = geometry.y,
        .width = geometry.width,
        .height = @min(HANDLE_HEIGHT, geometry.height),
    };
}

test "sheet classify uses parent, dialog, or override" {
    try testing.expectEqual(Kind.sheet, classify(.{ .has_parent = true }));
    try testing.expectEqual(Kind.sheet, classify(.{ .is_dialog = true }));
    try testing.expectEqual(Kind.sheet, classify(.{ .override_sheet = true }));
    try testing.expectEqual(Kind.column, classify(.{ .is_dialog = true, .override_sheet = false }));
    try testing.expectEqual(Kind.column, classify(.{ .has_parent = true, .override_sheet = false }));
}

test "sheet height prefers window geometry then min clamped by max" {
    try testing.expectEqual(@as(i32, 200), resolveHeight(.{
        .parent_height = 1000,
        .window_geometry_height = 200,
        .min_height = 400,
    }));
    try testing.expectEqual(@as(i32, 150), resolveHeight(.{
        .parent_height = 1000,
        .min_height = 200,
        .max_height = 150,
    }));
    try testing.expectEqual(@as(i32, 500), resolveHeight(.{ .parent_height = 1000 }));
}

test "sheet height caps at sixty percent of parent" {
    try testing.expectEqual(@as(i32, 600), resolveHeight(.{
        .parent_height = 1000,
        .window_geometry_height = 900,
    }));
}

test "sheet place anchors from the bottom and shrinks parent" {
    const requests = [_]Request{
        .{ .id = 2, .height = 200 },
        .{ .id = 3, .height = 100 },
    };
    var result = try place(testing.allocator, .{
        .x = 10,
        .y = 20,
        .width = 400,
        .height = 800,
    }, &requests);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 500), result.parent.height);
    try testing.expectEqual(strip.Geometry{
        .x = 10,
        .y = 620,
        .width = 400,
        .height = 200,
    }, result.sheets.items[0].geometry);
    try testing.expectEqual(strip.Geometry{
        .x = 10,
        .y = 520,
        .width = 400,
        .height = 100,
    }, result.sheets.items[1].geometry);
    try testing.expectEqual(@as(i32, HANDLE_HEIGHT), result.sheets.items[0].handle.height);
}

test "sheet place clips stacked height to the parent tile" {
    const requests = [_]Request{.{ .id = 1, .height = 500 }};
    var result = try place(testing.allocator, .{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 300,
    }, &requests);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 0), result.parent.height);
    try testing.expectEqual(@as(i32, 300), result.sheets.items[0].geometry.height);
}
