//! Color space conversions and color management
//!
//! Provides conversions between sRGB, HSL, OkLab color spaces,
//! gamma correction, and CIE color primaries for color management.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const core_math = @import("core.math");

/// 3x3 matrix for color transformations (uses f64 for precision)
pub const Matrix3 = core_math.mat3.Matrix3(f64);

/// sRGB color (0.0 - 1.0, gamma-encoded)
pub const SRGB = struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,
};

/// HSL color (0.0 - 1.0)
pub const HSL = struct {
    h: f64 = 0, // hue
    s: f64 = 0, // saturation
    l: f64 = 0, // lightness
};

/// OkLab perceptually uniform color space (0.0 - 1.0)
pub const OkLab = struct {
    l: f64 = 0, // lightness
    a: f64 = 0, // green-red
    b: f64 = 0, // blue-yellow
};

/// CIE xy chromaticity coordinates (0.0 - 1.0)
pub const XY = struct {
    x: f64 = 0,
    y: f64 = 0,
};

/// CIE XYZ tristimulus values
pub const XYZ = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,

    /// Per-component division
    pub fn div(self: XYZ, other: XYZ) XYZ {
        return .{
            .x = self.x / other.x,
            .y = self.y / other.y,
            .z = self.z / other.z,
        };
    }
};

/// Helper to multiply matrix by XYZ color
fn mulXYZ(m: Matrix3, xyz: XYZ) XYZ {
    const vec = m.mulVec3(.{ xyz.x, xyz.y, xyz.z });
    return .{ .x = vec[0], .y = vec[1], .z = vec[2] };
}

/// Bradford chromatic adaptation matrix
const Bradford = Matrix3.init(.{
    .{ 0.8951, 0.2664, -0.1614 },
    .{ -0.7502, 1.7135, 0.0367 },
    .{ 0.0389, -0.0685, 1.0296 },
});

/// CIE color primaries for a color space
pub const Primaries = struct {
    red: XY,
    green: XY,
    blue: XY,
    white: XY,

    /// Convert primaries to XYZ color space matrix
    pub fn toXYZ(self: Primaries) Matrix3 {
        const r = xy2xyz(self.red);
        const g = xy2xyz(self.green);
        const b = xy2xyz(self.blue);
        const w = xy2xyz(self.white);

        const mat = Matrix3.init(.{
            .{ r.x, g.x, b.x },
            .{ r.y, g.y, b.y },
            .{ r.z, g.z, b.z },
        });
        const inv_mat = mat.invert();

        const s = mulXYZ(inv_mat, w);

        return Matrix3.init(.{
            .{ s.x * r.x, s.y * g.x, s.z * b.x },
            .{ s.x * r.y, s.y * g.y, s.z * b.y },
            .{ s.x * r.z, s.y * g.z, s.z * b.z },
        });
    }

    /// Get conversion matrix to destination primaries
    pub fn convertMatrix(self: Primaries, dst: Primaries) Matrix3 {
        const dst_xyz = dst.toXYZ();
        const adapt = adaptWhite(self.white, dst.white);
        const src_xyz = self.toXYZ();
        return dst_xyz.invert().mul(adapt).mul(src_xyz);
    }
};

/// Convert gamma-encoded to linear
fn gammaToLinear(value: f64) f64 {
    return if (value >= 0.04045)
        math.pow(f64, (value + 0.055) / 1.055, 2.4)
    else
        value / 12.92;
}

/// Convert linear to gamma-encoded
fn linearToGamma(value: f64) f64 {
    return if (value >= 0.0031308)
        (1.055 * math.pow(f64, value, 0.41666666666)) - 0.055
    else
        12.92 * value;
}

/// Helper for HSL to RGB conversion
fn hueToRgb(p: f64, q: f64, t_in: f64) f64 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + ((q - p) * 6.0 * t);
    if (t < 1.0 / 2.0) return q;
    if (t < 2.0 / 3.0) return p + ((q - p) * (2.0 / 3.0 - t) * 6.0);
    return p;
}

/// Convert xy chromaticity to XYZ
pub fn xy2xyz(xy: XY) XYZ {
    if (xy.y == 0.0) return .{ .x = 0, .y = 0, .z = 0 };

    return .{
        .x = xy.x / xy.y,
        .y = 1.0,
        .z = (1.0 - xy.x - xy.y) / xy.y,
    };
}

/// Adapt white point from source to destination
pub fn adaptWhite(src: XY, dst: XY) Matrix3 {
    if (src.x == dst.x and src.y == dst.y) return Matrix3.identity;

    const src_xyz = xy2xyz(src);
    const dst_xyz = xy2xyz(dst);

    const bradford_inv = Bradford.invert();
    const factors = (mulXYZ(Bradford, dst_xyz)).div(mulXYZ(Bradford, src_xyz));

    const scale = Matrix3.init(.{
        .{ factors.x, 0, 0 },
        .{ 0, factors.y, 0 },
        .{ 0, 0, factors.z },
    });

    return bradford_inv.mul(scale).mul(Bradford);
}

/// Color representation (stored internally as sRGB)
pub const Color = struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,

    /// Create black color
    pub fn init() Color {
        return .{};
    }

    /// Create from sRGB values
    pub fn fromSRGB(rgb: SRGB) Color {
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }

    /// Create from HSL values
    pub fn fromHSL(hsl: HSL) Color {
        if (hsl.s <= 0) {
            return .{ .r = hsl.l, .g = hsl.l, .b = hsl.l };
        }

        const q = if (hsl.l < 0.5)
            hsl.l * (1.0 + hsl.s)
        else
            hsl.l + hsl.s - (hsl.l * hsl.s);

        const p = (2.0 * hsl.l) - q;

        return .{
            .r = hueToRgb(p, q, hsl.h + (1.0 / 3.0)),
            .g = hueToRgb(p, q, hsl.h),
            .b = hueToRgb(p, q, hsl.h - (1.0 / 3.0)),
        };
    }

    /// Create from OkLab values
    pub fn fromOkLab(lab: OkLab) Color {
        const l = math.pow(f64, lab.l + (lab.a * 0.3963377774) + (lab.b * 0.2158037573), 3);
        const m = math.pow(f64, lab.l + (lab.a * -0.1055613458) + (lab.b * -0.0638541728), 3);
        const s = math.pow(f64, lab.l + (lab.a * -0.0894841775) + (lab.b * -1.2914855480), 3);

        return .{
            .r = linearToGamma((l * 4.0767416621) + (m * -3.3077115913) + (s * 0.2309699292)),
            .g = linearToGamma((l * -1.2684380046) + (m * 2.6097574011) + (s * -0.3413193965)),
            .b = linearToGamma((l * -0.0041960863) + (m * -0.7034186147) + (s * 1.7076147010)),
        };
    }

    /// Convert to sRGB
    pub fn toSRGB(self: Color) SRGB {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    /// Convert to HSL
    pub fn toHSL(self: Color) HSL {
        const vmax = @max(self.r, @max(self.g, self.b));
        const vmin = @min(self.r, @min(self.g, self.b));
        const l = (vmax + vmin) / 2.0;

        if (vmax == vmin) {
            return .{ .h = 0, .s = 0, .l = l };
        }

        const d = vmax - vmin;
        const s = if (l > 0.5) d / (2.0 - vmax - vmin) else d / (vmax + vmin);

        var h: f64 = 0;
        if (vmax == self.r) {
            const offset: f64 = if (self.g < self.b) 6.0 else 0.0;
            h = (self.g - self.b) / d + offset;
        } else if (vmax == self.g) {
            h = (self.b - self.r) / d + 2.0;
        } else if (vmax == self.b) {
            h = (self.r - self.g) / d + 4.0;
        }
        h /= 6.0;

        return .{ .h = h, .s = s, .l = l };
    }

    /// Convert to OkLab
    pub fn toOkLab(self: Color) OkLab {
        const lin_r = gammaToLinear(self.r);
        const lin_g = gammaToLinear(self.g);
        const lin_b = gammaToLinear(self.b);

        const l = math.cbrt((0.4122214708 * lin_r) + (0.5363325363 * lin_g) + (0.0514459929 * lin_b));
        const m = math.cbrt((0.2119034982 * lin_r) + (0.6806995451 * lin_g) + (0.1073969566 * lin_b));
        const s = math.cbrt((0.0883024619 * lin_r) + (0.2817188376 * lin_g) + (0.6299787005 * lin_b));

        return .{
            .l = (l * 0.2104542553) + (m * 0.7936177850) + (s * -0.0040720468),
            .a = (l * 1.9779984951) + (m * -2.4285922050) + (s * 0.4505937099),
            .b = (l * 0.0259040371) + (m * 0.7827717662) + (s * -0.8086757660),
        };
    }
};

// Tests

test "Color - sRGB black" {
    const black = Color.init();
    const rgb = black.toSRGB();
    try testing.expectEqual(@as(f64, 0), rgb.r);
    try testing.expectEqual(@as(f64, 0), rgb.g);
    try testing.expectEqual(@as(f64, 0), rgb.b);
}

test "Color - sRGB to HSL conversion" {
    const red = Color.fromSRGB(.{ .r = 1.0, .g = 0, .b = 0 });
    const hsl = red.toHSL();
    try testing.expectApproxEqAbs(@as(f64, 0), hsl.h, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), hsl.s, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.5), hsl.l, 0.001);
}

test "Color - HSL to sRGB conversion" {
    const hsl = HSL{ .h = 0, .s = 1.0, .l = 0.5 }; // Red
    const color = Color.fromHSL(hsl);
    try testing.expectApproxEqAbs(@as(f64, 1.0), color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0), color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0), color.b, 0.001);
}

test "Color - OkLab round-trip" {
    const original = Color.fromSRGB(.{ .r = 0.5, .g = 0.7, .b = 0.3 });
    const lab = original.toOkLab();
    const back = Color.fromOkLab(lab);
    
    try testing.expectApproxEqAbs(original.r, back.r, 0.001);
    try testing.expectApproxEqAbs(original.g, back.g, 0.001);
    try testing.expectApproxEqAbs(original.b, back.b, 0.001);
}

test "Matrix3 - identity" {
    const m = Matrix3.identity;
    try testing.expectEqual(@as(f64, 1), m.m[0][0]);
    try testing.expectEqual(@as(f64, 1), m.m[1][1]);
    try testing.expectEqual(@as(f64, 1), m.m[2][2]);
    try testing.expectEqual(@as(f64, 0), m.m[0][1]);
}

test "Matrix3 - inversion" {
    const m = Matrix3{
        .m = .{
            .{ 1, 2, 3 },
            .{ 0, 1, 4 },
            .{ 5, 6, 0 },
        },
    };
    
    const inv = m.invert();
    const result = m.mul(inv);
    
    // Result should be approximately identity
    try testing.expectApproxEqAbs(@as(f64, 1), result.m[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), result.m[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1), result.m[2][2], 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0), result.m[0][1], 0.0001);
}

test "xy2xyz - conversion" {
    const xy = XY{ .x = 0.3127, .y = 0.3290 }; // D65 white point
    const xyz = xy2xyz(xy);
    
    try testing.expectApproxEqAbs(@as(f64, 0.9505), xyz.x, 0.001);
    try testing.expectEqual(@as(f64, 1.0), xyz.y);
    try testing.expectApproxEqAbs(@as(f64, 1.0890), xyz.z, 0.001);
}

test "Primaries - sRGB to XYZ" {
    const srgb = Primaries{
        .red = .{ .x = 0.64, .y = 0.33 },
        .green = .{ .x = 0.30, .y = 0.60 },
        .blue = .{ .x = 0.15, .y = 0.06 },
        .white = .{ .x = 0.3127, .y = 0.3290 }, // D65
    };
    
    const xyz_matrix = srgb.toXYZ();
    
    // Verify matrix is not all zeros
    var sum: f64 = 0;
    for (0..3) |i| {
        for (0..3) |j| {
            sum += @abs(xyz_matrix.m[i][j]);
        }
    }
    try testing.expect(sum > 1.0);
}
