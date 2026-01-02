const std = @import("std");
const Transform = @import("transform.zig").Direction;

pub const Type = struct {
    v: @Vector(2, f32) = @splat(0),

    pub fn init(x: f32, y: f32) Type {
        return .{ .v = .{ x, y } };
    }

    /// Get x component
    pub inline fn getX(self: Type) f32 {
        return self.v[0];
    }

    /// Get y component
    pub inline fn getY(self: Type) f32 {
        return self.v[1];
    }

    /// Set x component
    pub inline fn setX(self: *Type, value: f32) void {
        self.v[0] = value;
    }

    /// Set y component
    pub inline fn setY(self: *Type, value: f32) void {
        self.v[1] = value;
    }

    /// Normalizes the vector and returns the max absolute component
    pub fn normalize(self: *Type) f64 {
        const max = @max(@abs(self.v[0]), @abs(self.v[1]));
        self.v /= @as(@Vector(2, f32), @splat(max));
        return max;
    }

    pub fn floor(self: Type) Type {
        return .{ .v = @floor(self.v) };
    }

    pub fn round(self: Type) Type {
        return .{ .v = @round(self.v) };
    }

    pub fn clamp(self: Type, min: Type, max: Type) Type {
        return .{
            .v = .{
                std.math.clamp(self.v[0], min.v[0], if (max.v[0] < min.v[0]) std.math.inf(f32) else max.v[0]),
                std.math.clamp(self.v[1], min.v[1], if (max.v[1] < min.v[1]) std.math.inf(f32) else max.v[1]),
            },
        };
    }

    pub fn distance(self: Type, other: Type) f32 {
        return @sqrt(self.distanceSq(other));
    }

    pub fn distanceSq(self: Type, other: Type) f32 {
        const diff = self.v - other.v;
        const sq = diff * diff;
        return @reduce(.Add, sq);
    }

    pub fn size(self: Type) f64 {
        const sq = self.v * self.v;
        return @sqrt(@reduce(.Add, sq));
    }

    pub fn getComponentMax(self: Type, other: Type) Type {
        return .{ .v = @max(self.v, other.v) };
    }

    pub fn transform(self: Type, t: Transform, monitor_size: Type) Type {
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

    pub fn add(self: Type, other: Type) Type {
        return .{ .v = self.v + other.v };
    }

    pub fn sub(self: Type, other: Type) Type {
        return .{ .v = self.v - other.v };
    }

    pub fn mul(self: Type, scalar: f32) Type {
        return .{ .v = self.v * @as(@Vector(2, f32), @splat(scalar)) };
    }

    pub fn scale(self: Type, scalar: f32) Type {
        return self.mul(scalar);
    }

    pub fn div(self: Type, scalar: f32) Type {
        return .{ .v = self.v / @as(@Vector(2, f32), @splat(scalar)) };
    }

    pub fn eql(self: Type, other: Type) bool {
        return @reduce(.And, self.v == other.v);
    }
};

test "Type.normalize" {
    var v = Type.init(10, 5);
    const max = v.normalize();

    try std.testing.expectEqual(@as(f64, 10), max);
    try std.testing.expectEqual(@as(f32, 1), v.getX());
    try std.testing.expectEqual(@as(f32, 0.5), v.getY());
}

test "Type.floor" {
    const v = Type.init(10.7, 5.3);
    const result = v.floor();

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 5), result.getY());
}

test "Type.round" {
    const v = Type.init(10.4, 5.6);
    const result = v.round();

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 6), result.getY());
}

test "Type.clamp" {
    const v = Type.init(15, 5);
    const min = Type.init(0, 0);
    const max = Type.init(10, 10);
    const result = v.clamp(min, max);

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 5), result.getY());
}

test "Type.distance" {
    const v1 = Type.init(0, 0);
    const v2 = Type.init(3, 4);
    const dist = v1.distance(v2);

    try std.testing.expectEqual(@as(f32, 5), dist);
}

test "Type.distanceSq" {
    const v1 = Type.init(0, 0);
    const v2 = Type.init(3, 4);
    const dist_sq = v1.distanceSq(v2);

    try std.testing.expectEqual(@as(f32, 25), dist_sq);
}

test "Type.size" {
    const v = Type.init(3, 4);
    const s = v.size();

    try std.testing.expectEqual(@as(f64, 5), s);
}

test "Type.getComponentMax" {
    const v1 = Type.init(10, 5);
    const v2 = Type.init(3, 8);
    const result = v1.getComponentMax(v2);

    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 8), result.getY());
}

test "Type.transform 90 degrees" {
    const v = Type.init(10, 20);
    const monitor = Type.init(1920, 1080);
    const result = v.transform(.@"90", monitor);

    try std.testing.expectEqual(@as(f32, 20), result.getX());
    try std.testing.expectEqual(@as(f32, 1070), result.getY()); // 1080 - 10
}

test "Type.transform 180 degrees" {
    const v = Type.init(10, 20);
    const monitor = Type.init(1920, 1080);
    const result = v.transform(.@"180", monitor);

    try std.testing.expectEqual(@as(f32, 1910), result.getX()); // 1920 - 10
    try std.testing.expectEqual(@as(f32, 1060), result.getY()); // 1080 - 20
}

test "Type arithmetic" {
    const v1 = Type.init(10, 20);
    const v2 = Type.init(5, 3);

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

test "Type.transform - all 8 variants" {
    const v = Type.init(10, 20);
    const monitor = Type.init(1920, 1080);

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

test "Type.div - division by zero" {
    const v = Type.init(10, 20);
    const result = v.div(0);

    // Division by zero produces infinity
    try std.testing.expect(std.math.isInf(result.getX()));
    try std.testing.expect(std.math.isInf(result.getY()));
    try std.testing.expect(result.getX() > 0);
    try std.testing.expect(result.getY() > 0);
}

test "Type.div - negative zero" {
    const v = Type.init(10, 20);
    const result = v.div(-0.0);

    // Division by negative zero
    try std.testing.expect(std.math.isInf(result.getX()));
    try std.testing.expect(std.math.isInf(result.getY()));
}

test "Type.div - very small divisor" {
    const v = Type.init(1, 1);
    const tiny = std.math.floatMin(f32);
    const result = v.div(tiny);

    // Very small divisor produces very large result
    try std.testing.expect(result.getX() > 1e30);
    try std.testing.expect(result.getY() > 1e30);
}

test "Type.normalize - zero vector" {
    var v = Type.init(0, 0);
    const max = v.normalize();

    try std.testing.expectEqual(@as(f64, 0), max);
    // Division by zero in normalize produces inf
    try std.testing.expect(std.math.isNan(v.getX()) or std.math.isInf(v.getX()));
    try std.testing.expect(std.math.isNan(v.getY()) or std.math.isInf(v.getY()));
}

test "Type.normalize - negative values" {
    var v = Type.init(-10, -5);
    const max = v.normalize();

    // Max is based on absolute values
    try std.testing.expectEqual(@as(f64, 10), max);
    try std.testing.expectEqual(@as(f32, -1), v.getX());
    try std.testing.expectEqual(@as(f32, -0.5), v.getY());
}

test "Type.normalize - one component zero" {
    var v = Type.init(10, 0);
    const max = v.normalize();

    try std.testing.expectEqual(@as(f64, 10), max);
    try std.testing.expectEqual(@as(f32, 1), v.getX());
    try std.testing.expectEqual(@as(f32, 0), v.getY());
}

test "Type.clamp - inverted bounds" {
    const v = Type.init(50, 50);
    const min = Type.init(100, 100);
    const max = Type.init(0, 0);

    // When max < min, clamp uses infinity as upper bound
    const result = v.clamp(min, max);

    // Should clamp to min since max is inverted
    try std.testing.expectEqual(@as(f32, 100), result.getX());
    try std.testing.expectEqual(@as(f32, 100), result.getY());
}

test "Type.clamp - partially inverted bounds" {
    const v = Type.init(50, 50);
    const min = Type.init(0, 100);
    const max = Type.init(100, 0);

    const result = v.clamp(min, max);

    // X is normal, Y is inverted
    try std.testing.expectEqual(@as(f32, 50), result.getX());
    try std.testing.expectEqual(@as(f32, 100), result.getY());
}

test "Type.clamp - with NaN in value" {
    const v = Type.init(std.math.nan(f32), 50);
    const min = Type.init(0, 0);
    const max = Type.init(100, 100);

    const result = v.clamp(min, max);

    // NaN in value causes std.math.clamp to return max bound
    try std.testing.expectEqual(@as(f32, 100), result.getX());
    try std.testing.expectEqual(@as(f32, 50), result.getY());
}

test "Type.clamp - with infinity" {
    const v = Type.init(50, 50);
    const min = Type.init(0, 0);
    const max = Type.init(std.math.inf(f32), 100);

    const result = v.clamp(min, max);

    try std.testing.expectEqual(@as(f32, 50), result.getX());
    try std.testing.expectEqual(@as(f32, 50), result.getY());
}

test "Type - negative values in operations" {
    const v1 = Type.init(-10, -20);
    const v2 = Type.init(5, 3);

    // Add with negative
    const sum = v1.add(v2);
    try std.testing.expectEqual(@as(f32, -5), sum.getX());
    try std.testing.expectEqual(@as(f32, -17), sum.getY());

    // Subtract with negative
    const diff = v1.sub(v2);
    try std.testing.expectEqual(@as(f32, -15), diff.getX());
    try std.testing.expectEqual(@as(f32, -23), diff.getY());

    // Multiply by negative scalar
    const scaled = v1.mul(-2);
    try std.testing.expectEqual(@as(f32, 20), scaled.getX());
    try std.testing.expectEqual(@as(f32, 40), scaled.getY());

    // Divide by negative scalar
    const divided = v1.div(-2);
    try std.testing.expectEqual(@as(f32, 5), divided.getX());
    try std.testing.expectEqual(@as(f32, 10), divided.getY());
}

test "Type.distance - negative coordinates" {
    const v1 = Type.init(-10, -20);
    const v2 = Type.init(-7, -16);
    const dist = v1.distance(v2);

    try std.testing.expectEqual(@as(f32, 5), dist);
}

test "Type - infinity handling" {
    const inf = std.math.inf(f32);
    const v = Type.init(inf, 10);

    // Add with infinity
    const sum = v.add(Type.init(10, 10));
    try std.testing.expect(std.math.isInf(sum.getX()));
    try std.testing.expectEqual(@as(f32, 20), sum.getY());

    // Multiply by scalar
    const scaled = v.mul(2);
    try std.testing.expect(std.math.isInf(scaled.getX()));

    // Distance with infinity
    const dist = v.distance(Type.init(0, 0));
    try std.testing.expect(std.math.isInf(dist));

    // Floor with infinity
    const floored = v.floor();
    try std.testing.expect(std.math.isInf(floored.getX()));
}

test "Type - NaN handling" {
    const nan_val = std.math.nan(f32);
    const v = Type.init(nan_val, 10);

    // Add with NaN
    const sum = v.add(Type.init(10, 10));
    try std.testing.expect(std.math.isNan(sum.getX()));
    try std.testing.expectEqual(@as(f32, 20), sum.getY());

    // Multiply with NaN
    const scaled = v.mul(2);
    try std.testing.expect(std.math.isNan(scaled.getX()));

    // Distance with NaN
    const dist = v.distance(Type.init(0, 0));
    try std.testing.expect(std.math.isNan(dist));

    // Round with NaN
    const rounded = v.round();
    try std.testing.expect(std.math.isNan(rounded.getX()));
}

test "Type.size - zero vector" {
    const v = Type.init(0, 0);
    const s = v.size();

    try std.testing.expectEqual(@as(f64, 0), s);
}

test "Type.size - negative components" {
    const v = Type.init(-3, -4);
    const s = v.size();

    // Size is always positive (based on squared values)
    try std.testing.expectEqual(@as(f64, 5), s);
}

test "Type - very large values" {
    const large = std.math.floatMax(f32) / 10;
    const v = Type.init(large, large);

    // Operations should handle large values
    const scaled = v.mul(0.5);
    try std.testing.expect(std.math.isFinite(scaled.getX()));

    // Adding large values might overflow to infinity
    const sum = v.add(v);
    try std.testing.expect(std.math.isInf(sum.getX()) or std.math.isFinite(sum.getX()));
}

test "Type - very small values" {
    const tiny = std.math.floatMin(f32);
    const v = Type.init(tiny, tiny);

    // Operations should handle very small values
    const scaled = v.mul(2);
    try std.testing.expect(scaled.getX() > 0);

    // Size of very small vector
    const s = v.size();
    try std.testing.expect(s >= 0);
}

test "Type.eql - NaN comparison" {
    const nan_val = std.math.nan(f32);
    const v1 = Type.init(nan_val, 10);
    const v2 = Type.init(nan_val, 10);

    // NaN != NaN
    try std.testing.expect(!v1.eql(v2));
    try std.testing.expect(!v1.eql(v1));
}

test "Type.eql - infinity comparison" {
    const inf = std.math.inf(f32);
    const v1 = Type.init(inf, 10);
    const v2 = Type.init(inf, 10);

    // inf == inf
    try std.testing.expect(v1.eql(v2));
}

test "Type.eql - negative zero" {
    const v1 = Type.init(0.0, 0.0);
    const v2 = Type.init(-0.0, -0.0);

    // 0.0 == -0.0 in IEEE 754
    try std.testing.expect(v1.eql(v2));
}

test "Type.floor - negative values" {
    const v = Type.init(-10.7, -5.3);
    const result = v.floor();

    try std.testing.expectEqual(@as(f32, -11), result.getX());
    try std.testing.expectEqual(@as(f32, -6), result.getY());
}

test "Type.round - negative values" {
    const v = Type.init(-10.4, -5.6);
    const result = v.round();

    try std.testing.expectEqual(@as(f32, -10), result.getX());
    try std.testing.expectEqual(@as(f32, -6), result.getY());
}

test "Type.distanceSq - overflow potential" {
    const large = std.math.floatMax(f32) / 2;
    const v1 = Type.init(large, large);
    const v2 = Type.init(0, 0);

    const dist_sq = v1.distanceSq(v2);

    // Squaring large values may overflow to infinity
    try std.testing.expect(std.math.isInf(dist_sq) or std.math.isFinite(dist_sq));
}

test "Type.getComponentMax - with negative values" {
    const v1 = Type.init(-5, 10);
    const v2 = Type.init(-3, 8);
    const result = v1.getComponentMax(v2);

    try std.testing.expectEqual(@as(f32, -3), result.getX());
    try std.testing.expectEqual(@as(f32, 10), result.getY());
}

test "Type.getComponentMax - with NaN" {
    const nan_val = std.math.nan(f32);
    const v1 = Type.init(10, 20);
    const v2 = Type.init(nan_val, 15);
    const result = v1.getComponentMax(v2);

    // @max with NaN selects the non-NaN value
    try std.testing.expectEqual(@as(f32, 10), result.getX());
    try std.testing.expectEqual(@as(f32, 20), result.getY());
}

test "Type.transform - with negative coordinates" {
    const v = Type.init(-10, -20);
    const monitor = Type.init(1920, 1080);
    const result = v.transform(.@"90", monitor);

    try std.testing.expectEqual(@as(f32, -20), result.getX());
    try std.testing.expectEqual(@as(f32, 1090), result.getY()); // 1080 - (-10)
}

test "Type.scale - alias for mul" {
    const v = Type.init(10, 20);
    const scaled = v.scale(2);
    const mulled = v.mul(2);

    try std.testing.expect(scaled.eql(mulled));
}
