//! Main compositor state and management
//! Coordinates surfaces, backends, and protocol implementations

const std = @import("std");
const wayland = @import("wayland");
const backend = @import("backend");
const core = @import("core");

const Surface = @import("surface.zig").Surface;

/// Main compositor state
pub const Compositor = struct {
    allocator: std.mem.Allocator,
    server: *wayland.Server,
    coordinator: ?*backend.backend.Coordinator,
    surfaces: std.ArrayList(*Surface),
    next_surface_id: u32,

    const Self = @This();

    pub const Error = error{
        InitFailed,
        OutOfMemory,
    };

    /// Creates a new compositor instance
    pub fn init(allocator: std.mem.Allocator, server: *wayland.Server) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .server = server,
            .coordinator = null,
            .surfaces = std.ArrayList(*Surface){},
            .next_surface_id = 1,
        };

        return self;
    }

    /// Destroys the compositor and frees all resources
    pub fn deinit(self: *Self) void {
        // Clean up all surfaces
        for (self.surfaces.items) |surface| {
            surface.deinit();
        }
        self.surfaces.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Attaches a backend coordinator to the compositor
    pub fn attachBackend(self: *Self, coord: *backend.backend.Coordinator) void {
        self.coordinator = coord;
    }

    /// Creates a new surface and registers it with the compositor
    pub fn createSurface(self: *Self) Error!*Surface {
        const id = self.next_surface_id;
        self.next_surface_id += 1;

        const surface = try Surface.init(self.allocator, self, id);
        errdefer surface.deinit();

        try self.surfaces.append(self.allocator, surface);
        return surface;
    }

    /// Removes and destroys a surface
    pub fn destroySurface(self: *Self, surface: *Surface) void {
        // Find and remove from list
        for (self.surfaces.items, 0..) |s, i| {
            if (s == surface) {
                _ = self.surfaces.swapRemove(i);
                break;
            }
        }

        surface.deinit();
    }

    /// Gets the next serial number from the display
    pub fn nextSerial(self: *Self) u32 {
        const c = @import("wayland").c;
        return c.wl_display_next_serial(self.server.getDisplay());
    }
};

// Tests
const testing = core.testing;

test "Compositor - init and deinit" {
    const allocator = testing.allocator;

    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    var compositor = try Compositor.init(allocator, &server);
    defer compositor.deinit();

    try testing.expectEqual(@as(u32, 1), compositor.next_surface_id);
    try testing.expectEqual(@as(usize, 0), compositor.surfaces.items.len);
    try testing.expectNull(compositor.coordinator);
}

test "Compositor - create and destroy surface" {
    const allocator = testing.allocator;

    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    var compositor = try Compositor.init(allocator, &server);
    defer compositor.deinit();

    const surface = try compositor.createSurface();
    try testing.expectEqual(@as(usize, 1), compositor.surfaces.items.len);
    try testing.expectEqual(@as(u32, 1), surface.id);

    compositor.destroySurface(surface);
    try testing.expectEqual(@as(usize, 0), compositor.surfaces.items.len);
}

test "Compositor - multiple surfaces" {
    const allocator = testing.allocator;

    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    var compositor = try Compositor.init(allocator, &server);
    defer compositor.deinit();

    const s1 = try compositor.createSurface();
    const s2 = try compositor.createSurface();
    const s3 = try compositor.createSurface();

    try testing.expectEqual(@as(usize, 3), compositor.surfaces.items.len);
    try testing.expectEqual(@as(u32, 1), s1.id);
    try testing.expectEqual(@as(u32, 2), s2.id);
    try testing.expectEqual(@as(u32, 3), s3.id);
}
