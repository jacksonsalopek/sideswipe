//! EGL/OpenGL pixel format database
//!
//! Maps DRM fourcc formats to OpenGL internal formats, types,
//! and swizzle patterns for proper texture handling.

const std = @import("std");
const testing = std.testing;

/// Vector2D type (inline to avoid module dependency)
const Vector2D = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const c = @cImport({
    @cInclude("GLES3/gl3.h");
    @cInclude("GLES2/gl2ext.h");
    @cInclude("drm_fourcc.h");
});

/// GL swizzle pattern (4 components: R, G, B, A)
pub const Swizzle = [4]c.GLint;

/// Common swizzle patterns
pub const swizzle = struct {
    pub const RGBA: Swizzle = .{ c.GL_RED, c.GL_GREEN, c.GL_BLUE, c.GL_ALPHA };
    pub const BGRA: Swizzle = .{ c.GL_BLUE, c.GL_GREEN, c.GL_RED, c.GL_ALPHA };
    pub const ARGB: Swizzle = .{ c.GL_ALPHA, c.GL_RED, c.GL_GREEN, c.GL_BLUE };
    pub const ABGR: Swizzle = .{ c.GL_ALPHA, c.GL_BLUE, c.GL_GREEN, c.GL_RED };
    pub const RGB1: Swizzle = .{ c.GL_RED, c.GL_GREEN, c.GL_BLUE, c.GL_ONE };
    pub const BGR1: Swizzle = .{ c.GL_BLUE, c.GL_GREEN, c.GL_RED, c.GL_ONE };
    pub const R001: Swizzle = .{ c.GL_RED, c.GL_ZERO, c.GL_ZERO, c.GL_ONE };
    pub const RG01: Swizzle = .{ c.GL_RED, c.GL_GREEN, c.GL_ZERO, c.GL_ONE };
    pub const GR01: Swizzle = .{ c.GL_GREEN, c.GL_RED, c.GL_ZERO, c.GL_ONE };
};

/// Pixel format descriptor
pub const PixelFormat = struct {
    /// DRM fourcc format code
    drm_format: u32 = 0,
    /// OpenGL internal format (e.g., GL_RGBA8)
    gl_internal_format: c.GLint = 0,
    /// OpenGL format (e.g., GL_RGBA)
    gl_format: c.GLenum = 0,
    /// OpenGL type (e.g., GL_UNSIGNED_BYTE)
    gl_type: c.GLenum = 0,
    /// Has alpha channel
    with_alpha: bool = true,
    /// DRM format without alpha (if this has alpha)
    alpha_stripped: u32 = 0,
    /// Bytes per pixel/block
    bytes_per_block: u32 = 0,
    /// Block size for subsampled formats (default 1x1)
    block_size: Vector2D = .{ .x = 1, .y = 1 },
    /// GL swizzle pattern (null if no swizzle needed)
    swizzle_pattern: ?Swizzle = null,

    /// Get pixels per block
    pub fn pixelsPerBlock(self: PixelFormat) u32 {
        const block_pixels = @as(u32, @intFromFloat(self.block_size.x)) *
            @as(u32, @intFromFloat(self.block_size.y));
        return if (block_pixels > 0) block_pixels else 1;
    }

    /// Calculate minimum stride for given width
    pub fn minStride(self: PixelFormat, width: u32) u32 {
        const pixels_per_blk = self.pixelsPerBlock();
        const width_f: f64 = @floatFromInt(width);
        const bytes_f: f64 = @floatFromInt(self.bytes_per_block);
        const ppb_f: f64 = @floatFromInt(pixels_per_blk);
        return @intFromFloat(@ceil((width_f * bytes_f) / ppb_f));
    }
};

/// GLES3 pixel format database
pub const formats = [_]PixelFormat{
    // ARGB8888
    .{
        .drm_format = c.DRM_FORMAT_ARGB8888,
        .gl_internal_format = c.GL_RGBA8,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_XRGB8888,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.BGRA,
    },
    // XRGB8888
    .{
        .drm_format = c.DRM_FORMAT_XRGB8888,
        .gl_internal_format = c.GL_RGBA8,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_XRGB8888,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.BGR1,
    },
    // XBGR8888
    .{
        .drm_format = c.DRM_FORMAT_XBGR8888,
        .gl_internal_format = c.GL_RGBA8,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_XBGR8888,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.RGB1,
    },
    // ABGR8888
    .{
        .drm_format = c.DRM_FORMAT_ABGR8888,
        .gl_internal_format = c.GL_RGBA8,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_XBGR8888,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.RGBA,
    },
    // BGR888
    .{
        .drm_format = c.DRM_FORMAT_BGR888,
        .gl_internal_format = c.GL_RGB8,
        .gl_format = c.GL_RGB,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_BGR888,
        .bytes_per_block = 3,
        .swizzle_pattern = swizzle.RGB1,
    },
    // RGBX4444
    .{
        .drm_format = c.DRM_FORMAT_RGBX4444,
        .gl_internal_format = c.GL_RGBA4,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_SHORT_4_4_4_4,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_RGBX4444,
        .bytes_per_block = 2,
        .swizzle_pattern = swizzle.RGB1,
    },
    // RGBA4444
    .{
        .drm_format = c.DRM_FORMAT_RGBA4444,
        .gl_internal_format = c.GL_RGBA4,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_SHORT_4_4_4_4,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_RGBX4444,
        .bytes_per_block = 2,
        .swizzle_pattern = swizzle.RGBA,
    },
    // RGBX5551
    .{
        .drm_format = c.DRM_FORMAT_RGBX5551,
        .gl_internal_format = c.GL_RGB5_A1,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_SHORT_5_5_5_1,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_RGBX5551,
        .bytes_per_block = 2,
        .swizzle_pattern = swizzle.RGB1,
    },
    // RGBA5551
    .{
        .drm_format = c.DRM_FORMAT_RGBA5551,
        .gl_internal_format = c.GL_RGB5_A1,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_SHORT_5_5_5_1,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_RGBX5551,
        .bytes_per_block = 2,
        .swizzle_pattern = swizzle.RGBA,
    },
    // RGB565
    .{
        .drm_format = c.DRM_FORMAT_RGB565,
        .gl_internal_format = c.GL_RGB565,
        .gl_format = c.GL_RGB,
        .gl_type = c.GL_UNSIGNED_SHORT_5_6_5,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_RGB565,
        .bytes_per_block = 2,
        .swizzle_pattern = swizzle.RGB1,
    },
    // XBGR2101010
    .{
        .drm_format = c.DRM_FORMAT_XBGR2101010,
        .gl_internal_format = c.GL_RGB10_A2,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_INT_2_10_10_10_REV,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_XBGR2101010,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.RGB1,
    },
    // ABGR2101010
    .{
        .drm_format = c.DRM_FORMAT_ABGR2101010,
        .gl_internal_format = c.GL_RGB10_A2,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_INT_2_10_10_10_REV,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_XBGR2101010,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.RGBA,
    },
    // XRGB2101010
    .{
        .drm_format = c.DRM_FORMAT_XRGB2101010,
        .gl_internal_format = c.GL_RGB10_A2,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_INT_2_10_10_10_REV,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_XRGB2101010,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.BGR1,
    },
    // ARGB2101010
    .{
        .drm_format = c.DRM_FORMAT_ARGB2101010,
        .gl_internal_format = c.GL_RGB10_A2,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_UNSIGNED_INT_2_10_10_10_REV,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_XRGB2101010,
        .bytes_per_block = 4,
        .swizzle_pattern = swizzle.BGRA,
    },
    // XBGR16161616F (half-float)
    .{
        .drm_format = c.DRM_FORMAT_XBGR16161616F,
        .gl_internal_format = c.GL_RGBA16F,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_HALF_FLOAT,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_XBGR16161616F,
        .bytes_per_block = 8,
        .swizzle_pattern = swizzle.RGB1,
    },
    // ABGR16161616F (half-float)
    .{
        .drm_format = c.DRM_FORMAT_ABGR16161616F,
        .gl_internal_format = c.GL_RGBA16F,
        .gl_format = c.GL_RGBA,
        .gl_type = c.GL_HALF_FLOAT,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_XBGR16161616F,
        .bytes_per_block = 8,
        .swizzle_pattern = swizzle.RGBA,
    },
    // XBGR16161616 (16-bit integer)
    .{
        .drm_format = c.DRM_FORMAT_XBGR16161616,
        .gl_internal_format = c.GL_RGBA16UI,
        .gl_format = c.GL_RGBA_INTEGER,
        .gl_type = c.GL_UNSIGNED_SHORT,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_XBGR16161616,
        .bytes_per_block = 8,
        .swizzle_pattern = swizzle.RGBA,
    },
    // ABGR16161616 (16-bit integer)
    .{
        .drm_format = c.DRM_FORMAT_ABGR16161616,
        .gl_internal_format = c.GL_RGBA16UI,
        .gl_format = c.GL_RGBA_INTEGER,
        .gl_type = c.GL_UNSIGNED_SHORT,
        .with_alpha = true,
        .alpha_stripped = c.DRM_FORMAT_XBGR16161616,
        .bytes_per_block = 8,
        .swizzle_pattern = swizzle.RGBA,
    },
    // YVYU (YUV 4:2:2, subsampled)
    .{
        .drm_format = c.DRM_FORMAT_YVYU,
        .bytes_per_block = 4,
        .block_size = .{ .x = 2, .y = 1 },
    },
    // VYUY (YUV 4:2:2, subsampled)
    .{
        .drm_format = c.DRM_FORMAT_VYUY,
        .bytes_per_block = 4,
        .block_size = .{ .x = 2, .y = 1 },
    },
    // R8 (single channel)
    .{
        .drm_format = c.DRM_FORMAT_R8,
        .gl_internal_format = c.GL_R8,
        .gl_format = c.GL_RED,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = false,
        .bytes_per_block = 1,
        .swizzle_pattern = swizzle.R001,
    },
    // GR88 (two channel)
    .{
        .drm_format = c.DRM_FORMAT_GR88,
        .gl_internal_format = c.GL_RG8,
        .gl_format = c.GL_RG,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = false,
        .bytes_per_block = 2,
        .swizzle_pattern = swizzle.RG01,
    },
    // RGB888
    .{
        .drm_format = c.DRM_FORMAT_RGB888,
        .gl_internal_format = c.GL_RGB8,
        .gl_format = c.GL_RGB,
        .gl_type = c.GL_UNSIGNED_BYTE,
        .with_alpha = false,
        .alpha_stripped = c.DRM_FORMAT_RGB888,
        .bytes_per_block = 3,
        .swizzle_pattern = swizzle.BGR1,
    },
};

/// Get pixel format from DRM fourcc code
pub fn getPixelFormatFromDRM(drm_format: u32) ?*const PixelFormat {
    for (&formats) |*fmt| {
        if (fmt.drm_format == drm_format) return fmt;
    }
    return null;
}

/// Get pixel format from GL format and type
pub fn getPixelFormatFromGL(gl_format: c.GLenum, gl_type: c.GLenum, with_alpha: bool) ?*const PixelFormat {
    for (&formats) |*fmt| {
        if (fmt.gl_format == @as(c.GLint, @intCast(gl_format)) and
            fmt.gl_type == @as(c.GLint, @intCast(gl_type)) and
            fmt.with_alpha == with_alpha)
        {
            return fmt;
        }
    }
    return null;
}

/// Check if DRM format is opaque (no alpha)
pub fn isDrmFormatOpaque(drm_format: u32) bool {
    const fmt = getPixelFormatFromDRM(drm_format) orelse return false;
    return !fmt.with_alpha;
}

// Tests

test "format lookup - ARGB8888" {
    const fmt = getPixelFormatFromDRM(c.DRM_FORMAT_ARGB8888).?;
    try testing.expectEqual(@as(u32, c.DRM_FORMAT_ARGB8888), fmt.drm_format);
    try testing.expect(fmt.with_alpha);
    try testing.expectEqual(@as(u32, 4), fmt.bytes_per_block);
    try testing.expectEqual(@as(u32, c.DRM_FORMAT_XRGB8888), fmt.alpha_stripped);
}

test "format lookup - RGB565" {
    const fmt = getPixelFormatFromDRM(c.DRM_FORMAT_RGB565).?;
    try testing.expectEqual(@as(u32, c.DRM_FORMAT_RGB565), fmt.drm_format);
    try testing.expect(!fmt.with_alpha);
    try testing.expectEqual(@as(u32, 2), fmt.bytes_per_block);
}

test "format opacity check" {
    try testing.expect(!isDrmFormatOpaque(c.DRM_FORMAT_ARGB8888));
    try testing.expect(isDrmFormatOpaque(c.DRM_FORMAT_XRGB8888));
    try testing.expect(isDrmFormatOpaque(c.DRM_FORMAT_RGB565));
}

test "format stride calculation" {
    const fmt = getPixelFormatFromDRM(c.DRM_FORMAT_ARGB8888).?;
    const stride = fmt.minStride(1920);
    try testing.expectEqual(@as(u32, 1920 * 4), stride);
}

test "subsampled format - YVYU" {
    const fmt = getPixelFormatFromDRM(c.DRM_FORMAT_YVYU).?;
    try testing.expectEqual(@as(u32, 4), fmt.bytes_per_block);
    try testing.expectEqual(@as(f32, 2), fmt.block_size.x);
    try testing.expectEqual(@as(u32, 2), fmt.pixelsPerBlock());
}

test "GL format lookup" {
    // GL_RGBA with UNSIGNED_BYTE and alpha can match ARGB8888 or ABGR8888
    // depending on swizzle - just verify we find a valid format
    const fmt = getPixelFormatFromGL(c.GL_RGBA, c.GL_UNSIGNED_BYTE, true).?;
    try testing.expect(fmt.with_alpha);
    try testing.expectEqual(@as(u32, 4), fmt.bytes_per_block);
}
