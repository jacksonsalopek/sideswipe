const std = @import("std");
const Transform = @import("transform.zig").Transform;

pub const Vector2D = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) Vector2D {
        return .{ .x = x, .y = y };
    }

    /// Normalizes the vector and returns the max absolute component
    pub fn normalize(self: *Vector2D) f64 {
        const max = @max(@abs(self.x), @abs(self.y));
        self.x /= max;
        self.y /= max;
        return max;
    }

    pub fn floor(self: Vector2D) Vector2D {
        return .{
            .x = @floor(self.x),
            .y = @floor(self.y),
        };
    }

    pub fn round(self: Vector2D) Vector2D {
        return .{
            .x = @round(self.x),
            .y = @round(self.y),
        };
    }

    pub fn clamp(self: Vector2D, min: Vector2D, max: Vector2D) Vector2D {
        return .{
            .x = std.math.clamp(self.x, min.x, if (max.x < min.x) std.math.inf(f32) else max.x),
            .y = std.math.clamp(self.y, min.y, if (max.y < min.y) std.math.inf(f32) else max.y),
        };
    }

    pub fn distance(self: Vector2D, other: Vector2D) f32 {
        return @sqrt(self.distanceSq(other));
    }

    pub fn distanceSq(self: Vector2D, other: Vector2D) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return (dx * dx) + (dy * dy);
    }

    pub fn size(self: Vector2D) f64 {
        return @sqrt((self.x * self.x) + (self.y * self.y));
    }

    pub fn getComponentMax(self: Vector2D, other: Vector2D) Vector2D {
        return .{
            .x = @max(self.x, other.x),
            .y = @max(self.y, other.y),
        };
    }

    pub fn transform(self: Vector2D, t: Transform, monitor_size: Vector2D) Vector2D {
        return switch (t) {
            .normal => self,
            .@"90" => .{ .x = self.y, .y = monitor_size.y - self.x },
            .@"180" => .{ .x = monitor_size.x - self.x, .y = monitor_size.y - self.y },
            .@"270" => .{ .x = monitor_size.x - self.y, .y = self.x },
            .flipped => .{ .x = monitor_size.x - self.x, .y = self.y },
            .flipped_90 => .{ .x = self.y, .y = self.x },
            .flipped_180 => .{ .x = self.x, .y = monitor_size.y - self.y },
            .flipped_270 => .{ .x = monitor_size.x - self.y, .y = monitor_size.y - self.x },
        };
    }

    pub fn add(self: Vector2D, other: Vector2D) Vector2D {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vector2D, other: Vector2D) Vector2D {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn mul(self: Vector2D, scalar: f32) Vector2D {
        return .{ .x = self.x * scalar, .y = self.y * scalar };
    }

    pub fn scale(self: Vector2D, scalar: f32) Vector2D {
        return self.mul(scalar);
    }

    pub fn div(self: Vector2D, scalar: f32) Vector2D {
        return .{ .x = self.x / scalar, .y = self.y / scalar };
    }

    pub fn eql(self: Vector2D, other: Vector2D) bool {
        return self.x == other.x and self.y == other.y;
    }
};

test "Vector2D.normalize" {
    var v = Vector2D.init(10, 5);
    const max = v.normalize();

    try std.testing.expectEqual(@as(f64, 10), max);
    try std.testing.expectEqual(@as(f64, 1), v.x);
    try std.testing.expectEqual(@as(f64, 0.5), v.y);
}

test "Vector2D.floor" {
    const v = Vector2D.init(10.7, 5.3);
    const result = v.floor();

    try std.testing.expectEqual(@as(f64, 10), result.x);
    try std.testing.expectEqual(@as(f64, 5), result.y);
}

test "Vector2D.round" {
    const v = Vector2D.init(10.4, 5.6);
    const result = v.round();

    try std.testing.expectEqual(@as(f64, 10), result.x);
    try std.testing.expectEqual(@as(f64, 6), result.y);
}

test "Vector2D.clamp" {
    const v = Vector2D.init(15, 5);
    const min = Vector2D.init(0, 0);
    const max = Vector2D.init(10, 10);
    const result = v.clamp(min, max);

    try std.testing.expectEqual(@as(f64, 10), result.x);
    try std.testing.expectEqual(@as(f64, 5), result.y);
}

test "Vector2D.distance" {
    const v1 = Vector2D.init(0, 0);
    const v2 = Vector2D.init(3, 4);
    const dist = v1.distance(v2);

    try std.testing.expectEqual(@as(f64, 5), dist);
}

test "Vector2D.distanceSq" {
    const v1 = Vector2D.init(0, 0);
    const v2 = Vector2D.init(3, 4);
    const dist_sq = v1.distanceSq(v2);

    try std.testing.expectEqual(@as(f64, 25), dist_sq);
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

    try std.testing.expectEqual(@as(f64, 10), result.x);
    try std.testing.expectEqual(@as(f64, 8), result.y);
}

test "Vector2D.transform 90 degrees" {
    const v = Vector2D.init(10, 20);
    const monitor = Vector2D.init(1920, 1080);
    const result = v.transform(.@"90", monitor);

    try std.testing.expectEqual(@as(f64, 20), result.x);
    try std.testing.expectEqual(@as(f64, 1070), result.y); // 1080 - 10
}

test "Vector2D.transform 180 degrees" {
    const v = Vector2D.init(10, 20);
    const monitor = Vector2D.init(1920, 1080);
    const result = v.transform(.@"180", monitor);

    try std.testing.expectEqual(@as(f64, 1910), result.x); // 1920 - 10
    try std.testing.expectEqual(@as(f64, 1060), result.y); // 1080 - 20
}

test "Vector2D arithmetic" {
    const v1 = Vector2D.init(10, 20);
    const v2 = Vector2D.init(5, 3);

    const sum = v1.add(v2);
    try std.testing.expectEqual(@as(f64, 15), sum.x);
    try std.testing.expectEqual(@as(f64, 23), sum.y);

    const diff = v1.sub(v2);
    try std.testing.expectEqual(@as(f64, 5), diff.x);
    try std.testing.expectEqual(@as(f64, 17), diff.y);

    const scaled = v1.mul(2);
    try std.testing.expectEqual(@as(f64, 20), scaled.x);
    try std.testing.expectEqual(@as(f64, 40), scaled.y);
}
