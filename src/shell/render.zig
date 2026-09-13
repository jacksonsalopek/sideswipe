//! Physical-pixel SDR raster for the privileged shell (H3). Always sRGB.

const std = @import("std");
const testing = @import("core").testing;
const ring_geometry = @import("ring_geometry");

pub const Buffer = struct {
    pixels: []u32,
    width: i32,
    height: i32,
};

pub fn physical(logical: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * scale));
}

/// Inverse of `physical` for wl_output mode pixels advertised as buffer size.
pub fn logicalExtent(extent: i32, scale: f32) i32 {
    const s = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    return @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(@max(extent, 1))) / s))));
}

pub fn logicalSize(physical_w: i32, physical_h: i32, scale: f32) struct { width: i32, height: i32 } {
    return .{
        .width = logicalExtent(physical_w, scale),
        .height = logicalExtent(physical_h, scale),
    };
}

pub fn premul(color: ring_geometry.Color) u32 {
    const a = @as(u32, color.alpha);
    const pixel = ring_geometry.Color{
        .blue = @intCast(@as(u32, color.blue) * a / 255),
        .green = @intCast(@as(u32, color.green) * a / 255),
        .red = @intCast(@as(u32, color.red) * a / 255),
        .alpha = color.alpha,
    };
    return @bitCast(pixel);
}

pub fn clear(buffer: Buffer) void {
    @memset(buffer.pixels, 0);
}

pub fn fillRounded(buffer: Buffer, quad: ring_geometry.PhysicalQuad) void {
    if (quad.width <= 0 or quad.height <= 0) return;
    const color = premul(quad.color);
    const x0 = @max(quad.x, 0);
    const y0 = @max(quad.y, 0);
    const x1 = @min(quad.x + quad.width, buffer.width);
    const y1 = @min(quad.y + quad.height, buffer.height);
    if (x0 >= x1 or y0 >= y1) return;
    var y = y0;
    while (y < y1) : (y += 1) {
        fillRow(buffer, quad, y, x0, x1, color);
    }
}

fn fillRow(buffer: Buffer, quad: ring_geometry.PhysicalQuad, y: i32, x0: i32, x1: i32, color: u32) void {
    var x = x0;
    while (x < x1) : (x += 1) {
        if (!insideRounded(quad, x, y)) continue;
        const index = @as(usize, @intCast(y)) * @as(usize, @intCast(buffer.width)) + @as(usize, @intCast(x));
        buffer.pixels[index] = color;
    }
}

fn insideRounded(quad: ring_geometry.PhysicalQuad, x: i32, y: i32) bool {
    const radius = @min(quad.radius, @divTrunc(@min(quad.width, quad.height), 2));
    if (radius <= 0) return true;
    const left = x - quad.x;
    const top = y - quad.y;
    const right = quad.x + quad.width - 1 - x;
    const bottom = quad.y + quad.height - 1 - y;
    const dx = cornerDelta(left, right, radius);
    const dy = cornerDelta(top, bottom, radius);
    if (dx < 0 or dy < 0) return true;
    return dx * dx + dy * dy <= radius * radius;
}

fn cornerDelta(near: i32, far: i32, radius: i32) i32 {
    if (near < radius) return radius - near;
    if (far < radius) return radius - far;
    return -1;
}

pub fn paintRing(
    buffer: Buffer,
    center_x: f64,
    center_y: f64,
    scale: f32,
    slice_count: u8,
    selected: ?u8,
) !void {
    const quads = try ring_geometry.quadsWithSelection(
        .{},
        .{ .x = center_x, .y = center_y },
        slice_count,
        .fallback,
        selected,
        false,
    );
    for (quads.slice()) |quad| {
        fillRounded(buffer, quad.physical(scale));
    }
}

pub fn paintSwitcher(buffer: Buffer, scale: f32, columns: u32, progress: f64) void {
    if (columns == 0) return;
    const card_w = physical(160, scale);
    const card_h = physical(90, scale);
    const gap = physical(12, scale);
    const y = physical(48, scale) + physical(@intFromFloat(@round(progress * 24)), scale);
    var index: u32 = 0;
    while (index < columns) : (index += 1) {
        const x = physical(24, scale) + @as(i32, @intCast(index)) * (card_w + gap);
        fillRounded(buffer, .{
            .x = x,
            .y = y,
            .width = card_w,
            .height = card_h,
            .radius = physical(6, scale),
            .color = .{ .red = 0x38, .green = 0x38, .blue = 0x38, .alpha = 0xe8 },
        });
    }
}

test "physical size matches ring_geometry scaling" {
    try testing.expectEqual(@as(i32, 40), physical(40, 1));
    try testing.expectEqual(@as(i32, 60), physical(40, 1.5));
    try testing.expectEqual(@as(i32, 80), physical(40, 2));
}

test "logical size inverts physical mode pixels" {
    try testing.expectEqual(@as(i32, 1280), logicalExtent(1920, 1.5));
    try testing.expectEqual(@as(i32, 800), logicalExtent(1200, 1.5));
    const size = logicalSize(1920, 1080, 1);
    try testing.expectEqual(@as(i32, 1920), size.width);
    try testing.expectEqual(@as(i32, 1080), size.height);
    try testing.expectEqual(@as(i32, 1), logicalExtent(0, 2));
    try testing.expectEqual(@as(i32, 1080), logicalExtent(1080, 0));
}

test "ring raster writes physical pixels" {
    const pixels = try testing.allocator.alloc(u32, 200 * 200);
    defer testing.allocator.free(pixels);
    const buffer = Buffer{ .pixels = pixels, .width = 200, .height = 200 };
    clear(buffer);
    try paintRing(buffer, 100, 100, 1, 4, 1);
    var painted: usize = 0;
    for (pixels) |pixel| {
        if (pixel != 0) painted += 1;
    }
    try testing.expect(painted > 0);
}

test "premul keeps packed BGRA order" {
    const color = ring_geometry.Color{ .red = 0xff, .green = 0, .blue = 0, .alpha = 0x80 };
    const pixel: ring_geometry.Color = @bitCast(premul(color));
    try testing.expectEqual(@as(u8, 0x80), pixel.alpha);
    try testing.expectEqual(@as(u8, 0x80), pixel.red);
}
