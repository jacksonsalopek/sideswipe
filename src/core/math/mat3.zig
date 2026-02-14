//! Generic 3x3 matrix for transformations and color management
//!
//! Supports both f32 (graphics transforms) and f64 (color management)

const std = @import("std");
const testing = std.testing;

/// Generic 3x3 matrix
pub fn Matrix3(comptime T: type) type {
    if (T != f32 and T != f64) {
        @compileError("Matrix3 only supports f32 and f64");
    }

    return struct {
        m: [3][3]T,

        const Self = @This();

        /// Identity matrix
        pub const identity = Self{
            .m = .{
                .{ 1, 0, 0 },
                .{ 0, 1, 0 },
                .{ 0, 0, 1 },
            },
        };

        /// Initialize from 2D array
        pub fn init(values: [3][3]T) Self {
            return .{ .m = values };
        }

        /// Initialize from flat array (row-major)
        pub fn initFlat(values: [9]T) Self {
            return .{
                .m = .{
                    .{ values[0], values[1], values[2] },
                    .{ values[3], values[4], values[5] },
                    .{ values[6], values[7], values[8] },
                },
            };
        }

        /// Get as flat array (row-major)
        pub fn toFlat(self: Self) [9]T {
            return .{
                self.m[0][0], self.m[0][1], self.m[0][2],
                self.m[1][0], self.m[1][1], self.m[1][2],
                self.m[2][0], self.m[2][1], self.m[2][2],
            };
        }

        /// Compute determinant
        pub fn determinant(self: Self) T {
            return self.m[0][0] * (self.m[1][1] * self.m[2][2] - self.m[2][1] * self.m[1][2]) -
                self.m[0][1] * (self.m[1][0] * self.m[2][2] - self.m[1][2] * self.m[2][0]) +
                self.m[0][2] * (self.m[1][0] * self.m[2][1] - self.m[1][1] * self.m[2][0]);
        }

        /// Compute matrix inverse
        pub fn invert(self: Self) Self {
            const det = 1.0 / self.determinant();

            return Self{
                .m = .{
                    .{
                        (self.m[1][1] * self.m[2][2] - self.m[2][1] * self.m[1][2]) * det,
                        (self.m[0][2] * self.m[2][1] - self.m[0][1] * self.m[2][2]) * det,
                        (self.m[0][1] * self.m[1][2] - self.m[0][2] * self.m[1][1]) * det,
                    },
                    .{
                        (self.m[1][2] * self.m[2][0] - self.m[1][0] * self.m[2][2]) * det,
                        (self.m[0][0] * self.m[2][2] - self.m[0][2] * self.m[2][0]) * det,
                        (self.m[1][0] * self.m[0][2] - self.m[0][0] * self.m[1][2]) * det,
                    },
                    .{
                        (self.m[1][0] * self.m[2][1] - self.m[2][0] * self.m[1][1]) * det,
                        (self.m[2][0] * self.m[0][1] - self.m[0][0] * self.m[2][1]) * det,
                        (self.m[0][0] * self.m[1][1] - self.m[1][0] * self.m[0][1]) * det,
                    },
                },
            };
        }

        /// Multiply two matrices
        pub fn mul(self: Self, other: Self) Self {
            var result: Self = undefined;
            for (0..3) |i| {
                for (0..3) |j| {
                    result.m[i][j] = 0;
                    for (0..3) |k| {
                        result.m[i][j] += self.m[i][k] * other.m[k][j];
                    }
                }
            }
            return result;
        }

        /// Transpose matrix
        pub fn transpose(self: Self) Self {
            return Self{
                .m = .{
                    .{ self.m[0][0], self.m[1][0], self.m[2][0] },
                    .{ self.m[0][1], self.m[1][1], self.m[2][1] },
                    .{ self.m[0][2], self.m[1][2], self.m[2][2] },
                },
            };
        }

        /// Multiply matrix by 3D vector
        pub fn mulVec3(self: Self, vec: [3]T) [3]T {
            return .{
                (self.m[0][0] * vec[0]) + (self.m[0][1] * vec[1]) + (self.m[0][2] * vec[2]),
                (self.m[1][0] * vec[0]) + (self.m[1][1] * vec[1]) + (self.m[1][2] * vec[2]),
                (self.m[2][0] * vec[0]) + (self.m[2][1] * vec[1]) + (self.m[2][2] * vec[2]),
            };
        }
    };
}

// Type aliases
pub const Mat3f32 = Matrix3(f32);
pub const Mat3f64 = Matrix3(f64);

// Tests

test "Matrix3(f32) - identity" {
    const m = Mat3f32.identity;
    try testing.expectEqual(@as(f32, 1), m.m[0][0]);
    try testing.expectEqual(@as(f32, 1), m.m[1][1]);
    try testing.expectEqual(@as(f32, 1), m.m[2][2]);
    try testing.expectEqual(@as(f32, 0), m.m[0][1]);
}

test "Matrix3(f64) - identity" {
    const m = Mat3f64.identity;
    try testing.expectEqual(@as(f64, 1), m.m[0][0]);
    try testing.expectEqual(@as(f64, 1), m.m[1][1]);
    try testing.expectEqual(@as(f64, 1), m.m[2][2]);
    try testing.expectEqual(@as(f64, 0), m.m[0][1]);
}

test "Matrix3 - determinant" {
    const m = Mat3f32.init(.{
        .{ 1, 2, 3 },
        .{ 0, 1, 4 },
        .{ 5, 6, 0 },
    });
    
    const det = m.determinant();
    try testing.expectEqual(@as(f32, 1), det);
}

test "Matrix3 - inversion" {
    const m = Mat3f32.init(.{
        .{ 1, 2, 3 },
        .{ 0, 1, 4 },
        .{ 5, 6, 0 },
    });
    
    const inv = m.invert();
    const result = m.mul(inv);
    
    // Result should be approximately identity
    try testing.expectApproxEqAbs(@as(f32, 1), result.m[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), result.m[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), result.m[2][2], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), result.m[0][1], 0.0001);
}

test "Matrix3 - multiplication" {
    const m1 = Mat3f32.init(.{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
    });
    
    const m2 = Mat3f32.identity;
    const result = m1.mul(m2);
    
    // M * I = M
    try testing.expectEqual(m1.m[0][0], result.m[0][0]);
    try testing.expectEqual(m1.m[1][1], result.m[1][1]);
    try testing.expectEqual(m1.m[2][2], result.m[2][2]);
}

test "Matrix3 - transpose" {
    const m = Mat3f32.init(.{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
        .{ 7, 8, 9 },
    });
    
    const t = m.transpose();
    
    try testing.expectEqual(@as(f32, 1), t.m[0][0]);
    try testing.expectEqual(@as(f32, 4), t.m[0][1]);
    try testing.expectEqual(@as(f32, 7), t.m[0][2]);
    try testing.expectEqual(@as(f32, 2), t.m[1][0]);
}

test "Matrix3 - vector multiplication" {
    const m = Mat3f32.init(.{
        .{ 2, 0, 0 },
        .{ 0, 3, 0 },
        .{ 0, 0, 1 },
    });
    
    const vec = [3]f32{ 1, 1, 1 };
    const result = m.mulVec3(vec);
    
    try testing.expectEqual(@as(f32, 2), result[0]);
    try testing.expectEqual(@as(f32, 3), result[1]);
    try testing.expectEqual(@as(f32, 1), result[2]);
}

test "Matrix3 - flat array conversion" {
    const flat = [9]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const m = Mat3f32.initFlat(flat);
    const back = m.toFlat();
    
    try testing.expectEqualSlices(f32, &flat, &back);
}

test "Matrix3(f64) - high precision color operations" {
    const m = Mat3f64.init(.{
        .{ 0.4124564, 0.3575761, 0.1804375 },
        .{ 0.2126729, 0.7151522, 0.0721750 },
        .{ 0.0193339, 0.1191920, 0.9503041 },
    });
    
    const vec = [3]f64{ 1.0, 1.0, 1.0 };
    const result = m.mulVec3(vec);
    
    // D65 white point conversion
    try testing.expectApproxEqAbs(@as(f64, 0.9505), result[0], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result[1], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0889), result[2], 0.001);
}
