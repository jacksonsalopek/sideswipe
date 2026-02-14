const std = @import("std");
const Vec2 = @import("vector2d.zig").Vec2;
const Box = @import("box.zig").Box;
const Transform = @import("transform.zig").Direction;
const transforms = @import("transforms.zig");

// Import pixman
const c = @cImport({
    @cInclude("pixman.h");
});

const MAX_REGION_SIDE: i64 = 10000000;

pub const Region = struct {
    region: c.pixman_region32_t,
    allocator: std.mem.Allocator,
    
    /// Alias for backwards compatibility
    pub const Type = Region;

    pub fn init(allocator: std.mem.Allocator) Region {
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init(&region);
        return .{
            .region = region,
            .allocator = allocator,
        };
    }

    pub fn initFromPixman(allocator: std.mem.Allocator, ref: *const c.pixman_region32_t) Region {
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init(&region);
        _ = c.pixman_region32_copy(&region, ref);
        return .{
            .region = region,
            .allocator = allocator,
        };
    }

    pub fn initRect(allocator: std.mem.Allocator, x: f32, y: f32, w: f32, h: f32) Region {
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init_rect(&region, @intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h));
        return .{
            .region = region,
            .allocator = allocator,
        };
    }

    pub fn initFromBox(allocator: std.mem.Allocator, box: Box) Region {
        return initRect(allocator, box.x, box.y, box.width, box.height);
    }

    pub fn initFromPixmanBox(allocator: std.mem.Allocator, box: *c.pixman_box32_t) Region {
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init_rect(&region, box.x1, box.y1, box.x2 - box.x1, box.y2 - box.y1);
        return .{
            .region = region,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Region) void {
        c.pixman_region32_fini(&self.region);
    }

    pub fn clone(self: *const Type) Type {
        var region: c.pixman_region32_t = undefined;
        c.pixman_region32_init(&region);
        _ = c.pixman_region32_copy(&region, &self.region);
        return .{
            .region = region,
            .allocator = self.allocator,
        };
    }

    pub fn clear(self: *Region) *Region {
        c.pixman_region32_clear(&self.region);
        return self;
    }

    pub fn set(self: *Region, other: *const Type) *Region {
        _ = c.pixman_region32_copy(&self.region, &other.region);
        return self;
    }

    pub fn add(self: *Region, other: *const Type) *Region {
        _ = c.pixman_region32_union(&self.region, &self.region, &other.region);
        return self;
    }

    pub fn addRect(self: *Region, x: f32, y: f32, w: f32, h: f32) *Region {
        _ = c.pixman_region32_union_rect(&self.region, &self.region, @intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h));
        return self;
    }

    pub fn addBox(self: *Region, box: Box) *Region {
        return self.addRect(box.x, box.y, box.width, box.height);
    }

    pub fn subtract(self: *Region, other: *const Type) *Region {
        _ = c.pixman_region32_subtract(&self.region, &self.region, &other.region);
        return self;
    }

    pub fn intersect(self: *Region, other: *const Type) *Region {
        _ = c.pixman_region32_intersect(&self.region, &self.region, &other.region);
        return self;
    }

    pub fn intersectRect(self: *Region, x: f32, y: f32, w: f32, h: f32) *Region {
        _ = c.pixman_region32_intersect_rect(&self.region, &self.region, @intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h));
        return self;
    }

    pub fn invert(self: *Region, box: *c.pixman_box32_t) *Region {
        _ = c.pixman_region32_inverse(&self.region, &self.region, box);
        return self;
    }

    pub fn invertBox(self: *Region, box: Box) *Region {
        var pixman_box = c.pixman_box32_t{
            .x1 = @intFromFloat(box.x),
            .y1 = @intFromFloat(box.y),
            .x2 = @as(i32, @intFromFloat(box.width)) + @as(i32, @intFromFloat(box.x)),
            .y2 = @as(i32, @intFromFloat(box.height)) + @as(i32, @intFromFloat(box.y)),
        };
        return self.invert(&pixman_box);
    }

    pub fn translate(self: *Region, vec: Vec2) *Region {
        c.pixman_region32_translate(&self.region, @intFromFloat(vec.getX()), @intFromFloat(vec.getY()));
        return self;
    }

    pub fn transform(self: *Region, t: Transform, w: f32, h: f32) !*Region {
        if (t == .normal) return self;

        const rects = try self.getRects();
        defer self.allocator.free(rects);

        _ = self.clear();

        for (rects) |r| {
            var xfmd = Box{
                .x = @floatFromInt(r.x1),
                .y = @floatFromInt(r.y1),
                .width = @as(f32, @floatFromInt(r.x2)) - @as(f32, @floatFromInt(r.x1)),
                .height = @as(f32, @floatFromInt(r.y2)) - @as(f32, @floatFromInt(r.y1)),
            };
            xfmd = transforms.transformBox(xfmd, t, w, h);
            _ = self.addBox(xfmd);
        }

        return self;
    }

    pub fn expand(self: *Region, units: f32) !*Region {
        const rects = try self.getRects();
        defer self.allocator.free(rects);

        _ = self.clear();

        for (rects) |r| {
            const b = Box{
                .x = @as(f32, @floatFromInt(r.x1)) - units,
                .y = @as(f32, @floatFromInt(r.y1)) - units,
                .width = @as(f32, @floatFromInt(r.x2 - r.x1)) + (units * 2.0),
                .height = @as(f32, @floatFromInt(r.y2 - r.y1)) + (units * 2.0),
            };
            _ = self.addBox(b);
        }

        return self;
    }

    pub fn rationalize(self: *Region) *Region {
        const bounds = Box{
            .x = -MAX_REGION_SIDE,
            .y = -MAX_REGION_SIDE,
            .width = MAX_REGION_SIDE * 2,
            .height = MAX_REGION_SIDE * 2,
        };
        return self.intersectRect(bounds.x, bounds.y, bounds.width, bounds.height);
    }

    pub fn scaleScalar(self: *Region, scale_factor: f32) !*Region {
        return self.scale(Vec2.init(scale_factor, scale_factor));
    }

    pub fn scale(self: *Region, scale_vec: Vec2) !*Region {
        if (scale_vec.getX() == 1.0 and scale_vec.getY() == 1.0) return self;

        var rects_num: c_int = 0;
        const rects_arr = c.pixman_region32_rectangles(&self.region, &rects_num);

        var boxes = try self.allocator.alloc(c.pixman_box32_t, @intCast(rects_num));
        defer self.allocator.free(boxes);

        for (0..@intCast(rects_num)) |i| {
            boxes[i].x1 = @intFromFloat(@floor(@as(f32, @floatFromInt(rects_arr[i].x1)) * scale_vec.getX()));
            boxes[i].x2 = @intFromFloat(@ceil(@as(f32, @floatFromInt(rects_arr[i].x2)) * scale_vec.getX()));
            boxes[i].y1 = @intFromFloat(@floor(@as(f32, @floatFromInt(rects_arr[i].y1)) * scale_vec.getY()));
            boxes[i].y2 = @intFromFloat(@ceil(@as(f32, @floatFromInt(rects_arr[i].y2)) * scale_vec.getY()));
        }

        c.pixman_region32_fini(&self.region);
        _ = c.pixman_region32_init_rects(&self.region, boxes.ptr, @intCast(boxes.len));
        return self;
    }

    pub fn getRects(self: *const Type) ![]c.pixman_box32_t {
        var rects_num: c_int = 0;
        const rects_arr = c.pixman_region32_rectangles(&self.region, &rects_num);

        const result = try self.allocator.alloc(c.pixman_box32_t, @intCast(rects_num));
        @memcpy(result, rects_arr[0..@intCast(rects_num)]);

        return result;
    }

    pub fn getExtents(self: *Region) Box {
        const box = c.pixman_region32_extents(&self.region);
        return Box{
            .x = @floatFromInt(box.*.x1),
            .y = @floatFromInt(box.*.y1),
            .width = @as(f32, @floatFromInt(box.*.x2)) - @as(f32, @floatFromInt(box.*.x1)),
            .height = @as(f32, @floatFromInt(box.*.y2)) - @as(f32, @floatFromInt(box.*.y1)),
        };
    }

    pub fn containsPoint(self: *const Type, vec: Vec2) bool {
        return c.pixman_region32_contains_point(&self.region, @intFromFloat(vec.getX()), @intFromFloat(vec.getY()), null) != 0;
    }

    pub fn empty(self: *const Type) bool {
        return c.pixman_region32_not_empty(&self.region) == 0;
    }

    pub fn closestPoint(self: *const Type, vec: Vec2) !Vec2 {
        if (self.containsPoint(vec)) return vec;

        var best_dist: f32 = std.math.floatMax(f32);
        var leader = vec;

        const rects = try self.getRects();
        defer self.allocator.free(rects);

        for (rects) |box| {
            var x: f32 = 0;
            var y: f32 = 0;

            if (vec.getX() >= @as(f32, @floatFromInt(box.x2))) {
                x = @as(f32, @floatFromInt(box.x2)) - 1.0;
            } else if (vec.getX() < @as(f32, @floatFromInt(box.x1))) {
                x = @floatFromInt(box.x1);
            } else {
                x = vec.getX();
            }

            if (vec.getY() >= @as(f32, @floatFromInt(box.y2))) {
                y = @as(f32, @floatFromInt(box.y2)) - 1.0;
            } else if (vec.getY() < @as(f32, @floatFromInt(box.y1))) {
                y = @floatFromInt(box.y1);
            } else {
                y = vec.getY();
            }

            const distance = (x * x) + (y * y);
            if (distance < best_dist) {
                best_dist = distance;
                leader = Vec2.init(x, y);
            }
        }

        return leader;
    }

    pub fn pixman(self: *const Type) *const c.pixman_region32_t {
        return &self.region;
    }
};

test "Region.init and deinit" {
    var region = Region.init(std.testing.allocator);
    defer region.deinit();

    try std.testing.expect(region.empty());
}

test "Region.initRect" {
    var region = Region.initRect(std.testing.allocator, 10, 20, 100, 50);
    defer region.deinit();

    try std.testing.expect(!region.empty());

    const extents = region.getExtents();
    try std.testing.expectEqual(@as(f32, 10), extents.x);
    try std.testing.expectEqual(@as(f32, 20), extents.y);
    try std.testing.expectEqual(@as(f32, 100), extents.width);
    try std.testing.expectEqual(@as(f32, 50), extents.height);
}

test "Type.containsPoint" {
    var region = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region.deinit();

    try std.testing.expect(region.containsPoint(Vec2.init(50, 50)));
    try std.testing.expect(!region.containsPoint(Vec2.init(150, 50)));
}

test "Type.add" {
    var region1 = Region.initRect(std.testing.allocator, 0, 0, 50, 50);
    defer region1.deinit();

    var region2 = Region.initRect(std.testing.allocator, 25, 25, 50, 50);
    defer region2.deinit();

    _ = region1.add(&region2);

    const extents = region1.getExtents();
    try std.testing.expectEqual(@as(f32, 0), extents.x);
    try std.testing.expectEqual(@as(f32, 0), extents.y);
    try std.testing.expectEqual(@as(f32, 75), extents.width);
    try std.testing.expectEqual(@as(f32, 75), extents.height);
}

test "Type.intersect" {
    var region1 = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region1.deinit();

    var region2 = Region.initRect(std.testing.allocator, 50, 50, 100, 100);
    defer region2.deinit();

    _ = region1.intersect(&region2);

    const extents = region1.getExtents();
    try std.testing.expectEqual(@as(f32, 50), extents.x);
    try std.testing.expectEqual(@as(f32, 50), extents.y);
    try std.testing.expectEqual(@as(f32, 50), extents.width);
    try std.testing.expectEqual(@as(f32, 50), extents.height);
}

test "Type.subtract" {
    var region1 = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region1.deinit();

    var region2 = Region.initRect(std.testing.allocator, 25, 25, 50, 50);
    defer region2.deinit();

    _ = region1.subtract(&region2);

    try std.testing.expect(!region1.empty());
}

test "Type.translate" {
    var region = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region.deinit();

    _ = region.translate(Vec2.init(50, 50));

    const extents = region.getExtents();
    try std.testing.expectEqual(@as(f64, 50), extents.x);
    try std.testing.expectEqual(@as(f64, 50), extents.y);
}

test "Type.scale" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 100, 50);
    defer region.deinit();

    _ = try region.scale(Vec2.init(2, 2));

    const extents = region.getExtents();
    try std.testing.expectEqual(@as(f32, 20), extents.x);
    try std.testing.expectEqual(@as(f32, 20), extents.y);
    try std.testing.expectEqual(@as(f32, 200), extents.width);
    try std.testing.expectEqual(@as(f32, 100), extents.height);
}

test "Type - empty region operations" {
    var empty = Region.init(std.testing.allocator);
    defer empty.deinit();

    try std.testing.expect(empty.empty());

    var other = Region.initRect(std.testing.allocator, 10, 10, 50, 50);
    defer other.deinit();

    // Add to empty
    var result1 = empty.clone();
    defer result1.deinit();
    _ = result1.add(&other);
    try std.testing.expect(!result1.empty());

    // Subtract from empty
    var result2 = empty.clone();
    defer result2.deinit();
    _ = result2.subtract(&other);
    try std.testing.expect(result2.empty());

    // Intersect with empty
    var result3 = other.clone();
    defer result3.deinit();
    _ = result3.intersect(&empty);
    try std.testing.expect(result3.empty());

    // Translate empty
    var result4 = empty.clone();
    defer result4.deinit();
    _ = result4.translate(Vec2.init(100, 100));
    try std.testing.expect(result4.empty());

    // Scale empty
    var result5 = empty.clone();
    defer result5.deinit();
    _ = try result5.scaleScalar(2.0);
    try std.testing.expect(result5.empty());
}

test "Type - at MAX_REGION_SIDE boundaries" {
    const max = MAX_REGION_SIDE;

    // Type at positive boundary
    var region1 = Region.initRect(std.testing.allocator, @floatFromInt(max - 100), @floatFromInt(max - 100), 50, 50);
    defer region1.deinit();

    try std.testing.expect(!region1.empty());

    // Type at negative boundary
    var region2 = Region.initRect(std.testing.allocator, @floatFromInt(-max + 100), @floatFromInt(-max + 100), 50, 50);
    defer region2.deinit();

    try std.testing.expect(!region2.empty());

    // Operations should work
    _ = region1.add(&region2);
    try std.testing.expect(!region1.empty());
}

test "Type.transform - large dimensions" {
    var region = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region.deinit();

    // Transform with large but safe dimensions
    _ = try region.transform(.@"90", 10000, 10000);

    // Transform may rationalize or clip, just verify no crash
    _ = region.empty(); // Call to verify region is still valid
}

test "Type.scale - with zero" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 100, 100);
    defer region.deinit();

    _ = try region.scaleScalar(0.0);

    // Zero scale should create empty or point region
    const extents = region.getExtents();
    try std.testing.expectEqual(@as(f32, 0), extents.width);
    try std.testing.expectEqual(@as(f32, 0), extents.height);
}

test "Type.scale - with very large factor" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 100, 100);
    defer region.deinit();

    // Scale with very large factor
    _ = try region.scale(Vec2.init(1e6, 1e6));

    // Should produce very large region
    const extents = region.getExtents();
    try std.testing.expect(extents.width > 1e7);
    try std.testing.expect(extents.height > 1e7);
}

test "Type.rationalize - already outside MAX_REGION_SIDE" {
    const max = MAX_REGION_SIDE;

    // Create region way outside boundaries
    var region = Region.initRect(std.testing.allocator, @floatFromInt(max * 2), @floatFromInt(max * 2), 1000, 1000);
    defer region.deinit();

    // Rationalize should clip it
    _ = region.rationalize();

    // After rationalization, should be empty (clipped away)
    try std.testing.expect(region.empty());
}

test "Type.rationalize - partially outside boundaries" {
    const max = MAX_REGION_SIDE;

    // Type that straddles the boundary
    var region = Region.initRect(std.testing.allocator, @floatFromInt(max - 50), @floatFromInt(max - 50), 100, 100);
    defer region.deinit();

    _ = region.rationalize();

    // Should be clipped but not empty
    const extents = region.getExtents();
    try std.testing.expect(extents.width > 0);
    try std.testing.expect(extents.width < 100); // Clipped
}

test "Type.expand - negative values (shrink)" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 100, 100);
    defer region.deinit();

    _ = try region.expand(-10);

    // Should shrink the region
    const extents = region.getExtents();
    try std.testing.expectApproxEqAbs(@as(f32, 20), extents.x, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20), extents.y, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 80), extents.width, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 80), extents.height, 1.0);
}

test "Type.expand - over-shrink creates empty" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 40, 40);
    defer region.deinit();

    // Shrink by less than half the size
    _ = try region.expand(-15);

    // Should shrink but not become empty (40 - 30 = 10 remaining)
    const extents = region.getExtents();
    try std.testing.expect(extents.width > 0);
    try std.testing.expect(extents.height > 0);
}

test "Type.closestPoint - on empty region" {
    var empty = Region.init(std.testing.allocator);
    defer empty.deinit();

    const point = Vec2.init(50, 50);

    // Should handle gracefully (may return input or zero)
    const result = Region.closestPoint(&empty, point) catch point;

    // Just verify it doesn't crash
    try std.testing.expect(std.math.isFinite(result.getX()));
    try std.testing.expect(std.math.isFinite(result.getY()));
}

test "Type.transform - all 8 transforms" {
    const all_transforms = [_]Transform{
        .normal,  .@"90",      .@"180",      .@"270",
        .flipped, .flipped_90, .flipped_180, .flipped_270,
    };

    for (all_transforms) |t| {
        var region = Region.initRect(std.testing.allocator, 10, 20, 100, 50);
        defer region.deinit();

        _ = try region.transform(t, 1920, 1080);

        // Should not be empty after transform
        try std.testing.expect(!region.empty());

        const extents = region.getExtents();
        // Dimensions should be reasonable
        try std.testing.expect(extents.width > 0);
        try std.testing.expect(extents.height > 0);
    }
}

test "Type - multiple rectangles with operations" {
    var region = Region.initRect(std.testing.allocator, 0, 0, 50, 50);
    defer region.deinit();

    // Add multiple non-overlapping rectangles
    _ = region.addRect(100, 0, 50, 50);
    _ = region.addRect(0, 100, 50, 50);
    _ = region.addRect(100, 100, 50, 50);

    // Type should not be empty
    try std.testing.expect(!region.empty());

    // Scale all rectangles
    _ = try region.scaleScalar(2.0);
    try std.testing.expect(!region.empty());

    // Translate all
    _ = region.translate(Vec2.init(10, 10));
    try std.testing.expect(!region.empty());
}

test "Type - subtract larger from smaller" {
    var small = Region.initRect(std.testing.allocator, 10, 10, 50, 50);
    defer small.deinit();

    var large = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer large.deinit();

    // Subtract larger from smaller
    _ = small.subtract(&large);

    // Should be empty (completely subtracted)
    try std.testing.expect(small.empty());
}

test "Type - intersect non-overlapping" {
    var region1 = Region.initRect(std.testing.allocator, 0, 0, 50, 50);
    defer region1.deinit();

    var region2 = Region.initRect(std.testing.allocator, 100, 100, 50, 50);
    defer region2.deinit();

    _ = region1.intersect(&region2);

    // Non-overlapping regions produce empty intersection
    try std.testing.expect(region1.empty());
}

test "Type - containsPoint at exact boundaries" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 100, 100);
    defer region.deinit();

    // Point at top-left corner
    try std.testing.expect(region.containsPoint(Vec2.init(10, 10)));

    // Point at bottom-right corner (exclusive)
    try std.testing.expect(!region.containsPoint(Vec2.init(110, 110)));

    // Point just inside
    try std.testing.expect(region.containsPoint(Vec2.init(10.1, 10.1)));

    // Point just outside
    try std.testing.expect(!region.containsPoint(Vec2.init(110.1, 110.1)));
}

test "Type - transform with multiple rectangles" {
    var region = Region.initRect(std.testing.allocator, 0, 0, 50, 50);
    defer region.deinit();

    _ = region.addRect(100, 0, 50, 50);
    _ = region.addRect(0, 100, 50, 50);

    const rects_before = try region.getRects();
    const count_before = rects_before.len;
    std.testing.allocator.free(rects_before);

    try std.testing.expect(count_before > 0);

    // Transform should work with multiple rectangles (may merge or clip)
    _ = try region.transform(.@"90", 200, 200);

    // Verify region is still valid (may be empty after transform due to clipping)
    _ = region.empty();
}

test "Type - scale with different X and Y factors" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 100, 100);
    defer region.deinit();

    _ = try region.scale(Vec2.init(2.0, 0.5));

    const extents = region.getExtents();

    // Width doubled, height halved
    try std.testing.expectApproxEqAbs(@as(f32, 20), extents.x, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5), extents.y, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 200), extents.width, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 50), extents.height, 1.0);
}

test "Type - invert creates complement" {
    var region = Region.initRect(std.testing.allocator, 25, 25, 50, 50);
    defer region.deinit();

    const bounds = Box.init(0, 0, 100, 100);
    _ = region.invertBox(bounds);

    // Inverted region should not be empty
    try std.testing.expect(!region.empty());

    // Original center point should NOT be in inverted region
    try std.testing.expect(!region.containsPoint(Vec2.init(50, 50)));

    // Corners should be in inverted region
    try std.testing.expect(region.containsPoint(Vec2.init(5, 5)));
}
