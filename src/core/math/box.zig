const std = @import("std");
const Vector2D = @import("vector2d.zig").Type;
const Transform = @import("transform.zig").Direction;

pub const Type = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(x: f32, y: f32, w: f32, h: f32) Type {
        return .{ .x = x, .y = y, .width = w, .height = h };
    }

    pub fn at(self: Type) Vector2D {
        return Vector2D.init(self.x, self.y);
    }

    pub fn pos(self: Type) Vector2D {
        return self.at();
    }

    pub fn size(self: Type) Vector2D {
        return Vector2D.init(self.width, self.height);
    }

    pub fn middle(self: Type) Vector2D {
        return Vector2D.init(
            self.x + self.width / 2.0,
            self.y + self.height / 2.0,
        );
    }

    pub fn contains(self: Type, other: Type) bool {
        return other.x >= self.x and
            other.x + other.width <= self.x + self.width and
            other.y >= self.y and
            other.y + other.height <= self.y + self.height;
    }

    pub fn containsPoint(self: Type, point: Vector2D) bool {
        return point.getX() >= self.x and
            point.getX() < self.x + self.width and
            point.getY() >= self.y and
            point.getY() < self.y + self.height;
    }

    pub fn empty(self: Type) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn translate(self: Type, delta: Vector2D) Type {
        return .{
            .x = self.x + delta.getX(),
            .y = self.y + delta.getY(),
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn scale(self: Type, s: f32) Type {
        return .{
            .x = self.x * s,
            .y = self.y * s,
            .width = self.width * s,
            .height = self.height * s,
        };
    }

    pub fn scaleFromCenter(self: Type, s: f32) Type {
        const center = self.middle();
        const new_width = self.width * s;
        const new_height = self.height * s;

        return .{
            .x = center.getX() - new_width / 2.0,
            .y = center.getY() - new_height / 2.0,
            .width = new_width,
            .height = new_height,
        };
    }

    pub fn expand(self: Type, value: f32) Type {
        return .{
            .x = self.x - value,
            .y = self.y - value,
            .width = self.width + value * 2.0,
            .height = self.height + value * 2.0,
        };
    }

    pub fn noNegativeSize(self: Type) Type {
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

    pub fn roundInternal(self: Type) Type {
        const new_x = @floor(self.x);
        const new_y = @floor(self.y);

        return .{
            .x = new_x,
            .y = new_y,
            .width = @round(self.x + self.width - new_x),
            .height = @round(self.y + self.height - new_y),
        };
    }

    pub fn round(self: Type) Type {
        return .{
            .x = @round(self.x),
            .y = @round(self.y),
            .width = @round(self.width),
            .height = @round(self.height),
        };
    }

    pub fn floor(self: Type) Type {
        return .{
            .x = @floor(self.x),
            .y = @floor(self.y),
            .width = @floor(self.width),
            .height = @floor(self.height),
        };
    }

    pub fn intersection(self: Type, other: Type) Type {
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

    pub fn overlaps(self: Type, other: Type) bool {
        return !self.intersection(other).empty();
    }

    pub fn inside(self: Type, other: Type) bool {
        return self.x >= other.x and
            self.y >= other.y and
            self.x + self.width <= other.x + other.width and
            self.y + self.height <= other.y + other.height;
    }

    pub fn closest(self: Type, point: Vector2D) Vector2D {
        if (self.containsPoint(point)) return point;

        return Vector2D.init(
            std.math.clamp(point.getX(), self.x, self.x + self.width),
            std.math.clamp(point.getY(), self.y, self.y + self.height),
        );
    }

    pub fn addExtents(self: Type, extents: Extents) Type {
        return .{
            .x = self.x - extents.left,
            .y = self.y - extents.top,
            .width = self.width + extents.left + extents.right,
            .height = self.height + extents.top + extents.bottom,
        };
    }

    pub fn subtractExtents(self: Type, extents: Extents) Type {
        return .{
            .x = self.x + extents.left,
            .y = self.y + extents.top,
            .width = self.width - extents.left - extents.right,
            .height = self.height - extents.top - extents.bottom,
        };
    }

    pub fn extentsFrom(self: Type, other: Type) Extents {
        return .{
            .top = other.y - self.y,
            .bottom = (self.y + self.height) - (other.y + other.height),
            .left = other.x - self.x,
            .right = (self.x + self.width) - (other.x + other.width),
        };
    }

    pub fn transform(self: Type, t: Transform, w: f32, h: f32) Type {
        return switch (t) {
            .normal => self,
            .@"90" => Type.init(h - self.y - self.height, self.x, self.height, self.width),
            .@"180" => Type.init(w - self.x - self.width, h - self.y - self.height, self.width, self.height),
            .@"270" => Type.init(self.y, w - self.x - self.width, self.height, self.width),
            .flipped => Type.init(w - self.x - self.width, self.y, self.width, self.height),
            .flipped_90 => Type.init(self.y, self.x, self.height, self.width),
            .flipped_180 => Type.init(self.x, h - self.y - self.height, self.width, self.height),
            .flipped_270 => Type.init(h - self.y - self.height, w - self.x - self.width, self.height, self.width),
        };
    }

    pub fn eql(self: Type, other: Type) bool {
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

test "Type initialization" {
    const box = Type.init(10, 20, 100, 50);
    try std.testing.expectEqual(@as(f64, 10), box.x);
    try std.testing.expectEqual(@as(f64, 20), box.y);
    try std.testing.expectEqual(@as(f64, 100), box.width);
    try std.testing.expectEqual(@as(f64, 50), box.height);
}

test "Type.middle" {
    const box = Type.init(0, 0, 100, 50);
    const mid = box.middle();
    try std.testing.expectEqual(@as(f32, 50), mid.getX());
    try std.testing.expectEqual(@as(f32, 25), mid.getY());
}

test "Type.contains" {
    const outer = Type.init(0, 0, 100, 100);
    const inner = Type.init(10, 10, 20, 20);
    const outside = Type.init(50, 50, 100, 100);

    try std.testing.expect(outer.contains(inner));
    try std.testing.expect(!outer.contains(outside));
}

test "Type.containsPoint" {
    const box = Type.init(0, 0, 100, 100);
    try std.testing.expect(box.containsPoint(Vector2D.init(50, 50)));
    try std.testing.expect(!box.containsPoint(Vector2D.init(150, 50)));
    try std.testing.expect(!box.containsPoint(Vector2D.init(100, 50))); // Edge is exclusive
}

test "Type.intersection" {
    const box1 = Type.init(0, 0, 100, 100);
    const box2 = Type.init(50, 50, 100, 100);
    const result = box1.intersection(box2);

    try std.testing.expectEqual(@as(f64, 50), result.x);
    try std.testing.expectEqual(@as(f64, 50), result.y);
    try std.testing.expectEqual(@as(f64, 50), result.width);
    try std.testing.expectEqual(@as(f64, 50), result.height);
}

test "Type.overlaps" {
    const box1 = Type.init(0, 0, 100, 100);
    const box2 = Type.init(50, 50, 100, 100);
    const box3 = Type.init(200, 200, 100, 100);

    try std.testing.expect(box1.overlaps(box2));
    try std.testing.expect(!box1.overlaps(box3));
}

test "Type.scale" {
    const box = Type.init(10, 10, 100, 50);
    const scaled = box.scale(2);

    try std.testing.expectEqual(@as(f64, 20), scaled.x);
    try std.testing.expectEqual(@as(f64, 20), scaled.y);
    try std.testing.expectEqual(@as(f64, 200), scaled.width);
    try std.testing.expectEqual(@as(f64, 100), scaled.height);
}

test "Type.expand" {
    const box = Type.init(10, 10, 100, 50);
    const expanded = box.expand(5);

    try std.testing.expectEqual(@as(f32, 5), expanded.x);
    try std.testing.expectEqual(@as(f32, 5), expanded.y);
    try std.testing.expectEqual(@as(f32, 110), expanded.width);
    try std.testing.expectEqual(@as(f32, 60), expanded.height);
}

test "Type.translate" {
    const box = Type.init(10, 20, 30, 40);
    const translated = box.translate(Vector2D.init(5, -5));

    try std.testing.expectEqual(@as(f32, 15), translated.x);
    try std.testing.expectEqual(@as(f32, 15), translated.y);
    try std.testing.expectEqual(@as(f32, 30), translated.width);
    try std.testing.expectEqual(@as(f32, 40), translated.height);
}

test "Type.scaleFromCenter" {
    const box = Type.init(10, 10, 20, 30);

    // Scale up from center
    const scaled_up = box.scaleFromCenter(2.0);
    try std.testing.expectEqual(@as(f32, 40), scaled_up.width);
    try std.testing.expectEqual(@as(f32, 60), scaled_up.height);

    // Center should remain the same
    const orig_center = box.middle();
    const new_center = scaled_up.middle();
    try std.testing.expectApproxEqAbs(orig_center.getX(), new_center.getX(), 0.01);
    try std.testing.expectApproxEqAbs(orig_center.getY(), new_center.getY(), 0.01);

    // Scale down from center
    const scaled_down = scaled_up.scaleFromCenter(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 20), scaled_down.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 30), scaled_down.height, 0.01);
}

test "Type.inside" {
    const inner = Type.init(10, 10, 20, 20);
    const outer = Type.init(0, 0, 100, 100);
    const overlapping = Type.init(50, 50, 100, 100);

    try std.testing.expect(inner.inside(outer));
    try std.testing.expect(!outer.inside(inner));
    try std.testing.expect(!overlapping.inside(outer));
}

test "Type.extentsFrom" {
    const box1 = Type.init(0, 0, 100, 100);
    const box2 = Type.init(50, 50, 100, 100);

    const extents = box1.extentsFrom(box2);

    try std.testing.expectEqual(@as(f32, 50), extents.top);
    try std.testing.expectEqual(@as(f32, 50), extents.left);
    try std.testing.expectEqual(@as(f32, -50), extents.bottom);
    try std.testing.expectEqual(@as(f32, -50), extents.right);
}

test "Type.transform - 90 degrees" {
    const box = Type.init(10, 20, 30, 40);
    const transformed = box.transform(.@"90", 100, 200);

    try std.testing.expectEqual(@as(f32, 140), transformed.x); // 200 - 20 - 40
    try std.testing.expectEqual(@as(f32, 10), transformed.y);
    try std.testing.expectEqual(@as(f32, 40), transformed.width); // height becomes width
    try std.testing.expectEqual(@as(f32, 30), transformed.height); // width becomes height
}

test "Type.transform - flipped" {
    const box = Type.init(10, 20, 30, 40);
    const transformed = box.transform(.flipped, 100, 200);

    try std.testing.expectEqual(@as(f32, 60), transformed.x); // 100 - 10 - 30
    try std.testing.expectEqual(@as(f32, 20), transformed.y);
    try std.testing.expectEqual(@as(f32, 30), transformed.width);
    try std.testing.expectEqual(@as(f32, 40), transformed.height);
}

test "Type.empty" {
    const empty1 = Type.init(0, 0, 0, 100);
    const empty2 = Type.init(0, 0, 100, 0);
    const not_empty = Type.init(0, 0, 10, 10);

    try std.testing.expect(empty1.empty());
    try std.testing.expect(empty2.empty());
    try std.testing.expect(!not_empty.empty());
}

test "Type - negative dimensions" {
    const box = Type.init(0, 0, -100, -100);

    // Negative dimensions are technically non-empty (just inverted)
    try std.testing.expectEqual(@as(f32, -100), box.width);
    try std.testing.expectEqual(@as(f32, -100), box.height);

    // noNegativeSize should fix it
    const fixed = box.noNegativeSize();
    try std.testing.expectEqual(@as(f32, -100), fixed.x);
    try std.testing.expectEqual(@as(f32, -100), fixed.y);
    try std.testing.expectEqual(@as(f32, 100), fixed.width);
    try std.testing.expectEqual(@as(f32, 100), fixed.height);

    // Fixed box should not be empty
    try std.testing.expect(!fixed.empty());
}

test "Type - infinity coordinates" {
    const inf = std.math.inf(f32);
    const box = Type.init(inf, 0, 100, 100);

    try std.testing.expect(std.math.isInf(box.x));
    try std.testing.expect(std.math.isFinite(box.width));

    // Operations should handle infinity gracefully
    const translated = box.translate(Vector2D.init(10, 10));
    try std.testing.expect(std.math.isInf(translated.x));

    // Middle with infinity
    const mid = box.middle();
    try std.testing.expect(std.math.isInf(mid.getX()));
}

test "Type - NaN coordinates" {
    const nan_val = std.math.nan(f32);
    const box = Type.init(nan_val, 0, 100, 100);

    try std.testing.expect(std.math.isNan(box.x));

    // Operations with NaN propagate NaN
    const translated = box.translate(Vector2D.init(10, 10));
    try std.testing.expect(std.math.isNan(translated.x));

    // containsPoint with NaN should return false
    const contains = box.containsPoint(Vector2D.init(50, 50));
    try std.testing.expect(!contains);
}

test "Type - overflow on large coordinates" {
    const very_large = std.math.floatMax(f32) - 10;
    const box = Type.init(very_large, 0, 100, 100);

    // Translate should handle overflow
    const translated = box.translate(Vector2D.init(100, 0));

    // Result may be infinity due to overflow, but should not crash
    try std.testing.expect(std.math.isFinite(translated.x) or std.math.isInf(translated.x));
}

test "Type - zero-area box containment at boundary" {
    // Zero-width box
    const zero_width = Type.init(10, 10, 0, 100);

    // Point exactly at x=10 (left edge)
    const point_at_edge = Vector2D.init(10, 50);

    // Zero-width box should not contain points (empty)
    try std.testing.expect(zero_width.empty());
    try std.testing.expect(!zero_width.containsPoint(point_at_edge));

    // Zero-height box
    const zero_height = Type.init(10, 10, 100, 0);
    const point_at_y = Vector2D.init(50, 10);

    try std.testing.expect(zero_height.empty());
    try std.testing.expect(!zero_height.containsPoint(point_at_y));
}

test "Type - empty box operations" {
    const empty = Type.init(10, 10, 0, 0);
    const normal = Type.init(0, 0, 100, 100);

    try std.testing.expect(empty.empty());

    // Intersection with empty
    const intersect1 = empty.intersection(normal);
    try std.testing.expect(intersect1.empty());

    // Overlaps with empty
    try std.testing.expect(!empty.overlaps(normal));
    try std.testing.expect(!normal.overlaps(empty));

    // Contains with empty
    try std.testing.expect(!empty.contains(normal));
    try std.testing.expect(normal.contains(empty)); // Technically contains a zero-area region

    // Empty inside normal
    try std.testing.expect(empty.inside(normal));
}

test "Type.scaleFromCenter - zero scale factor" {
    const box = Type.init(10, 10, 100, 50);
    const scaled = box.scaleFromCenter(0.0);

    // Should result in zero-area box at center
    try std.testing.expectEqual(@as(f32, 0), scaled.width);
    try std.testing.expectEqual(@as(f32, 0), scaled.height);

    // Center should remain the same
    const orig_center = box.middle();
    const new_center = scaled.middle();

    // With zero size, middle is just the position
    try std.testing.expectApproxEqAbs(orig_center.getX(), new_center.getX(), 0.01);
    try std.testing.expectApproxEqAbs(orig_center.getY(), new_center.getY(), 0.01);
}

test "Type.scaleFromCenter - negative scale factor" {
    const box = Type.init(10, 10, 100, 50);
    const scaled = box.scaleFromCenter(-1.0);

    // Negative scale creates negative dimensions
    try std.testing.expectEqual(@as(f32, -100), scaled.width);
    try std.testing.expectEqual(@as(f32, -50), scaled.height);

    // Should be fixable with noNegativeSize
    const fixed = scaled.noNegativeSize();
    try std.testing.expectEqual(@as(f32, 100), fixed.width);
    try std.testing.expectEqual(@as(f32, 50), fixed.height);
}

test "Type - intersection with non-overlapping boxes" {
    const box1 = Type.init(0, 0, 50, 50);
    const box2 = Type.init(100, 100, 50, 50);

    const intersect = box1.intersection(box2);

    // Non-overlapping boxes produce empty intersection
    try std.testing.expect(intersect.empty());
    try std.testing.expectEqual(@as(f32, 0), intersect.width);
    try std.testing.expectEqual(@as(f32, 0), intersect.height);
}

test "Type - intersection of box with itself" {
    const box = Type.init(10, 20, 100, 80);
    const intersect = box.intersection(box);

    // Type intersected with itself should be itself
    try std.testing.expectEqual(box.x, intersect.x);
    try std.testing.expectEqual(box.y, intersect.y);
    try std.testing.expectEqual(box.width, intersect.width);
    try std.testing.expectEqual(box.height, intersect.height);
}

test "Type.contains - touching boundaries" {
    const outer = Type.init(0, 0, 100, 100);

    // Type exactly at boundaries
    const at_left_edge = Type.init(0, 0, 50, 50);
    const at_right_edge = Type.init(50, 50, 50, 50);
    const exceeds_by_one = Type.init(0, 0, 101, 100);

    try std.testing.expect(outer.contains(at_left_edge));
    try std.testing.expect(outer.contains(at_right_edge));
    try std.testing.expect(!outer.contains(exceeds_by_one));
}

test "Type.containsPoint - exact boundary test" {
    const box = Type.init(10, 10, 100, 100);

    // Points at exact boundaries
    const top_left = Vector2D.init(10, 10);
    const bottom_right = Vector2D.init(110, 110);
    const just_inside = Vector2D.init(10.001, 10.001);

    // Inclusive at start, exclusive at end
    try std.testing.expect(box.containsPoint(top_left));
    try std.testing.expect(!box.containsPoint(bottom_right)); // Exclusive
    try std.testing.expect(box.containsPoint(just_inside));
}

test "Type.transform - all transforms preserve area" {
    const box = Type.init(10, 20, 100, 50);
    const area = box.width * box.height;

    const transforms = [_]Transform{
        .normal,  .@"90",      .@"180",      .@"270",
        .flipped, .flipped_90, .flipped_180, .flipped_270,
    };

    for (transforms) |t| {
        const transformed = box.transform(t, 1920, 1080);
        const new_area = transformed.width * transformed.height;

        // Area should be preserved (might be rotated)
        try std.testing.expectApproxEqAbs(area, new_area, 0.01);
    }
}

test "Type.expand - negative expansion (shrink)" {
    const box = Type.init(10, 10, 100, 50);
    const shrunk = box.expand(-5);

    // Negative expansion shrinks the box
    try std.testing.expectEqual(@as(f32, 15), shrunk.x);
    try std.testing.expectEqual(@as(f32, 15), shrunk.y);
    try std.testing.expectEqual(@as(f32, 90), shrunk.width);
    try std.testing.expectEqual(@as(f32, 40), shrunk.height);
}

test "Type.expand - over-shrink creates negative dimensions" {
    const box = Type.init(10, 10, 20, 20);
    const over_shrunk = box.expand(-15);

    // Over-shrinking creates negative dimensions
    try std.testing.expectEqual(@as(f32, -10), over_shrunk.width);
    try std.testing.expectEqual(@as(f32, -10), over_shrunk.height);

    // Should be fixable
    const fixed = over_shrunk.noNegativeSize();
    try std.testing.expectEqual(@as(f32, 10), fixed.width);
    try std.testing.expectEqual(@as(f32, 10), fixed.height);
}

test "Type.extentsFrom - various configurations" {
    const box1 = Type.init(0, 0, 100, 100);

    // box2 inside box1
    const box2_inside = Type.init(10, 10, 20, 20);
    const extents_inside = box1.extentsFrom(box2_inside);
    try std.testing.expect(extents_inside.top > 0);
    try std.testing.expect(extents_inside.left > 0);
    try std.testing.expect(extents_inside.bottom > 0);
    try std.testing.expect(extents_inside.right > 0);

    // box2 extends beyond box1
    const box2_beyond = Type.init(50, 50, 100, 100);
    const extents_beyond = box1.extentsFrom(box2_beyond);
    try std.testing.expect(extents_beyond.top > 0);
    try std.testing.expect(extents_beyond.bottom < 0); // Extends beyond
    try std.testing.expect(extents_beyond.right < 0); // Extends beyond
}
