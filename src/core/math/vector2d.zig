const std = @import("std");
const Transform = @import("transform.zig").Transform;

pub const Vector2D = struct {
    v: @Vector(2, f32) = @splat(0),

    pub fn init(x: f32, y: f32) Vector2D {
        return .{ .v = .{ x, y } };
    }

    /// Get x component
    pub inline fn getX(self: Vector2D) f32 {
        return self.v[0];
    }

    /// Get y component
    pub inline fn getY(self: Vector2D) f32 {
        return self.v[1];
    }

    /// Set x component
    pub inline fn setX(self: *Vector2D, value: f32) void {
        self.v[0] = value;
    }

    /// Set y component
    pub inline fn setY(self: *Vector2D, value: f32) void {
        self.v[1] = value;
    }

    /// Normalizes the vector and returns the max absolute component
    pub fn normalize(self: *Vector2D) f64 {
        const max = @max(@abs(self.v[0]), @abs(self.v[1]));
        self.v /= @as(@Vector(2, f32), @splat(max));
        return max;
    }

    pub fn floor(self: Vector2D) Vector2D {
        return .{ .v = @floor(self.v) };
    }

    pub fn round(self: Vector2D) Vector2D {
        return .{ .v = @round(self.v) };
    }

    pub fn clamp(self: Vector2D, min: Vector2D, max: Vector2D) Vector2D {
        return .{
            .v = .{
                std.math.clamp(self.v[0], min.v[0], if (max.v[0] < min.v[0]) std.math.inf(f32) else max.v[0]),
                std.math.clamp(self.v[1], min.v[1], if (max.v[1] < min.v[1]) std.math.inf(f32) else max.v[1]),
            },
        };
    }

    pub fn distance(self: Vector2D, other: Vector2D) f32 {
        return @sqrt(self.distanceSq(other));
    }

    pub fn distanceSq(self: Vector2D, other: Vector2D) f32 {
        const diff = self.v - other.v;
        const sq = diff * diff;
        return @reduce(.Add, sq);
    }

    pub fn size(self: Vector2D) f64 {
        const sq = self.v * self.v;
        return @sqrt(@reduce(.Add, sq));
    }

    pub fn getComponentMax(self: Vector2D, other: Vector2D) Vector2D {
        return .{ .v = @max(self.v, other.v) };
    }

    pub fn transform(self: Vector2D, t: Transform, monitor_size: Vector2D) Vector2D {
        const x = self.v[0];
        const y = self.v[1];
        const mx = monitor_size.v[0];
        const my = monitor_size.v[1];
        return switch (t) {
            .normal => self,
            .@"90" => .{ .v = .{ y, my - x } },
            .@"180" => .{ .v = .{ mx - x, my - y } },
            .@"270" => .{ .v = .{ mx - y, x } },
            .flipped => .{ .v = .{ mx - x, y } },
            .flipped_90 => .{ .v = .{ y, x } },
            .flipped_180 => .{ .v = .{ x, my - y } },
            .flipped_270 => .{ .v = .{ mx - y, my - x } },
        };
    }

    pub fn add(self: Vector2D, other: Vector2D) Vector2D {
        return .{ .v = self.v + other.v };
    }

    pub fn sub(self: Vector2D, other: Vector2D) Vector2D {
        return .{ .v = self.v - other.v };
    }

    pub fn mul(self: Vector2D, scalar: f32) Vector2D {
        return .{ .v = self.v * @as(@Vector(2, f32), @splat(scalar)) };
    }

    pub fn scale(self: Vector2D, scalar: f32) Vector2D {
        return self.mul(scalar);
    }

    pub fn div(self: Vector2D, scalar: f32) Vector2D {
        return .{ .v = self.v / @as(@Vector(2, f32), @splat(scalar)) };
    }

    pub fn eql(self: Vector2D, other: Vector2D) bool {
        return @reduce(.And, self.v == other.v);
    }
};

test "Vector2D.normalize" {
    var v = Vector2D.init(10, 5);
    const max = v.normalize();

    try std.testing.expectEqual(@as(f64, 10), max);
    try std.testing.expectEqual(@as(f32, 1), v.getX());
    try std.testing.expectEqual(@as(f32, 0.5), v.getY());
}

test "Vector2D.floor" {
    const v = Vector2D.init(10.7, 5.3);
    const result = v.floor();

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 5), result.getY());
}

test "Vector2D.round" {
    const v = Vector2D.init(10.4, 5.6);
    const result = v.round();

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 6), result.getY());
}

test "Vector2D.clamp" {
    const v = Vector2D.init(15, 5);
    const min = Vector2D.init(0, 0);
    const max = Vector2D.init(10, 10);
    const result = v.clamp(min, max);

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 5), result.getY());
}

test "Vector2D.distance" {
    const v1 = Vector2D.init(0, 0);
    const v2 = Vector2D.init(3, 4);
    const dist = v1.distance(v2);

    try std.testing.expectEqual(@as(f32, 5), dist);
}

test "Vector2D.distanceSq" {
    const v1 = Vector2D.init(0, 0);
    const v2 = Vector2D.init(3, 4);
    const dist_sq = v1.distanceSq(v2);

    try std.testing.expectEqual(@as(f32, 25), dist_sq);
}

test "Vector2D.size" {
    const v = Vector2D.init(3, 4);
    const s = v.size();

    try std.testing.expectEqual(@as(f64, 5), s);
}

test "Vector2D.getComponentMax" {
    const v1 = Vector2D.init(10, 5);
    const v2 = Vector2D.init(3, 8);
    const result = v1.getComponentMax(v2);

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 8), result.getY());
}

test "Vector2D.transform 90 degrees" {
    const v = Vector2D.init(10, 20);
    const monitor = Vector2D.init(1920, 1080);
    const result = v.transform(.@"90", monitor);

    try std.testing.expectEqual(@as(f32, 20), result.getX());
    try std.testing.expectEqual(@as(f32, 1070), result.getY()); // 1080 - 10
}

test "Vector2D.transform 180 degrees" {
    const v = Vector2D.init(10, 20);
    const monitor = Vector2D.init(1920, 1080);
    const result = v.transform(.@"180", monitor);

    try std.testing.expectEqual(@as(f32, 1910), result.getX()); // 1920 - 10
    try std.testing.expectEqual(@as(f32, 1060), result.getY()); // 1080 - 20
}

test "Vector2D arithmetic" {
    const v1 = Vector2D.init(10, 20);
    const v2 = Vector2D.init(5, 3);

    const sum = v1.add(v2);
    try std.testing.expectEqual(@as(f32, 15), sum.getX());
    try std.testing.expectEqual(@as(f32, 23), sum.getY());

    const diff = v1.sub(v2);
    try std.testing.expectEqual(@as(f32, 5), diff.getX());
    try std.testing.expectEqual(@as(f32, 17), diff.getY());

    const scaled = v1.mul(2);
    try std.testing.expectEqual(@as(f32, 20), scaled.getX());
    try std.testing.expectEqual(@as(f32, 40), scaled.getY());
}

test "Vector2D.transform - all 8 variants" {
    const v = Vector2D.init(10, 20);
    const monitor = Vector2D.init(1920, 1080);

    // Normal (identity)
    const normal = v.transform(.normal, monitor);
    try std.testing.expectEqual(@as(f32, 10), normal.getX());
    try std.testing.expectEqual(@as(f32, 20), normal.getY());

    // 90 degrees
    const t90 = v.transform(.@"90", monitor);
    try std.testing.expectEqual(@as(f32, 20), t90.getX());
    try std.testing.expectEqual(@as(f32, 1070), t90.getY()); // 1080 - 10

    // 180 degrees
    const t180 = v.transform(.@"180", monitor);
    try std.testing.expectEqual(@as(f32, 1910), t180.getX()); // 1920 - 10
    try std.testing.expectEqual(@as(f32, 1060), t180.getY()); // 1080 - 20

    // 270 degrees
    const t270 = v.transform(.@"270", monitor);
    try std.testing.expectEqual(@as(f32, 1900), t270.getX()); // 1920 - 20
    try std.testing.expectEqual(@as(f32, 10), t270.getY());

    // Flipped (horizontal flip)
    const flipped = v.transform(.flipped, monitor);
    try std.testing.expectEqual(@as(f32, 1910), flipped.getX()); // 1920 - 10
    try std.testing.expectEqual(@as(f32, 20), flipped.getY());

    // Flipped 90
    const flipped90 = v.transform(.flipped_90, monitor);
    try std.testing.expectEqual(@as(f32, 20), flipped90.getX());
    try std.testing.expectEqual(@as(f32, 10), flipped90.getY());

    // Flipped 180
    const flipped180 = v.transform(.flipped_180, monitor);
    try std.testing.expectEqual(@as(f32, 10), flipped180.getX());
    try std.testing.expectEqual(@as(f32, 1060), flipped180.getY()); // 1080 - 20

    // Flipped 270
    const flipped270 = v.transform(.flipped_270, monitor);
    try std.testing.expectEqual(@as(f32, 1900), flipped270.getX()); // 1920 - 20
    try std.testing.expectEqual(@as(f32, 1070), flipped270.getY()); // 1080 - 10
}
