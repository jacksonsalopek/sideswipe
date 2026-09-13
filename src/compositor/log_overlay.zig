//! Bottom-left log panel painted with a cached system monospace face.

const std = @import("std");
const core = @import("core");
const cli = @import("core.cli");
const font = @import("font.zig");

const margin = 12;
const pad = 8;
const panel_bg = [_]u8{ 24, 24, 24, 230 };
const ink = [_]u8{ 220, 220, 220, 255 };

pub const Overlay = struct {
    gpa: std.mem.Allocator,
    face: *font.Face,
    scratch: [cli.Logger.rolling_cap * 2 + 1]u8 = undefined,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) !*Self {
        const face = try font.Face.openMono(gpa, 13);
        errdefer face.deinit();
        const self = try gpa.create(Self);
        self.* = .{ .gpa = gpa, .face = face };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.face.deinit();
        self.gpa.destroy(self);
    }

    pub fn capture(self: *Self, local: *cli.Logger) []const u8 {
        var n = cli.copyGlobalRolling(&self.scratch);
        if (n > 0 and n < self.scratch.len) {
            self.scratch[n] = '\n';
            n += 1;
        }
        n += local.copyRolling(self.scratch[n..]);
        return self.scratch[0..n];
    }

    pub fn paint(
        self: *const Self,
        pixels: []u8,
        stride: i32,
        width: i32,
        height: i32,
        text: []const u8,
    ) void {
        if (text.len == 0 or width <= 0 or height <= 0) return;
        const cols = columns(width, self.face.cell);
        const rows = rowBudget(height, self.face.line_height);
        if (cols == 0 or rows == 0) return;
        const visible = tail(text, rows);
        const used = usedRows(visible);
        const panel = panelBox(width, height, cols, used, self.face.cell, self.face.line_height);
        fillRect(pixels, stride, width, height, panel, panel_bg);
        drawLines(self.face, pixels, stride, width, height, panel, visible);
    }
};

pub fn tail(text: []const u8, max_lines: usize) []const u8 {
    if (max_lines == 0 or text.len == 0) return &.{};
    var lines: usize = 1;
    for (text) |ch| {
        if (ch == '\n') lines += 1;
    }
    if (text[text.len - 1] == '\n') lines -= 1;
    if (lines <= max_lines) return text;
    return afterSkipped(text, lines - max_lines);
}

fn afterSkipped(text: []const u8, skip: usize) []const u8 {
    var remain = skip;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '\n') continue;
        remain -= 1;
        if (remain == 0) return text[index + 1 ..];
    }
    return text;
}

fn usedRows(text: []const u8) usize {
    if (text.len == 0) return 0;
    var rows: usize = 1;
    for (text) |ch| {
        if (ch == '\n') rows += 1;
    }
    if (text[text.len - 1] == '\n') rows -= 1;
    return rows;
}

fn columns(width: i32, cell: u32) u32 {
    const inner = width - 2 * margin - 2 * pad;
    if (inner <= 0 or cell == 0) return 0;
    return @intCast(@divTrunc(inner, @as(i32, @intCast(cell))));
}

fn rowBudget(height: i32, line_height: u32) usize {
    const inner = height - 2 * margin - 2 * pad;
    if (inner <= 0 or line_height == 0) return 0;
    const fit: usize = @intCast(@divTrunc(inner, @as(i32, @intCast(line_height))));
    const cap: usize = @intCast(@divTrunc(height, 3 * @as(i32, @intCast(line_height))));
    return @min(fit, @max(cap, 4));
}

const Box = struct { x: i32, y: i32, w: i32, h: i32 };

fn panelBox(width: i32, height: i32, cols: u32, rows: usize, cell: u32, line_height: u32) Box {
    const w = @min(width - 2 * margin, @as(i32, @intCast(cols * cell)) + 2 * pad);
    const h = @as(i32, @intCast(rows * line_height)) + 2 * pad;
    return .{
        .x = margin,
        .y = height - margin - h,
        .w = @max(w, 0),
        .h = @max(h, 0),
    };
}

fn drawLines(
    face: *const font.Face,
    pixels: []u8,
    stride: i32,
    width: i32,
    height: i32,
    panel: Box,
    text: []const u8,
) void {
    var y = panel.y + pad;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (index < text.len and text[index] != '\n') continue;
        drawLine(face, pixels, stride, width, height, panel.x + pad, y, text[start..index]);
        y += @intCast(face.line_height);
        start = index + 1;
    }
}

fn drawLine(
    face: *const font.Face,
    pixels: []u8,
    stride: i32,
    width: i32,
    height: i32,
    origin_x: i32,
    origin_y: i32,
    line: []const u8,
) void {
    var pen = origin_x;
    const baseline = origin_y + face.ascender;
    for (line) |ch| {
        if (ch < 32) continue;
        const glyph = face.glyph(ch);
        blitGlyph(pixels, stride, width, height, pen + glyph.left, baseline - glyph.top, glyph);
        pen += glyph.advance;
    }
}

fn blitGlyph(
    pixels: []u8,
    stride: i32,
    width: i32,
    height: i32,
    x0: i32,
    y0: i32,
    glyph: *const font.Glyph,
) void {
    var y: u8 = 0;
    while (y < glyph.h) : (y += 1) {
        var x: u8 = 0;
        while (x < glyph.w) : (x += 1) {
            blend(pixels, stride, width, height, x0 + x, y0 + y, glyph.cover[@as(usize, y) * font.cover_stride + x]);
        }
    }
}

fn fillRect(pixels: []u8, stride: i32, width: i32, height: i32, box: Box, color: [4]u8) void {
    var y: i32 = 0;
    while (y < box.h) : (y += 1) {
        var x: i32 = 0;
        while (x < box.w) : (x += 1) {
            plot(pixels, stride, width, height, box.x + x, box.y + y, color);
        }
    }
}

fn blend(pixels: []u8, stride: i32, width: i32, height: i32, x: i32, y: i32, cover: u8) void {
    if (cover == 0) return;
    const dest = pixel(pixels, stride, width, height, x, y) orelse return;
    if (cover == 255) {
        dest.* = ink;
        return;
    }
    dest[0] = mix(dest[0], ink[0], cover);
    dest[1] = mix(dest[1], ink[1], cover);
    dest[2] = mix(dest[2], ink[2], cover);
    dest[3] = 255;
}

fn plot(pixels: []u8, stride: i32, width: i32, height: i32, x: i32, y: i32, color: [4]u8) void {
    const dest = pixel(pixels, stride, width, height, x, y) orelse return;
    dest.* = color;
}

fn pixel(pixels: []u8, stride: i32, width: i32, height: i32, x: i32, y: i32) ?*[4]u8 {
    if (x < 0 or y < 0 or x >= width or y >= height) return null;
    const off: usize = @intCast(y * stride + x * 4);
    if (off + 4 > pixels.len) return null;
    return pixels[off..][0..4];
}

fn mix(dst: u8, src: u8, cover: u8) u8 {
    const a: u16 = cover;
    return @intCast((@as(u16, src) * a + @as(u16, dst) * (255 - a)) / 255);
}

const testing = core.testing;

test "tail - keeps the newest lines" {
    try testing.expectEqualStrings("b\nc", tail("a\nb\nc", 2));
    try testing.expectEqualStrings("only", tail("only", 3));
    try testing.expectEqualStrings("", tail("", 2));
}

test "Overlay.paint - draws cached glyphs into a BGRA buffer" {
    const overlay = Overlay.init(testing.allocator) catch |err| switch (err) {
        error.NoMonoFont, error.Fontconfig, error.FreeTypeInit, error.FreeTypeFace, error.FreeTypeSize => return error.SkipZigTest,
        else => return err,
    };
    defer overlay.deinit();
    var pixels = [_]u8{0} ** (240 * 160 * 4);
    overlay.paint(&pixels, 240 * 4, 240, 160, "INFO ]: hello");
    var lit: usize = 0;
    for (pixels) |byte| {
        if (byte > 0) lit += 1;
    }
    try testing.expect(lit > 0);
}
