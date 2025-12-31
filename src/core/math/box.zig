const std = @import("std");
const Vector2D = @import("vector2d.zig").Vector2D;

pub const Box = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(x: f32, y: f32, w: f32, h: f32) Box {
        return .{ .x = x, .y = y, .width = w, .height = h };
    }

    pub fn at(self: Box) Vector2D {
        return Vector2D.init(self.x, self.y);
    }

    pub fn pos(self: Box) Vector2D {
        return self.at();
    }

    pub fn size(self: Box) Vector2D {
        return Vector2D.init(self.width, self.height);
    }

    pub fn middle(self: Box) Vector2D {
        return Vector2D.init(
            self.x + self.width / 2.0,
            self.y + self.height / 2.0,
        );
    }

    pub fn contains(self: Box, other: Box) bool {
        return other.x >= self.x and
            other.x + other.width <= self.x + self.width and
            other.y >= self.y and
            other.y + other.height <= self.y + self.height;
    }

    pub fn containsPoint(self: Box, point: Vector2D) bool {
        return point.x >= self.x and
            point.x < self.x + self.width and
            point.y >= self.y and
            point.y < self.y + self.height;
    }

    pub fn empty(self: Box) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn translate(self: Box, delta: Vector2D) Box {
        return .{
            .x = self.x + delta.x,
            .y = self.y + delta.y,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn scale(self: Box, s: f32) Box {
        return .{
            .x = self.x * s,
            .y = self.y * s,
            .width = self.width * s,
            .height = self.height * s,
        };
    }

    pub fn scaleFromCenter(self: Box, s: f32) Box {
        const old_dims = self.size();
        const new_box = self.scale(s);
        const new_dims = new_box.size();

        return .{
            .x = new_box.x - (new_dims.x - old_dims.x) / 2.0,
            .y = new_box.y - (new_dims.y - old_dims.y) / 2.0,
            .width = new_box.width,
            .height = new_box.height,
        };
    }

    pub fn expand(self: Box, value: f32) Box {
        return .{
            .x = self.x - value,
            .y = self.y - value,
            .width = self.width + value * 2.0,
            .height = self.height + value * 2.0,
        };
    }

    pub fn noNegativeSize(self: Box) Box {
        var result = self;
        if (result.width < 0) {
            result.x += result.width;
            result.width = -result.width;
        }
        if (result.height < 0) {
            result.y += result.height;
            result.height = -result.height;
        }
        return result;
    }

    pub fn roundInternal(self: Box) Box {
        const new_x = @floor(self.x);
        const new_y = @floor(self.y);

        return .{
            .x = new_x,
            .y = new_y,
            .width = @round(self.x + self.width - new_x),
            .height = @round(self.y + self.height - new_y),
        };
    }

    pub fn round(self: Box) Box {
        return .{
            .x = @round(self.x),
            .y = @round(self.y),
            .width = @round(self.width),
            .height = @round(self.height),
        };
    }

    pub fn floor(self: Box) Box {
        return .{
            .x = @floor(self.x),
            .y = @floor(self.y),
            .width = @floor(self.width),
            .height = @floor(self.height),
        };
    }

    pub fn intersection(self: Box, other: Box) Box {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.x + self.width, other.x + other.width);
        const y2 = @min(self.y + self.height, other.y + other.height);

        return .{
            .x = x1,
            .y = y1,
            .width = @max(0, x2 - x1),
            .height = @max(0, y2 - y1),
        };
    }

    pub fn overlaps(self: Box, other: Box) bool {
        return !self.intersection(other).empty();
    }

    pub fn closest(self: Box, point: Vector2D) Vector2D {
        if (self.containsPoint(point)) return point;

        return Vector2D.init(
            std.math.clamp(point.x, self.x, self.x + self.width),
            std.math.clamp(point.y, self.y, self.y + self.height),
        );
    }

    pub fn addExtents(self: Box, extents: Extents) Box {
        return .{
            .x = self.x - extents.left,
            .y = self.y - extents.top,
            .width = self.width + extents.left + extents.right,
            .height = self.height + extents.top + extents.bottom,
        };
    }

    pub fn subtractExtents(self: Box, extents: Extents) Box {
        return .{
            .x = self.x + extents.left,
            .y = self.y + extents.top,
            .width = self.width - extents.left - extents.right,
            .height = self.height - extents.top - extents.bottom,
        };
    }

    pub fn eql(self: Box, other: Box) bool {
        return self.x == other.x and
            self.y == other.y and
            self.width == other.width and
            self.height == other.height;
    }
};

pub const Extents = struct {
    top: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
    right: f32 = 0,

    pub fn addExtents(self: Extents, other: Extents) Extents {
        return .{
            .top = self.top + other.top,
            .bottom = self.bottom + other.bottom,
            .left = self.left + other.left,
            .right = self.right + other.right,
        };
    }
};

test "Box initialization" {
    const box = Box.init(10, 20, 100, 50);
    try std.testing.expectEqual(@as(f64, 10), box.x);
    try std.testing.expectEqual(@as(f64, 20), box.y);
    try std.testing.expectEqual(@as(f64, 100), box.width);
    try std.testing.expectEqual(@as(f64, 50), box.height);
}

test "Box.middle" {
    const box = Box.init(0, 0, 100, 50);
    const mid = box.middle();
    try std.testing.expectEqual(@as(f64, 50), mid.x);
    try std.testing.expectEqual(@as(f64, 25), mid.y);
}

test "Box.contains" {
    const outer = Box.init(0, 0, 100, 100);
    const inner = Box.init(10, 10, 20, 20);
    const outside = Box.init(50, 50, 100, 100);

    try std.testing.expect(outer.contains(inner));
    try std.testing.expect(!outer.contains(outside));
}

test "Box.containsPoint" {
    const box = Box.init(0, 0, 100, 100);
    try std.testing.expect(box.containsPoint(Vector2D.init(50, 50)));
    try std.testing.expect(!box.containsPoint(Vector2D.init(150, 50)));
    try std.testing.expect(!box.containsPoint(Vector2D.init(100, 50))); // Edge is exclusive
}

test "Box.intersection" {
    const box1 = Box.init(0, 0, 100, 100);
    const box2 = Box.init(50, 50, 100, 100);
    const result = box1.intersection(box2);

    try std.testing.expectEqual(@as(f64, 50), result.x);
    try std.testing.expectEqual(@as(f64, 50), result.y);
    try std.testing.expectEqual(@as(f64, 50), result.width);
    try std.testing.expectEqual(@as(f64, 50), result.height);
}

test "Box.overlaps" {
    const box1 = Box.init(0, 0, 100, 100);
    const box2 = Box.init(50, 50, 100, 100);
    const box3 = Box.init(200, 200, 100, 100);

    try std.testing.expect(box1.overlaps(box2));
    try std.testing.expect(!box1.overlaps(box3));
}

test "Box.scale" {
    const box = Box.init(10, 10, 100, 50);
    const scaled = box.scale(2);

    try std.testing.expectEqual(@as(f64, 20), scaled.x);
    try std.testing.expectEqual(@as(f64, 20), scaled.y);
    try std.testing.expectEqual(@as(f64, 200), scaled.width);
    try std.testing.expectEqual(@as(f64, 100), scaled.height);
}

test "Box.expand" {
    const box = Box.init(10, 10, 100, 50);
    const expanded = box.expand(5);

    try std.testing.expectEqual(@as(f64, 5), expanded.x);
    try std.testing.expectEqual(@as(f64, 5), expanded.y);
    try std.testing.expectEqual(@as(f64, 110), expanded.width);
    try std.testing.expectEqual(@as(f64, 60), expanded.height);
}
