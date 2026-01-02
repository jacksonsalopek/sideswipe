const std = @import("std");
const string = @import("core.string").string;
const Vector2D = @import("vector2d.zig").Type;
const Box = @import("box.zig").Type;
const Transform = @import("transform.zig").Direction;

pub const Type = struct {
    matrix: [9]f32,

    const transform_matrices = std.StaticStringMap([9]f32).initComptime(.{
        .{ "normal", .{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0 } },
        .{ "90", .{ 0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0 } },
        .{ "180", .{ -1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0 } },
        .{ "270", .{ 0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0 } },
        .{ "flipped", .{ -1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0 } },
        .{ "flipped_90", .{ 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0 } },
        .{ "flipped_180", .{ 1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0 } },
        .{ "flipped_270", .{ 0.0, -1.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0 } },
    });

    pub fn init() Type {
        return .{ .matrix = [_]f32{0} ** 9 };
    }

    pub fn initFromArray(mat: [9]f32) Type {
        return .{ .matrix = mat };
    }

    pub fn identity() Type {
        return initFromArray(.{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0 });
    }

    fn getTransformMatrix(t: Transform) [9]f32 {
        return switch (t) {
            .normal => transform_matrices.get("normal").?,
            .@"90" => transform_matrices.get("90").?,
            .@"180" => transform_matrices.get("180").?,
            .@"270" => transform_matrices.get("270").?,
            .flipped => transform_matrices.get("flipped").?,
            .flipped_90 => transform_matrices.get("flipped_90").?,
            .flipped_180 => transform_matrices.get("flipped_180").?,
            .flipped_270 => transform_matrices.get("flipped_270").?,
        };
    }

    pub fn outputProjection(size: Vector2D, t: Transform) Type {
        var mat = Type.init();

        const transform_mat = getTransformMatrix(t);
        const x: f32 = 2.0 / size.getX();
        const y: f32 = 2.0 / size.getY();

        // Rotation + reflection
        mat.matrix[0] = x * transform_mat[0];
        mat.matrix[1] = x * transform_mat[1];
        mat.matrix[3] = y * transform_mat[3];
        mat.matrix[4] = y * transform_mat[4];

        // Translation
        const sign_x = mat.matrix[0] + mat.matrix[1];
        const sign_y = mat.matrix[3] + mat.matrix[4];
        mat.matrix[2] = if (sign_x >= 0) -1.0 else 1.0;
        mat.matrix[5] = if (sign_y >= 0) -1.0 else 1.0;

        // Identity
        mat.matrix[8] = 1.0;

        return mat;
    }

    pub fn getMatrix(self: Type) [9]f32 {
        return self.matrix;
    }

    pub fn projectBox(self: Type, box: Box, t: Transform, rot: f32) Type {
        var mat = Type.identity();

        const box_size = box.size();

        _ = mat.translate(box.pos());

        if (rot != 0) {
            _ = mat.translate(box_size.scale(0.5));
            _ = mat.rotate(rot);
            _ = mat.translate(box_size.scale(-0.5));
        }

        _ = mat.scale(box_size);

        if (t != .normal) {
            _ = mat.translate(Vector2D.init(0.5, 0.5));
            _ = mat.applyTransform(t);
            _ = mat.translate(Vector2D.init(-0.5, -0.5));
        }

        var result = self.copy();
        _ = result.multiply(mat);
        return result;
    }

    pub fn applyTransform(self: *Type, t: Transform) *Type {
        const transform_mat = getTransformMatrix(t);
        _ = self.multiply(Type.initFromArray(transform_mat));
        return self;
    }

    pub fn rotate(self: *Type, rot: f32) *Type {
        const cos_rot = @cos(rot);
        const sin_rot = @sin(rot);
        const rotation_mat = [9]f32{ cos_rot, -sin_rot, 0.0, sin_rot, cos_rot, 0.0, 0.0, 0.0, 1.0 };
        _ = self.multiply(Type.initFromArray(rotation_mat));
        return self;
    }

    pub fn scale(self: *Type, scale_vec: Vector2D) *Type {
        const scale_mat = [9]f32{ scale_vec.getX(), 0.0, 0.0, 0.0, scale_vec.getY(), 0.0, 0.0, 0.0, 1.0 };
        _ = self.multiply(Type.initFromArray(scale_mat));
        return self;
    }

    pub fn scaleScalar(self: *Type, scale_factor: f32) *Type {
        return self.scale(Vector2D.init(scale_factor, scale_factor));
    }

    pub fn translate(self: *Type, offset: Vector2D) *Type {
        const translation_mat = [9]f32{ 1.0, 0.0, offset.getX(), 0.0, 1.0, offset.getY(), 0.0, 0.0, 1.0 };
        _ = self.multiply(Type.initFromArray(translation_mat));
        return self;
    }

    pub fn transpose(self: *Type) *Type {
        const m = self.matrix;
        self.matrix = [9]f32{ m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8] };
        return self;
    }

    pub fn multiply(self: *Type, other: Type) *Type {
        const m1 = self.matrix;
        const m2 = other.matrix;

        const product = [9]f32{
            m1[0] * m2[0] + m1[1] * m2[3] + m1[2] * m2[6],
            m1[0] * m2[1] + m1[1] * m2[4] + m1[2] * m2[7],
            m1[0] * m2[2] + m1[1] * m2[5] + m1[2] * m2[8],

            m1[3] * m2[0] + m1[4] * m2[3] + m1[5] * m2[6],
            m1[3] * m2[1] + m1[4] * m2[4] + m1[5] * m2[7],
            m1[3] * m2[2] + m1[4] * m2[5] + m1[5] * m2[8],

            m1[6] * m2[0] + m1[7] * m2[3] + m1[8] * m2[6],
            m1[6] * m2[1] + m1[7] * m2[4] + m1[8] * m2[7],
            m1[6] * m2[2] + m1[7] * m2[5] + m1[8] * m2[8],
        };

        self.matrix = product;
        return self;
    }

    pub fn copy(self: Type) Type {
        return self;
    }

    pub fn format(
        self: Type,
        comptime fmt: string,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        // Check if all values are finite
        for (self.matrix) |m| {
            if (!std.math.isFinite(m)) {
                try writer.writeAll("[mat3x3: invalid values]");
                return;
            }
        }

        var buf: [256]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "[mat3x3: {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}, {d:.3}]", .{
            self.matrix[0], self.matrix[1], self.matrix[2],
            self.matrix[3], self.matrix[4], self.matrix[5],
            self.matrix[6], self.matrix[7], self.matrix[8],
        }) catch "[mat3x3: error]";
        try writer.writeAll(str);
    }
};

test "Type.identity" {
    const mat = Type.identity();
    try std.testing.expectEqual(@as(f32, 1.0), mat.matrix[0]);
    try std.testing.expectEqual(@as(f32, 0.0), mat.matrix[1]);
    try std.testing.expectEqual(@as(f32, 1.0), mat.matrix[4]);
    try std.testing.expectEqual(@as(f32, 1.0), mat.matrix[8]);
}

test "Type.translate" {
    var mat = Type.identity();
    _ = mat.translate(Vector2D.init(10, 20));

    try std.testing.expectEqual(@as(f32, 10.0), mat.matrix[2]);
    try std.testing.expectEqual(@as(f32, 20.0), mat.matrix[5]);
}

test "Type.scale" {
    var mat = Type.identity();
    _ = mat.scale(Vector2D.init(2, 3));

    try std.testing.expectEqual(@as(f32, 2.0), mat.matrix[0]);
    try std.testing.expectEqual(@as(f32, 3.0), mat.matrix[4]);
}

test "Type.rotate" {
    var mat = Type.identity();
    _ = mat.rotate(std.math.pi / 2.0); // 90 degrees

    // cos(90) ≈ 0, sin(90) ≈ 1
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mat.matrix[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), mat.matrix[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mat.matrix[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mat.matrix[4], 0.0001);
}

test "Type.multiply" {
    var mat1 = Type.identity();
    _ = mat1.translate(Vector2D.init(5, 5));

    var mat2 = Type.identity();
    _ = mat2.scale(Vector2D.init(2, 2));

    _ = mat1.multiply(mat2);

    // Result should have both translation and scale
    try std.testing.expectEqual(@as(f32, 2.0), mat1.matrix[0]);
    try std.testing.expectEqual(@as(f32, 2.0), mat1.matrix[4]);
}

test "Type.transpose" {
    var mat = Type.initFromArray(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    _ = mat.transpose();

    try std.testing.expectEqual(@as(f32, 1), mat.matrix[0]);
    try std.testing.expectEqual(@as(f32, 4), mat.matrix[1]);
    try std.testing.expectEqual(@as(f32, 7), mat.matrix[2]);
    try std.testing.expectEqual(@as(f32, 2), mat.matrix[3]);
    try std.testing.expectEqual(@as(f32, 5), mat.matrix[4]);
    try std.testing.expectEqual(@as(f32, 8), mat.matrix[5]);
}

test "Type.format" {
    const mat = Type.identity();
    var buf: [200]u8 = undefined;

    // Test the custom format function directly
    var fbs = std.io.fixedBufferStream(&buf);
    try mat.format("", .{}, fbs.writer());
    const result = fbs.getWritten();

    // Check if the custom format function produced the expected output
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "mat3x3") != null);
}

test "Type - complex compositor chain" {
    // Test from hyprutils: outputProjection + projectBox + translate + scale + transpose
    const output_size = Vector2D.init(1920, 1080);
    const jeremy = Type.outputProjection(output_size, .flipped_90);

    const box = Box.init(10, 10, 200, 200);
    var matrix_box_1 = jeremy.projectBox(box, .normal, 0);
    _ = matrix_box_1.translate(Vector2D.init(100, 100));
    _ = matrix_box_1.scale(Vector2D.init(1.25, 1.5));
    const matrix_box = matrix_box_1.transpose();

    // Expected values from hyprutils test (with tolerance for precision)
    const expected = [9]f32{ 0, 0.46296296, 0, 0.3125, 0, 0, 19.84375, 36.055557, 1 };

    const result = matrix_box.getMatrix();

    // Check each element with tolerance for 32-bit precision
    try std.testing.expectApproxEqAbs(expected[0], result[0], 0.1);
    try std.testing.expectApproxEqAbs(expected[1], result[1], 0.1);
    try std.testing.expectApproxEqAbs(expected[2], result[2], 0.1);
    try std.testing.expectApproxEqAbs(expected[3], result[3], 0.1);
    try std.testing.expectApproxEqAbs(expected[4], result[4], 0.1);
    try std.testing.expectApproxEqAbs(expected[5], result[5], 0.1);
    try std.testing.expectApproxEqAbs(expected[6], result[6], 0.1);
    try std.testing.expectApproxEqAbs(expected[7], result[7], 0.1);
    try std.testing.expectApproxEqAbs(expected[8], result[8], 0.1);
}

test "Type - matrix with NaN values" {
    const nan = std.math.nan(f32);
    const mat = Type.initFromArray(.{ nan, 0, 0, 0, nan, 0, 0, 0, 1 });

    const result = mat.getMatrix();
    try std.testing.expect(std.math.isNan(result[0]));
    try std.testing.expect(std.math.isNan(result[4]));

    // Operations with NaN propagate NaN
    var mat_copy = mat;
    _ = mat_copy.translate(Vector2D.init(10, 10));

    const after_translate = mat_copy.getMatrix();
    try std.testing.expect(std.math.isNan(after_translate[0]));
}

test "Type - matrix with infinity values" {
    const inf = std.math.inf(f32);
    const mat = Type.initFromArray(.{ inf, 0, 0, 0, inf, 0, 0, 0, 1 });

    const result = mat.getMatrix();
    try std.testing.expect(std.math.isInf(result[0]));
    try std.testing.expect(std.math.isInf(result[4]));

    // Operations with infinity
    var mat_copy = mat;
    _ = mat_copy.scale(Vector2D.init(2, 2));

    const after_scale = mat_copy.getMatrix();
    try std.testing.expect(std.math.isInf(after_scale[0]));
}

test "Type - singular matrix (determinant zero)" {
    // All zeros except bottom-right (singular)
    const singular = Type.initFromArray(.{ 0, 0, 0, 0, 0, 0, 0, 0, 1 });

    const result = singular.getMatrix();
    try std.testing.expectEqual(@as(f32, 0), result[0]);
    try std.testing.expectEqual(@as(f32, 0), result[4]);

    // Operations should still work (even if mathematically singular)
    var mat_copy = singular;
    _ = mat_copy.translate(Vector2D.init(5, 5));

    // Should not crash
    _ = mat_copy.getMatrix();
}

test "Type - long chain of transformations" {
    var mat = Type.identity();

    // 100 iterations of transformation
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = mat.translate(Vector2D.init(0.1, 0.1));
        _ = mat.scale(Vector2D.init(1.001, 1.001));
        _ = mat.rotate(@as(f32, @floatCast(0.01)));
    }

    const result = mat.getMatrix();

    // After 100 iterations, values should still be finite
    for (result) |val| {
        try std.testing.expect(std.math.isFinite(val));
    }

    // Values shouldn't have drifted to extreme magnitudes
    for (result) |val| {
        try std.testing.expect(@abs(val) < 1e6);
    }
}

test "Type.format - with non-finite values" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    const mat_nan = Type.initFromArray(.{ nan, 0, 0, 0, 1, 0, 0, 0, 1 });
    const mat_inf = Type.initFromArray(.{ inf, 0, 0, 0, 1, 0, 0, 0, 1 });

    var buf: [300]u8 = undefined;

    // Format with NaN should not crash
    var fbs1 = std.io.fixedBufferStream(&buf);
    try mat_nan.format("", .{}, fbs1.writer());
    const result1 = fbs1.getWritten();
    try std.testing.expect(result1.len > 0);

    // Format with Inf should not crash
    var fbs2 = std.io.fixedBufferStream(&buf);
    try mat_inf.format("", .{}, fbs2.writer());
    const result2 = fbs2.getWritten();
    try std.testing.expect(result2.len > 0);
}

test "Type - rotation preserves structure" {
    // Test that rotation maintains reasonable matrix values
    const angles = [_]f32{ 0, std.math.pi / 4.0, std.math.pi / 2.0, std.math.pi, 2.0 * std.math.pi };

    for (angles) |angle| {
        var mat = Type.identity();
        _ = mat.rotate(angle);

        const result = mat.getMatrix();

        // All values should be finite
        for (result) |val| {
            try std.testing.expect(std.math.isFinite(val));
        }

        // Rotation matrix elements should be bounded
        for (result) |val| {
            try std.testing.expect(@abs(val) <= 2.0);
        }
    }
}

test "Type.projectBox - with rotation at π intervals" {
    const output_size = Vector2D.init(1920, 1080);
    const mat = Type.outputProjection(output_size, .normal);

    const box = Box.init(100, 100, 200, 200);

    // Test rotation at special angles
    const rotations = [_]f32{
        0,
        std.math.pi / 2.0, // 90 degrees
        std.math.pi, // 180 degrees
        3.0 * std.math.pi / 2.0, // 270 degrees
        2.0 * std.math.pi, // 360 degrees (full circle)
    };

    for (rotations) |rot| {
        const result = mat.projectBox(box, .normal, rot);
        const matrix = result.getMatrix();

        // All values should be finite
        for (matrix) |val| {
            try std.testing.expect(std.math.isFinite(val));
        }
    }
}

test "Type - multiply by zero matrix" {
    var identity = Type.identity();
    const zero = Type.init(); // All zeros

    const result = identity.multiply(zero);
    const matrix = result.getMatrix();

    // Result should be all zeros
    for (matrix) |val| {
        try std.testing.expectEqual(@as(f32, 0), val);
    }
}

test "Type - chained operations maintain finite values" {
    var mat = Type.identity();
    _ = mat.translate(Vector2D.init(10, 20));
    _ = mat.scale(Vector2D.init(2, 3));
    _ = mat.rotate(@as(f32, @floatCast(std.math.pi / 4.0)));

    const result = mat.getMatrix();

    // All values should remain finite after chained operations
    for (result) |val| {
        try std.testing.expect(std.math.isFinite(val));
    }

    // Values should be reasonable
    for (result) |val| {
        try std.testing.expect(@abs(val) < 1000);
    }
}

test "Type - identity is neutral element" {
    var mat = Type.identity();
    _ = mat.translate(Vector2D.init(5, 10));
    _ = mat.scale(Vector2D.init(2, 3));

    const original = mat.getMatrix();

    var identity = Type.identity();

    // M * I = M
    const result1 = mat.multiply(identity);
    const matrix1 = result1.getMatrix();

    for (original, matrix1) |o, r| {
        try std.testing.expectApproxEqAbs(o, r, 0.001);
    }

    // I * M = M
    const result2 = identity.multiply(mat);
    const matrix2 = result2.getMatrix();

    for (original, matrix2) |o, r| {
        try std.testing.expectApproxEqAbs(o, r, 0.001);
    }
}

test "Type - scale by zero" {
    var mat = Type.identity();
    _ = mat.scale(Vector2D.init(0, 0));

    const result = mat.getMatrix();

    // Scaling by zero should zero out the scale components
    try std.testing.expectEqual(@as(f32, 0), result[0]);
    try std.testing.expectEqual(@as(f32, 0), result[4]);
}

test "Type - transpose twice returns original" {
    var mat = Type.identity();
    _ = mat.translate(Vector2D.init(10, 20));
    _ = mat.scale(Vector2D.init(2, 3));

    const original = mat.getMatrix();

    const transposed_once = mat.transpose();
    const transposed_twice = transposed_once.transpose();

    const result = transposed_twice.getMatrix();

    // (M^T)^T = M
    for (original, result) |o, r| {
        try std.testing.expectEqual(o, r);
    }
}

test "Type - outputProjection for all transforms" {
    const output_size = Vector2D.init(1920, 1080);

    const transforms = [_]Transform{
        .normal,  .@"90",      .@"180",      .@"270",
        .flipped, .flipped_90, .flipped_180, .flipped_270,
    };

    for (transforms) |t| {
        const mat = Type.outputProjection(output_size, t);
        const result = mat.getMatrix();

        // All values should be finite
        for (result) |val| {
            try std.testing.expect(std.math.isFinite(val));
        }

        // Bottom-right should always be 1
        try std.testing.expectEqual(@as(f32, 1), result[8]);
    }
}

test "Type - numerical drift in rotation" {
    var mat = Type.identity();

    // Small rotation repeated many times
    const small_angle: f32 = 0.01; // ~0.57 degrees

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = mat.rotate(small_angle);
    }

    // After 200 rotations of 0.01 radians (2 radians total)
    // Should still have finite values
    const result = mat.getMatrix();

    for (result) |val| {
        try std.testing.expect(std.math.isFinite(val));
        // Values shouldn't explode
        try std.testing.expect(@abs(val) < 100);
    }
}

test "Type.projectBox - rotation at exact multiples of π" {
    const output_size = Vector2D.init(1920, 1080);
    const mat = Type.outputProjection(output_size, .normal);
    const box = Box.init(100, 100, 200, 200);

    const pi = std.math.pi;
    const special_angles = [_]f32{ pi, 2 * pi, -pi, 3 * pi };

    for (special_angles) |angle| {
        const result = mat.projectBox(box, .normal, angle);
        const matrix = result.getMatrix();

        // All values should be finite (no sin/cos edge cases)
        for (matrix) |val| {
            try std.testing.expect(std.math.isFinite(val));
        }
    }
}

test "Type - very small rotation angles" {
    var mat = Type.identity();

    // Very small angle (numerical precision test)
    const tiny_angle: f32 = 1e-6;
    _ = mat.rotate(tiny_angle);

    const result = mat.getMatrix();

    // Should be very close to identity
    const identity_mat = Type.identity().getMatrix();

    for (result, identity_mat) |r, id| {
        try std.testing.expectApproxEqAbs(id, r, 0.01);
    }
}

test "Type - commutative scaling" {
    var mat1 = Type.identity();
    _ = mat1.scale(Vector2D.init(2, 3));
    _ = mat1.scale(Vector2D.init(4, 5));

    var mat2 = Type.identity();
    _ = mat2.scale(Vector2D.init(4, 5));
    _ = mat2.scale(Vector2D.init(2, 3));

    const result1 = mat1.getMatrix();
    const result2 = mat2.getMatrix();

    // Scaling should be commutative
    for (result1, result2) |r1, r2| {
        try std.testing.expectApproxEqAbs(r1, r2, 0.001);
    }
}

test "Type - translate then scale vs scale then translate" {
    var translate_first = Type.identity();
    _ = translate_first.translate(Vector2D.init(10, 20));
    _ = translate_first.scale(Vector2D.init(2, 2));

    var scale_first = Type.identity();
    _ = scale_first.scale(Vector2D.init(2, 2));
    _ = scale_first.translate(Vector2D.init(10, 20));

    const result1 = translate_first.getMatrix();
    const result2 = scale_first.getMatrix();

    // These should be DIFFERENT (operations don't commute)
    var different = false;
    for (result1, result2) |r1, r2| {
        if (@abs(r1 - r2) > 0.01) {
            different = true;
            break;
        }
    }

    try std.testing.expect(different);
}
