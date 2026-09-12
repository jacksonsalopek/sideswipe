//! Shared radial-menu hit testing and fallback geometry.

const std = @import("std");
const testing = @import("core").testing;

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const Config = struct {
    inner_radius: f64 = 28,
    outer_radius: f64 = 112,
    item_radius: f64 = 72,
    item_width: f64 = 40,
    item_height: f64 = 24,
    corner_radius: f64 = 6,
};

pub const Color = packed struct(u32) {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8,
};

pub const Quad = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    radius: f64,
    color: Color,

    pub fn physical(self: Quad, scale: f32) PhysicalQuad {
        const left = scaledEdge(self.x, scale);
        const top = scaledEdge(self.y, scale);
        const right = scaledEdge(self.x + self.width, scale);
        const bottom = scaledEdge(self.y + self.height, scale);
        return .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
            .radius = @max(0, scaledEdge(self.radius, scale)),
            .color = self.color,
        };
    }
};

pub const PhysicalQuad = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    radius: i32,
    color: Color,
};

pub const Quads = struct {
    items: [8]Quad = undefined,
    len: usize = 0,

    pub fn slice(self: *const Quads) []const Quad {
        return self.items[0..self.len];
    }
};

pub const Style = enum {
    placeholder,
    fallback,
};

/// Returns the zero-based slice under `point`, with slice zero centered upward.
pub fn hit(config: Config, center: Point, point: Point, slice_count: u8) !?u8 {
    try validate(config, slice_count);
    if (!finitePoint(center) or !finitePoint(point)) return error.InvalidCoordinate;
    const dx = point.x - center.x;
    const dy = point.y - center.y;
    const radius = std.math.hypot(dx, dy);
    if (radius < config.inner_radius or radius > config.outer_radius) return null;
    const full = 2 * std.math.pi;
    const step = full / @as(f64, @floatFromInt(slice_count));
    var angle = std.math.atan2(dx, -dy);
    if (angle < 0) angle += full;
    return @intFromFloat(@floor(@mod(angle + step / 2, full) / step));
}

/// Builds scale-independent rounded rectangles for the first fallback frame.
pub fn quads(config: Config, center: Point, slice_count: u8, style: Style) !Quads {
    return quadsWithSelection(config, center, slice_count, style, null, false);
}

pub fn quadsWithSelection(
    config: Config,
    center: Point,
    slice_count: u8,
    style: Style,
    selected: ?u8,
    focus_visible: bool,
) !Quads {
    try validate(config, slice_count);
    if (selected) |index| {
        if (index >= slice_count) return error.InvalidSelection;
    }
    if (!finitePoint(center)) return error.InvalidCoordinate;
    var result: Quads = .{};
    const step = 2 * std.math.pi / @as(f64, @floatFromInt(slice_count));
    for (0..slice_count) |index| {
        const angle = @as(f64, @floatFromInt(index)) * step - @as(f64, std.math.pi) / 2;
        const item_center = Point{
            .x = center.x + @cos(angle) * config.item_radius,
            .y = center.y + @sin(angle) * config.item_radius,
        };
        result.items[index] = .{
            .x = item_center.x - config.item_width / 2,
            .y = item_center.y - config.item_height / 2,
            .width = config.item_width,
            .height = config.item_height,
            .radius = config.corner_radius,
            .color = styleColor(style, index, selected, focus_visible),
        };
    }
    result.len = slice_count;
    return result;
}

fn validate(config: Config, slice_count: u8) !void {
    if (slice_count == 0 or slice_count > 8) return error.InvalidSliceCount;
    if (!std.math.isFinite(config.inner_radius) or
        !std.math.isFinite(config.outer_radius) or
        !std.math.isFinite(config.item_radius) or
        !std.math.isFinite(config.item_width) or
        !std.math.isFinite(config.item_height) or
        !std.math.isFinite(config.corner_radius))
    {
        return error.InvalidGeometry;
    }
    if (config.inner_radius < 0 or config.outer_radius <= config.inner_radius)
        return error.InvalidGeometry;
    if (config.item_width <= 0 or config.item_height <= 0 or config.corner_radius < 0)
        return error.InvalidGeometry;
}

fn finitePoint(point: Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn scaledEdge(value: f64, scale: f32) i32 {
    return @intFromFloat(@round(value * @as(f64, scale)));
}

fn styleColor(style: Style, index: usize, selected: ?u8, focus_visible: bool) Color {
    if (selected != null and selected.? == index) {
        return if (focus_visible)
            .{ .red = 0xff, .green = 0xd0, .blue = 0x30, .alpha = 0xff }
        else
            .{ .red = 0x70, .green = 0xa0, .blue = 0xff, .alpha = 0xff };
    }
    return switch (style) {
        .placeholder => .{ .red = 0x7a, .green = 0x7a, .blue = 0x7a, .alpha = 0xd0 },
        .fallback => .{ .red = 0x38, .green = 0x38, .blue = 0x38, .alpha = 0xe8 },
    };
}

test "ring hit test honors dead zone and outer edge" {
    const center = Point{ .x = 100, .y = 100 };
    try testing.expectNull(try hit(.{}, center, center, 4));
    try testing.expectEqual(@as(?u8, 0), try hit(.{}, center, .{ .x = 100, .y = 72 }, 4));
    try testing.expectEqual(@as(?u8, 1), try hit(.{}, center, .{ .x = 128, .y = 100 }, 4));
    try testing.expectNull(try hit(.{}, center, .{ .x = 100, .y = -13 }, 4));
}

test "ring slice boundaries split symmetrically" {
    const center = Point{ .x = 0, .y = 0 };
    const inside_first = Point{ .x = 19, .y = -46 };
    const inside_second = Point{ .x = 46, .y = -19 };
    try testing.expectEqual(@as(?u8, 0), try hit(.{}, center, inside_first, 4));
    try testing.expectEqual(@as(?u8, 1), try hit(.{}, center, inside_second, 4));
}

test "ring placeholder quads scale at one one-half and two" {
    const result = try quads(.{}, .{ .x = 100, .y = 100 }, 4, .placeholder);
    try testing.expectEqual(@as(usize, 4), result.len);
    const logical = result.slice()[0];
    const one = logical.physical(1);
    const fractional = logical.physical(1.5);
    const two = logical.physical(2);
    try testing.expectEqual(@as(i32, 40), one.width);
    try testing.expectEqual(@as(i32, 60), fractional.width);
    try testing.expectEqual(@as(i32, 80), two.width);
    try testing.expectEqual(@as(i32, 9), fractional.radius);
}

test "ring quads use rounded fallback highlight" {
    const result = try quadsWithSelection(.{}, .{ .x = 0, .y = 0 }, 3, .fallback, 0, false);
    try testing.expect(result.slice()[0].radius > 0);
    try testing.expect(result.slice()[0].color.red != result.slice()[1].color.red);
}

test "ring selection exposes pointer and focus-visible colors" {
    const pointer = try quadsWithSelection(.{}, .{}, 4, .fallback, 2, false);
    const keyboard = try quadsWithSelection(.{}, .{}, 4, .fallback, 2, true);
    try testing.expect(pointer.slice()[2].color.red != pointer.slice()[1].color.red);
    try testing.expect(pointer.slice()[2].color.red != keyboard.slice()[2].color.red);
    try testing.expectError(error.InvalidSelection, quadsWithSelection(.{}, .{}, 4, .fallback, 4, false));
}

test "ring rejects invalid counts coordinates and radii" {
    try testing.expectError(error.InvalidSliceCount, hit(.{}, .{}, .{}, 0));
    try testing.expectError(error.InvalidSliceCount, quads(.{}, .{}, 9, .fallback));
    try testing.expectError(error.InvalidCoordinate, hit(.{}, .{ .x = std.math.inf(f64), .y = 0 }, .{}, 4));
    try testing.expectError(error.InvalidGeometry, quads(.{ .inner_radius = 10, .outer_radius = 9 }, .{}, 4, .fallback));
}
