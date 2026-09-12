//! Output-local scene planning and damage tracking.

const std = @import("std");
const testing = @import("core").testing;
const strip = @import("../layout/strip.zig");
const ring_geometry = @import("../ring_geometry.zig");

pub const Layer = enum(u8) {
    wallpaper,
    toplevel,
    popup,
    shell,
    cursor,
};

pub const PhysicalGeometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Node = struct {
    surface_id: u32,
    layer: Layer,
    logical: strip.Geometry,
    opacity: f32 = 1,
    damaged: bool = true,

    pub fn physical(self: Node, scale: f32) PhysicalGeometry {
        const left = scaledEdge(self.logical.x, scale);
        const top = scaledEdge(self.logical.y, scale);
        const right = scaledEdge(self.logical.x + self.logical.width, scale);
        const bottom = scaledEdge(self.logical.y + self.logical.height, scale);
        return .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
        };
    }
};

pub const Type = struct {
    nodes: std.ArrayList(Node) = .empty,
    shell_quads: std.ArrayList(ring_geometry.Quad) = .empty,
    output_damaged: bool = false,

    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.shell_quads.deinit(allocator);
    }

    pub fn add(self: *Type, allocator: std.mem.Allocator, node: Node) !void {
        try self.nodes.append(allocator, node);
        self.output_damaged = self.output_damaged or node.damaged;
    }

    pub fn removeSurface(self: *Type, surface_id: u32) void {
        var index: usize = 0;
        while (index < self.nodes.items.len) {
            if (self.nodes.items[index].surface_id != surface_id) {
                index += 1;
                continue;
            }
            _ = self.nodes.orderedRemove(index);
            self.output_damaged = true;
        }
    }

    pub fn setShellQuads(
        self: *Type,
        allocator: std.mem.Allocator,
        quads: []const ring_geometry.Quad,
    ) !void {
        self.shell_quads.clearRetainingCapacity();
        try self.shell_quads.appendSlice(allocator, quads);
        self.output_damaged = true;
    }

    pub fn clearShellQuads(self: *Type) void {
        if (self.shell_quads.items.len == 0) return;
        self.shell_quads.clearRetainingCapacity();
        self.output_damaged = true;
    }

    /// Returns whether one output composite must be submitted.
    pub fn beginFrame(self: *Type) bool {
        if (!self.output_damaged) return false;
        self.sort();
        return true;
    }

    pub fn finishFrame(self: *Type) void {
        for (self.nodes.items) |*node| node.damaged = false;
        self.output_damaged = false;
    }

    fn sort(self: *Type) void {
        std.mem.sort(Node, self.nodes.items, {}, lessThan);
    }
};

fn lessThan(_: void, lhs: Node, rhs: Node) bool {
    return @intFromEnum(lhs.layer) < @intFromEnum(rhs.layer);
}

fn scaledEdge(logical: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * scale));
}

test "scene converts logical edges without fractional gaps" {
    const left = Node{
        .surface_id = 1,
        .layer = .toplevel,
        .logical = .{ .x = 0, .y = 0, .width = 333, .height = 400 },
    };
    const right = Node{
        .surface_id = 2,
        .layer = .toplevel,
        .logical = .{ .x = 333, .y = 0, .width = 333, .height = 400 },
    };
    const left_physical = left.physical(1.5);
    const right_physical = right.physical(1.5);
    try testing.expectEqual(left_physical.x + left_physical.width, right_physical.x);
}

test "scene sorts layers and elides idle frames" {
    var scene: Type = .{};
    defer scene.deinit(testing.allocator);
    try scene.add(testing.allocator, .{
        .surface_id = 3,
        .layer = .popup,
        .logical = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    });
    try scene.add(testing.allocator, .{
        .surface_id = 2,
        .layer = .toplevel,
        .logical = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    });

    try testing.expect(scene.beginFrame());
    try testing.expectEqual(Layer.toplevel, scene.nodes.items[0].layer);
    scene.finishFrame();
    try testing.expectFalse(scene.beginFrame());
}

test "scene physical geometry covers scale matrix" {
    const node = Node{
        .surface_id = 1,
        .layer = .toplevel,
        .logical = .{ .x = 10, .y = 20, .width = 100, .height = 50 },
    };
    try testing.expectEqual(PhysicalGeometry{ .x = 10, .y = 20, .width = 100, .height = 50 }, node.physical(1));
    try testing.expectEqual(PhysicalGeometry{ .x = 15, .y = 30, .width = 150, .height = 75 }, node.physical(1.5));
    try testing.expectEqual(PhysicalGeometry{ .x = 20, .y = 40, .width = 200, .height = 100 }, node.physical(2));
}

test "scene replaces and clears transient shell quads" {
    var scene: Type = .{};
    defer scene.deinit(testing.allocator);
    const first = [_]ring_geometry.Quad{.{
        .x = 1,
        .y = 2,
        .width = 3,
        .height = 4,
        .radius = 1,
        .color = .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 },
    }};
    try scene.setShellQuads(testing.allocator, &first);
    try testing.expectEqual(@as(usize, 1), scene.shell_quads.items.len);
    try testing.expect(scene.output_damaged);
    scene.clearShellQuads();
    try testing.expectEqual(@as(usize, 0), scene.shell_quads.items.len);
}
