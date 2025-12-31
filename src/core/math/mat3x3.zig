const std = @import("std");
const Vector2D = @import("vector2d.zig").Vector2D;
const Box = @import("box.zig").Box;
const Transform = @import("transform.zig").Transform;

pub const Mat3x3 = struct {
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

    pub fn init() Mat3x3 {
        return .{ .matrix = [_]f32{0} ** 9 };
    }

    pub fn initFromArray(mat: [9]f32) Mat3x3 {
        return .{ .matrix = mat };
    }

    pub fn identity() Mat3x3 {
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

    pub fn outputProjection(size: Vector2D, t: Transform) Mat3x3 {
        var mat = Mat3x3.init();

        const transform_mat = getTransformMatrix(t);
        const x: f32 = 2.0 / size.x;
        const y: f32 = 2.0 / size.y;

        // Rotation + reflection
        mat.matrix[0] = x * transform_mat[0];
        mat.matrix[1] = x * transform_mat[1];
        mat.matrix[3] = y * transform_mat[3];
        mat.matrix[4] = y * transform_mat[4];

        // Translation
        mat.matrix[2] = -std.math.copysign(1.0, mat.matrix[0] + mat.matrix[1]);
        mat.matrix[5] = -std.math.copysign(1.0, mat.matrix[3] + mat.matrix[4]);

        // Identity
        mat.matrix[8] = 1.0;

        return mat;
    }

    pub fn getMatrix(self: Mat3x3) [9]f32 {
        return self.matrix;
    }

    pub fn projectBox(self: Mat3x3, box: Box, t: Transform, rot: f32) Mat3x3 {
        var mat = Mat3x3.identity();

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

    pub fn applyTransform(self: *Mat3x3, t: Transform) *Mat3x3 {
        const transform_mat = getTransformMatrix(t);
        _ = self.multiply(Mat3x3.initFromArray(transform_mat));
        return self;
    }

    pub fn rotate(self: *Mat3x3, rot: f32) *Mat3x3 {
        const cos_rot = @cos(rot);
        const sin_rot = @sin(rot);
        const rotation_mat = [9]f32{ cos_rot, -sin_rot, 0.0, sin_rot, cos_rot, 0.0, 0.0, 0.0, 1.0 };
        _ = self.multiply(Mat3x3.initFromArray(rotation_mat));
        return self;
    }

    pub fn scale(self: *Mat3x3, scale_vec: Vector2D) *Mat3x3 {
        const scale_mat = [9]f32{ scale_vec.x, 0.0, 0.0, 0.0, scale_vec.y, 0.0, 0.0, 0.0, 1.0 };
        _ = self.multiply(Mat3x3.initFromArray(scale_mat));
        return self;
    }

    pub fn scaleScalar(self: *Mat3x3, scale_factor: f32) *Mat3x3 {
        return self.scale(Vector2D.init(scale_factor, scale_factor));
    }

    pub fn translate(self: *Mat3x3, offset: Vector2D) *Mat3x3 {
        const translation_mat = [9]f32{ 1.0, 0.0, offset.x, 0.0, 1.0, offset.y, 0.0, 0.0, 1.0 };
        _ = self.multiply(Mat3x3.initFromArray(translation_mat));
        return self;
    }

    pub fn transpose(self: *Mat3x3) *Mat3x3 {
        const m = self.matrix;
        self.matrix = [9]f32{ m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8] };
        return self;
    }

    pub fn multiply(self: *Mat3x3, other: Mat3x3) *Mat3x3 {
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

    pub fn copy(self: Mat3x3) Mat3x3 {
        return self;
    }

    pub fn format(
        self: Mat3x3,
        comptime fmt: []const u8,
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

test "Mat3x3.identity" {
    const mat = Mat3x3.identity();
    try std.testing.expectEqual(@as(f32, 1.0), mat.matrix[0]);
    try std.testing.expectEqual(@as(f32, 0.0), mat.matrix[1]);
    try std.testing.expectEqual(@as(f32, 1.0), mat.matrix[4]);
    try std.testing.expectEqual(@as(f32, 1.0), mat.matrix[8]);
}

test "Mat3x3.translate" {
    var mat = Mat3x3.identity();
    _ = mat.translate(Vector2D.init(10, 20));

    try std.testing.expectEqual(@as(f32, 10.0), mat.matrix[2]);
    try std.testing.expectEqual(@as(f32, 20.0), mat.matrix[5]);
}

test "Mat3x3.scale" {
    var mat = Mat3x3.identity();
    _ = mat.scale(Vector2D.init(2, 3));

    try std.testing.expectEqual(@as(f32, 2.0), mat.matrix[0]);
    try std.testing.expectEqual(@as(f32, 3.0), mat.matrix[4]);
}

test "Mat3x3.rotate" {
    var mat = Mat3x3.identity();
    _ = mat.rotate(std.math.pi / 2.0); // 90 degrees

    // cos(90) ≈ 0, sin(90) ≈ 1
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mat.matrix[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), mat.matrix[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mat.matrix[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mat.matrix[4], 0.0001);
}

test "Mat3x3.multiply" {
    var mat1 = Mat3x3.identity();
    _ = mat1.translate(Vector2D.init(5, 5));

    var mat2 = Mat3x3.identity();
    _ = mat2.scale(Vector2D.init(2, 2));

    _ = mat1.multiply(mat2);

    // Result should have both translation and scale
    try std.testing.expectEqual(@as(f32, 2.0), mat1.matrix[0]);
    try std.testing.expectEqual(@as(f32, 2.0), mat1.matrix[4]);
}

test "Mat3x3.transpose" {
    var mat = Mat3x3.initFromArray(.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    _ = mat.transpose();

    try std.testing.expectEqual(@as(f32, 1), mat.matrix[0]);
    try std.testing.expectEqual(@as(f32, 4), mat.matrix[1]);
    try std.testing.expectEqual(@as(f32, 7), mat.matrix[2]);
    try std.testing.expectEqual(@as(f32, 2), mat.matrix[3]);
    try std.testing.expectEqual(@as(f32, 5), mat.matrix[4]);
    try std.testing.expectEqual(@as(f32, 8), mat.matrix[5]);
}

test "Mat3x3.format" {
    const mat = Mat3x3.identity();
    var buf: [200]u8 = undefined;

    // Test the custom format function directly
    var fbs = std.io.fixedBufferStream(&buf);
    try mat.format("", .{}, fbs.writer());
    const result = fbs.getWritten();

    // Check if the custom format function produced the expected output
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "mat3x3") != null);
}
