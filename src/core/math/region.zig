const std = @import("std");
const Vector2D = @import("vector2d.zig").Vector2D;
const Box = @import("box.zig").Box;
const Transform = @import("transform.zig").Transform;

// Import pixman
const c = @cImport({
    @cInclude("pixman.h");
});

const MAX_REGION_SIDE: i64 = 10000000;

pub const Region = struct {
    region: c.pixman_region32_t,
    allocator: std.mem.Allocator,

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

    pub fn clone(self: *const Region) Region {
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

    pub fn set(self: *Region, other: *const Region) *Region {
        _ = c.pixman_region32_copy(&self.region, &other.region);
        return self;
    }

    pub fn add(self: *Region, other: *const Region) *Region {
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

    pub fn subtract(self: *Region, other: *const Region) *Region {
        _ = c.pixman_region32_subtract(&self.region, &self.region, &other.region);
        return self;
    }

    pub fn intersect(self: *Region, other: *const Region) *Region {
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

    pub fn translate(self: *Region, vec: Vector2D) *Region {
        c.pixman_region32_translate(&self.region, @intFromFloat(vec.x), @intFromFloat(vec.y));
        return self;
    }

    pub fn transform(self: *Region, t: Transform, w: f32, h: f32) !*Region {
        if (t == .normal) return self;

        const rects = try self.getRects();
        defer self.allocator.free(rects);

        _ = self.clear();

        const transforms_module = @import("transforms.zig");
        for (rects) |r| {
            var xfmd = Box{
                .x = @floatFromInt(r.x1),
                .y = @floatFromInt(r.y1),
                .width = @as(f32, @floatFromInt(r.x2)) - @as(f32, @floatFromInt(r.x1)),
                .height = @as(f32, @floatFromInt(r.y2)) - @as(f32, @floatFromInt(r.y1)),
            };
            xfmd = transforms_module.transformBox(xfmd, t, w, h);
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
        return self.scale(Vector2D.init(scale_factor, scale_factor));
    }

    pub fn scale(self: *Region, scale_vec: Vector2D) !*Region {
        if (scale_vec.x == 1.0 and scale_vec.y == 1.0) return self;

        var rects_num: c_int = 0;
        const rects_arr = c.pixman_region32_rectangles(&self.region, &rects_num);

        var boxes = try self.allocator.alloc(c.pixman_box32_t, @intCast(rects_num));
        defer self.allocator.free(boxes);

        for (0..@intCast(rects_num)) |i| {
            boxes[i].x1 = @intFromFloat(@floor(@as(f32, @floatFromInt(rects_arr[i].x1)) * scale_vec.x));
            boxes[i].x2 = @intFromFloat(@ceil(@as(f32, @floatFromInt(rects_arr[i].x2)) * scale_vec.x));
            boxes[i].y1 = @intFromFloat(@floor(@as(f32, @floatFromInt(rects_arr[i].y1)) * scale_vec.y));
            boxes[i].y2 = @intFromFloat(@ceil(@as(f32, @floatFromInt(rects_arr[i].y2)) * scale_vec.y));
        }

        c.pixman_region32_fini(&self.region);
        _ = c.pixman_region32_init_rects(&self.region, boxes.ptr, @intCast(boxes.len));
        return self;
    }

    pub fn getRects(self: *const Region) ![]c.pixman_box32_t {
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

    pub fn containsPoint(self: *const Region, vec: Vector2D) bool {
        return c.pixman_region32_contains_point(&self.region, @intFromFloat(vec.x), @intFromFloat(vec.y), null) != 0;
    }

    pub fn empty(self: *const Region) bool {
        return c.pixman_region32_not_empty(&self.region) == 0;
    }

    pub fn closestPoint(self: *const Region, vec: Vector2D) !Vector2D {
        if (self.containsPoint(vec)) return vec;

        var best_dist: f32 = std.math.floatMax(f32);
        var leader = vec;

        const rects = try self.getRects();
        defer self.allocator.free(rects);

        for (rects) |box| {
            var x: f32 = 0;
            var y: f32 = 0;

            if (vec.x >= @as(f32, @floatFromInt(box.x2))) {
                x = @as(f32, @floatFromInt(box.x2)) - 1.0;
            } else if (vec.x < @as(f32, @floatFromInt(box.x1))) {
                x = @floatFromInt(box.x1);
            } else {
                x = vec.x;
            }

            if (vec.y >= @as(f32, @floatFromInt(box.y2))) {
                y = @as(f32, @floatFromInt(box.y2)) - 1.0;
            } else if (vec.y < @as(f32, @floatFromInt(box.y1))) {
                y = @floatFromInt(box.y1);
            } else {
                y = vec.y;
            }

            const distance = (x * x) + (y * y);
            if (distance < best_dist) {
                best_dist = distance;
                leader = Vector2D.init(x, y);
            }
        }

        return leader;
    }

    pub fn pixman(self: *const Region) *const c.pixman_region32_t {
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

test "Region.containsPoint" {
    var region = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region.deinit();

    try std.testing.expect(region.containsPoint(Vector2D.init(50, 50)));
    try std.testing.expect(!region.containsPoint(Vector2D.init(150, 50)));
}

test "Region.add" {
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

test "Region.intersect" {
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

test "Region.subtract" {
    var region1 = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region1.deinit();

    var region2 = Region.initRect(std.testing.allocator, 25, 25, 50, 50);
    defer region2.deinit();

    _ = region1.subtract(&region2);

    try std.testing.expect(!region1.empty());
}

test "Region.translate" {
    var region = Region.initRect(std.testing.allocator, 0, 0, 100, 100);
    defer region.deinit();

    _ = region.translate(Vector2D.init(50, 50));

    const extents = region.getExtents();
    try std.testing.expectEqual(@as(f64, 50), extents.x);
    try std.testing.expectEqual(@as(f64, 50), extents.y);
}

test "Region.scale" {
    var region = Region.initRect(std.testing.allocator, 10, 10, 100, 50);
    defer region.deinit();

    _ = try region.scale(Vector2D.init(2, 2));

    const extents = region.getExtents();
    try std.testing.expectEqual(@as(f32, 20), extents.x);
    try std.testing.expectEqual(@as(f32, 20), extents.y);
    try std.testing.expectEqual(@as(f32, 200), extents.width);
    try std.testing.expectEqual(@as(f32, 100), extents.height);
}
