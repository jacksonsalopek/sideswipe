//! Output scale policy and logical/physical conversion.

const std = @import("std");
const testing = @import("core").testing;

pub const Config = struct {
    override: ?f32 = null,
};

pub const PhysicalSize = struct {
    width_mm: u32,
    height_mm: u32,
};

pub const PixelSize = struct {
    width: u32,
    height: u32,
};

pub const Error = error{InvalidOverride};

pub fn preferred(config: Config, pixels: PixelSize, physical: ?PhysicalSize) Error!f32 {
    if (config.override) |value| {
        if (!std.math.isFinite(value) or value < 0.5 or value > 4) return error.InvalidOverride;
        return value;
    }
    const dimensions = physical orelse return 1;
    if (dimensions.width_mm == 0 or dimensions.height_mm == 0) return 1;

    const diagonal_pixels = std.math.hypot(
        @as(f64, @floatFromInt(pixels.width)),
        @as(f64, @floatFromInt(pixels.height)),
    );
    const diagonal_inches = std.math.hypot(
        @as(f64, @floatFromInt(dimensions.width_mm)),
        @as(f64, @floatFromInt(dimensions.height_mm)),
    ) / 25.4;
    const dpi = diagonal_pixels / diagonal_inches;
    if (dpi < 140) return 1;
    if (dpi <= 200) return 1.5;
    return 2;
}

pub fn legacy(fractional: f32) i32 {
    return @intFromFloat(@ceil(fractional));
}

pub fn protocolValue(fractional: f32) u32 {
    return @intFromFloat(@round(fractional * 120));
}

test "preferred scale uses DPI thresholds" {
    try testing.expectEqual(@as(f32, 1), try preferred(.{}, .{ .width = 1920, .height = 1080 }, .{ .width_mm = 600, .height_mm = 340 }));
    try testing.expectEqual(@as(f32, 1.5), try preferred(.{}, .{ .width = 2560, .height = 1440 }, .{ .width_mm = 400, .height_mm = 225 }));
    try testing.expectEqual(@as(f32, 2), try preferred(.{}, .{ .width = 3840, .height = 2160 }, .{ .width_mm = 400, .height_mm = 225 }));
}

test "configured scale overrides detection" {
    try testing.expectEqual(@as(f32, 1.5), try preferred(.{ .override = 1.5 }, .{ .width = 1, .height = 1 }, null));
    try testing.expectError(error.InvalidOverride, preferred(.{ .override = 0 }, .{ .width = 1, .height = 1 }, null));
}

test "fractional protocol and legacy scale values" {
    try testing.expectEqual(@as(u32, 120), protocolValue(1));
    try testing.expectEqual(@as(u32, 180), protocolValue(1.5));
    try testing.expectEqual(@as(u32, 240), protocolValue(2));
    try testing.expectEqual(@as(i32, 2), legacy(1.5));
}
