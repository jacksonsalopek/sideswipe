//! Pure strip layout model.

const std = @import("std");
const testing = @import("core").testing;

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const Geometry = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Width = enum {
    quarter,
    third,
    half,
    two_thirds,
    full,

    pub fn pixels(self: Width, viewport_width: i32) i32 {
        return switch (self) {
            .quarter => @divTrunc(viewport_width, 4),
            .third => @divTrunc(viewport_width, 3),
            .half => @divTrunc(viewport_width, 2),
            .two_thirds => @divTrunc(viewport_width * 2, 3),
            .full => viewport_width,
        };
    }
};

pub const Tile = struct {
    id: u32,
    min_size: Size = .{ .width = 0, .height = 0 },
};

pub const Column = struct {
    id: u32,
    width: Width = .half,
    tiles: []const Tile,
};

pub const Workspace = struct {
    id: u32,
    columns: []const Column,
    focused_column: ?usize = null,
};

pub const Output = struct {
    id: u32,
    workspaces: []const Workspace,
    active_workspace: usize = 0,
};

pub const Input = struct {
    viewport: Size,
    scale: f32,
    workspace: Workspace,
};

pub const Placement = struct {
    tile_id: u32,
    column_id: u32,
    geometry: Geometry,
    configure_serial: u32,
};

pub const Result = struct {
    placements: std.ArrayList(Placement) = .empty,
    viewport_x: i32 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.placements.deinit(allocator);
    }
};

pub const Error = error{
    InvalidViewport,
    InvalidScale,
    MinimumSizesExceedViewport,
};

/// Computes integer logical tile geometries without mutating workspace state.
pub fn compute(
    allocator: std.mem.Allocator,
    input: Input,
    first_serial: u32,
) (Error || std.mem.Allocator.Error)!Result {
    if (input.viewport.width <= 0 or input.viewport.height <= 0) return error.InvalidViewport;
    if (!std.math.isFinite(input.scale) or input.scale <= 0) return error.InvalidScale;

    var result: Result = .{};
    errdefer result.deinit(allocator);

    var x: i32 = 0;
    var serial = first_serial;
    for (input.workspace.columns, 0..) |column, column_index| {
        const width = @max(1, column.width.pixels(input.viewport.width));
        try appendColumn(allocator, &result, column, x, width, input.viewport.height, &serial);
        if (input.workspace.focused_column == column_index) {
            result.viewport_x = focusedViewportX(x, width, input.viewport.width);
        }
        x += width;
    }
    return result;
}

fn appendColumn(
    allocator: std.mem.Allocator,
    result: *Result,
    column: Column,
    x: i32,
    width: i32,
    height: i32,
    serial: *u32,
) (Error || std.mem.Allocator.Error)!void {
    if (column.tiles.len == 0) return;

    var minimum_total: i32 = 0;
    for (column.tiles) |tile| minimum_total += @max(0, tile.min_size.height);
    if (minimum_total > height) return error.MinimumSizesExceedViewport;

    const unclaimed = height - minimum_total;
    const share = @divTrunc(unclaimed, @as(i32, @intCast(column.tiles.len)));
    var remainder = @mod(unclaimed, @as(i32, @intCast(column.tiles.len)));
    var y: i32 = 0;

    for (column.tiles) |tile| {
        const extra: i32 = if (remainder > 0) 1 else 0;
        remainder -= extra;
        const tile_height = @max(0, tile.min_size.height) + share + extra;
        try result.placements.append(allocator, .{
            .tile_id = tile.id,
            .column_id = column.id,
            .geometry = .{ .x = x, .y = y, .width = width, .height = tile_height },
            .configure_serial = serial.*,
        });
        serial.* +%= 1;
        y += tile_height;
    }
}

fn focusedViewportX(column_x: i32, column_width: i32, viewport_width: i32) i32 {
    const right = column_x + column_width;
    if (right <= viewport_width) return 0;
    return right - viewport_width;
}

test "strip layout splits a column into logical tiles" {
    const tiles = [_]Tile{ .{ .id = 10 }, .{ .id = 11 } };
    const columns = [_]Column{.{ .id = 1, .width = .half, .tiles = &tiles }};
    var result = try compute(testing.allocator, .{
        .viewport = .{ .width = 1200, .height = 800 },
        .scale = 1.5,
        .workspace = .{ .id = 4, .columns = &columns, .focused_column = 0 },
    }, 20);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.placements.items.len);
    try testing.expectEqual(Geometry{ .x = 0, .y = 0, .width = 600, .height = 400 }, result.placements.items[0].geometry);
    try testing.expectEqual(@as(u32, 21), result.placements.items[1].configure_serial);
}

test "strip layout preserves minimum heights" {
    const tiles = [_]Tile{
        .{ .id = 1, .min_size = .{ .width = 0, .height = 500 } },
        .{ .id = 2, .min_size = .{ .width = 0, .height = 100 } },
    };
    const columns = [_]Column{.{ .id = 1, .tiles = &tiles }};
    var result = try compute(testing.allocator, .{
        .viewport = .{ .width = 1000, .height = 800 },
        .scale = 2,
        .workspace = .{ .id = 1, .columns = &columns },
    }, 1);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 600), result.placements.items[0].geometry.height);
    try testing.expectEqual(@as(i32, 200), result.placements.items[1].geometry.height);
}

test "strip layout rejects impossible minimum heights" {
    const tiles = [_]Tile{.{ .id = 1, .min_size = .{ .width = 0, .height = 801 } }};
    const columns = [_]Column{.{ .id = 1, .tiles = &tiles }};
    try testing.expectError(error.MinimumSizesExceedViewport, compute(testing.allocator, .{
        .viewport = .{ .width = 1000, .height = 800 },
        .scale = 1,
        .workspace = .{ .id = 1, .columns = &columns },
    }, 1));
}

test "strip layout is idempotent at fractional scales" {
    const tiles = [_]Tile{.{ .id = 1 }};
    const columns = [_]Column{
        .{ .id = 1, .width = .two_thirds, .tiles = &tiles },
        .{ .id = 2, .width = .half, .tiles = &tiles },
    };
    const input: Input = .{
        .viewport = .{ .width = 999, .height = 601 },
        .scale = 1.5,
        .workspace = .{ .id = 1, .columns = &columns, .focused_column = 1 },
    };
    var first = try compute(testing.allocator, input, 50);
    defer first.deinit(testing.allocator);
    var second = try compute(testing.allocator, input, 50);
    defer second.deinit(testing.allocator);

    try testing.expectEqualSlices(Placement, first.placements.items, second.placements.items);
    try testing.expectEqual(first.viewport_x, second.viewport_x);
}
