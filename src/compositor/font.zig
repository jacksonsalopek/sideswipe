//! System monospace faces via Fontconfig + FreeType. Glyphs are cached at load.

const std = @import("std");
const core = @import("core");

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const fc = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

const first_char: u8 = 32;
const last_char: u8 = 126;
const glyph_count = last_char - first_char + 1;
pub const cover_stride = 32;
const max_side = cover_stride;

const preferred = [_][:0]const u8{
    "Adwaita Mono",
    "IBM Plex Mono",
    "Liberation Mono",
    "SF Mono",
    "monospace",
};

pub const Glyph = struct {
    w: u8 = 0,
    h: u8 = 0,
    left: i8 = 0,
    top: i8 = 0,
    advance: u8 = 0,
    cover: [max_side * max_side]u8 = @splat(0),
};

pub const Face = struct {
    gpa: std.mem.Allocator,
    library: ft.FT_Library,
    face: ft.FT_Face,
    ascender: i32,
    line_height: u32,
    cell: u32,
    glyphs: [glyph_count]Glyph = @splat(.{}),

    const Self = @This();

    /// Loads an installed monospace face and rasterizes ASCII.
    pub fn openMono(gpa: std.mem.Allocator, px: u32) !*Self {
        if (firstInstalled()) |path| return openPath(gpa, path, px);
        const path = try resolveMono(gpa);
        defer gpa.free(path);
        return openPath(gpa, path, px);
    }

    pub fn openPath(gpa: std.mem.Allocator, path: [:0]const u8, px: u32) !*Self {
        if (px == 0) return error.InvalidSize;
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.FreeTypeInit;
        errdefer _ = ft.FT_Done_FreeType(library);

        var face: ft.FT_Face = null;
        if (ft.FT_New_Face(library, path.ptr, 0, &face) != 0) return error.FreeTypeFace;
        errdefer _ = ft.FT_Done_Face(face);
        if (ft.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FreeTypeSize;

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .library = library,
            .face = face,
            .ascender = metric(face, .ascender),
            .line_height = @intCast(@max(metric(face, .height), 1)),
            .cell = 0,
        };
        self.cacheAscii();
        self.cell = if (self.glyph('M').advance != 0) self.glyph('M').advance else 8;
        return self;
    }

    pub fn deinit(self: *Self) void {
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
        self.gpa.destroy(self);
    }

    pub fn glyph(self: *const Self, ch: u8) *const Glyph {
        if (ch < first_char or ch > last_char) return self.glyph('?');
        return &self.glyphs[ch - first_char];
    }

    fn cacheAscii(self: *Self) void {
        var ch: u8 = first_char;
        while (ch <= last_char) : (ch += 1) {
            self.glyphs[ch - first_char] = rasterize(self.face, ch);
        }
    }
};

/// Resolves a system monospace file via Fontconfig.
pub fn resolveMono(gpa: std.mem.Allocator) ![:0]u8 {
    if (fc.FcInit() == fc.FcFalse) return error.Fontconfig;
    for (preferred) |family| {
        if (matchFamily(gpa, family)) |path| return path;
    }
    return error.NoMonoFont;
}

fn matchFamily(gpa: std.mem.Allocator, family: [:0]const u8) ?[:0]u8 {
    const pattern = fc.FcPatternCreate() orelse return null;
    defer fc.FcPatternDestroy(pattern);
    _ = fc.FcPatternAddString(pattern, fc.FC_FAMILY, family.ptr);
    _ = fc.FcPatternAddInteger(pattern, fc.FC_SPACING, fc.FC_MONO);
    _ = fc.FcConfigSubstitute(null, pattern, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pattern);
    var result: fc.FcResult = fc.FcResultNoMatch;
    const matched = fc.FcFontMatch(null, pattern, &result) orelse return null;
    defer fc.FcPatternDestroy(matched);
    var file: [*c]fc.FcChar8 = null;
    if (fc.FcPatternGetString(matched, fc.FC_FILE, 0, &file) != fc.FcResultMatch) return null;
    if (file == null) return null;
    return gpa.dupeZ(u8, std.mem.span(file)) catch null;
}

const Metric = enum { ascender, height };

fn metric(face: ft.FT_Face, which: Metric) i32 {
    const metrics = face.*.size.*.metrics;
    const raw: i32 = switch (which) {
        .ascender => @intCast(metrics.ascender),
        .height => @intCast(metrics.height),
    };
    return @divTrunc(raw, 64);
}

fn rasterize(face: ft.FT_Face, ch: u8) Glyph {
    if (ft.FT_Load_Char(face, ch, ft.FT_LOAD_RENDER) != 0) return .{};
    const slot = face.*.glyph;
    const bitmap = slot.*.bitmap;
    var glyph = Glyph{
        .left = @intCast(std.math.clamp(slot.*.bitmap_left, std.math.minInt(i8), std.math.maxInt(i8))),
        .top = @intCast(std.math.clamp(slot.*.bitmap_top, std.math.minInt(i8), std.math.maxInt(i8))),
        .advance = @intCast(@min(@as(u32, @intCast(@divTrunc(slot.*.advance.x, 64))), 255)),
    };
    copyCover(&glyph, bitmap);
    return glyph;
}

fn copyCover(glyph: *Glyph, bitmap: ft.FT_Bitmap) void {
    if (bitmap.buffer == null or bitmap.pixel_mode != ft.FT_PIXEL_MODE_GRAY) return;
    const w: u32 = @min(bitmap.width, max_side);
    const h: u32 = @min(bitmap.rows, max_side);
    glyph.w = @intCast(w);
    glyph.h = @intCast(h);
    const pitch: i32 = bitmap.pitch;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src_row = rowOffset(pitch, y);
        const dest = glyph.cover[y * max_side ..][0..w];
        @memcpy(dest, bitmap.buffer[src_row..][0..w]);
    }
}

fn rowOffset(pitch: i32, y: u32) usize {
    if (pitch >= 0) return @as(usize, @intCast(pitch)) * y;
    const stride: usize = @intCast(-pitch);
    return stride * y;
}

const testing = core.testing;

fn firstInstalled() ?[:0]const u8 {
    const paths = [_][:0]const u8{
        "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
        "/usr/share/fonts/TTF/IBMPlexMono-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/apple-fonts/SF-Mono-Regular.otf",
    };
    for (paths) |path| {
        std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch continue;
        return path;
    }
    return null;
}

test "Face.openPath - rasterizes ASCII from a system mono font" {
    const path = firstInstalled() orelse return error.SkipZigTest;
    const face = try Face.openPath(testing.allocator, path, 14);
    defer face.deinit();
    try testing.expect(face.line_height >= 10);
    try testing.expect(face.cell >= 6);
    try testing.expect(face.glyph('A').w > 0);
    try testing.expect(face.glyph('A').h > 0);
    try testing.expect(face.glyph(' ').advance > 0);
}

test "Face.openMono - uses an installed monospace file" {
    const face = Face.openMono(testing.allocator, 13) catch |err| switch (err) {
        error.NoMonoFont, error.Fontconfig, error.FreeTypeInit, error.FreeTypeFace, error.FreeTypeSize => return error.SkipZigTest,
        else => return err,
    };
    defer face.deinit();
    try testing.expect(face.glyph('0').advance > 0);
}
