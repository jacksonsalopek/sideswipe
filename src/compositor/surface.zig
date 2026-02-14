//! Surface state management
//! Handles wl_surface state with double-buffered pending/committed states

const std = @import("std");
const core = @import("core");
const math = @import("core.math");
const c = @import("wayland").c;

const Compositor = @import("compositor.zig").Compositor;

/// Surface buffer state
pub const BufferState = struct {
    /// Currently attached buffer resource
    buffer: ?*c.wl_resource = null,
    /// Buffer offset on X axis
    dx: i32 = 0,
    /// Buffer offset on Y axis
    dy: i32 = 0,
    /// Buffer scale factor
    scale: i32 = 1,
    /// Buffer transform (rotation/flip)
    transform: u32 = 0,

    pub fn reset(self: *BufferState) void {
        self.buffer = null;
        self.dx = 0;
        self.dy = 0;
    }
};

/// Surface damage tracking
pub const DamageState = struct {
    /// Damaged regions in surface coordinates
    surface_damage: std.ArrayList(math.Box),
    /// Damaged regions in buffer coordinates
    buffer_damage: std.ArrayList(math.Box),

    pub fn init() DamageState {
        return .{
            .surface_damage = std.ArrayList(math.Box){},
            .buffer_damage = std.ArrayList(math.Box){},
        };
    }

    pub fn deinit(self: *DamageState, allocator: std.mem.Allocator) void {
        self.surface_damage.deinit(allocator);
        self.buffer_damage.deinit(allocator);
    }

    pub fn reset(self: *DamageState) void {
        self.surface_damage.clearRetainingCapacity();
        self.buffer_damage.clearRetainingCapacity();
    }

    pub fn addSurfaceDamage(self: *DamageState, allocator: std.mem.Allocator, box: math.Box) !void {
        try self.surface_damage.append(allocator, box);
    }

    pub fn addBufferDamage(self: *DamageState, allocator: std.mem.Allocator, box: math.Box) !void {
        try self.buffer_damage.append(allocator, box);
    }
};

/// Frame callback data
pub const FrameCallback = struct {
    resource: *c.wl_resource,
    next: ?*FrameCallback = null,
};

/// Surface role type
pub const Role = enum {
    none,
    xdg_toplevel,
    xdg_popup,
    subsurface,
    cursor,
};

/// Main surface structure
pub const Surface = struct {
    allocator: std.mem.Allocator,
    compositor: *Compositor,
    id: u32,
    resource: ?*c.wl_resource = null,

    /// Surface role (can only be set once)
    role: Role = .none,
    role_data: ?*anyopaque = null,

    /// Pending state (accumulates until commit)
    pending: struct {
        buffer: BufferState = .{},
        damage: DamageState,
        opaque_region: std.ArrayList(math.Box),
        input_region: std.ArrayList(math.Box),
        frame_callbacks: std.ArrayList(*FrameCallback),
    },

    /// Committed state (applied on commit)
    current: struct {
        buffer: BufferState = .{},
        damage: DamageState,
        width: i32 = 0,
        height: i32 = 0,
        frame_callbacks: std.ArrayList(*FrameCallback),
    },

    /// Parent surface for subsurfaces
    parent: ?*Surface = null,
    /// Child subsurfaces
    children: std.ArrayList(*Surface),

    /// Whether the surface has been mapped
    mapped: bool = false,

    const Self = @This();

    pub const Error = error{
        OutOfMemory,
    };

    /// Creates a new surface
    pub fn init(allocator: std.mem.Allocator, compositor: *Compositor, id: u32) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .compositor = compositor,
            .id = id,
            .pending = .{
                .damage = DamageState.init(),
                .opaque_region = std.ArrayList(math.Box){},
                .input_region = std.ArrayList(math.Box){},
                .frame_callbacks = std.ArrayList(*FrameCallback){},
            },
            .current = .{
                .damage = DamageState.init(),
                .frame_callbacks = std.ArrayList(*FrameCallback){},
            },
            .children = std.ArrayList(*Surface){},
        };

        return self;
    }

    /// Destroys the surface
    pub fn deinit(self: *Self) void {
        // Clean up pending frame callbacks
        for (self.pending.frame_callbacks.items) |callback| {
            self.allocator.destroy(callback);
        }
        self.pending.damage.deinit(self.allocator);
        self.pending.opaque_region.deinit(self.allocator);
        self.pending.input_region.deinit(self.allocator);
        self.pending.frame_callbacks.deinit(self.allocator);

        // Clean up current frame callbacks
        for (self.current.frame_callbacks.items) |callback| {
            self.allocator.destroy(callback);
        }
        self.current.damage.deinit(self.allocator);
        self.current.frame_callbacks.deinit(self.allocator);

        self.children.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Sets the surface resource
    pub fn setResource(self: *Self, resource: *c.wl_resource) void {
        self.resource = resource;
    }

    /// Attaches a buffer to the pending state
    pub fn attach(self: *Self, buffer: ?*c.wl_resource, dx: i32, dy: i32) void {
        self.pending.buffer.buffer = buffer;
        self.pending.buffer.dx = dx;
        self.pending.buffer.dy = dy;
    }

    /// Adds damage to the pending state (surface coordinates)
    pub fn damage(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
        const box = math.Box{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        try self.pending.damage.addSurfaceDamage(self.allocator, box);
    }

    /// Adds damage to the pending state (buffer coordinates)
    pub fn damageBuffer(self: *Self, x: i32, y: i32, width: i32, height: i32) Error!void {
        const box = math.Box{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
        try self.pending.damage.addBufferDamage(self.allocator, box);
    }

    /// Adds a frame callback to the pending state
    pub fn frame(self: *Self, callback: *FrameCallback) Error!void {
        try self.pending.frame_callbacks.append(self.allocator, callback);
    }

    /// Sets the surface scale
    pub fn setScale(self: *Self, scale: i32) void {
        self.pending.buffer.scale = scale;
    }

    /// Sets the surface transform
    pub fn setTransform(self: *Self, transform: u32) void {
        self.pending.buffer.transform = transform;
    }

    /// Commits the pending state to current state
    pub fn commit(self: *Self) void {
        // Apply buffer state
        self.current.buffer = self.pending.buffer;
        self.pending.buffer.reset();

        // Apply damage
        self.current.damage.deinit(self.allocator);
        self.current.damage = self.pending.damage;
        self.pending.damage = DamageState.init();

        // Clear pending regions
        self.pending.opaque_region.clearRetainingCapacity();
        self.pending.input_region.clearRetainingCapacity();

        // Move frame callbacks from pending to current
        // They will be sent when the frame is actually rendered
        for (self.current.frame_callbacks.items) |callback| {
            self.allocator.destroy(callback);
        }
        self.current.frame_callbacks.clearRetainingCapacity();
        for (self.pending.frame_callbacks.items) |callback| {
            self.current.frame_callbacks.append(self.allocator, callback) catch {
                // If append fails, destroy the callback to avoid leak
                self.allocator.destroy(callback);
            };
        }
        self.pending.frame_callbacks.clearRetainingCapacity();

        // Update mapped state based on buffer attachment
        if (self.current.buffer.buffer != null and !self.mapped) {
            self.mapped = true;
        } else if (self.current.buffer.buffer == null and self.mapped) {
            self.mapped = false;
        }

        // Schedule frame on compositor if we have a buffer and callbacks
        if (self.current.buffer.buffer != null and self.current.frame_callbacks.items.len > 0) {
            self.compositor.scheduleFrame();
        }

        // Commit subsurfaces if in synchronized mode
        for (self.children.items) |child| {
            // In a real implementation, check if child is synchronized
            child.commit();
        }
    }

    /// Sets the surface role
    /// Returns error if role is already set to a different value
    pub fn setRole(self: *Self, role: Role, data: ?*anyopaque) Error!void {
        if (self.role != .none and self.role != role) {
            return error.OutOfMemory; // Use OutOfMemory as placeholder for protocol error
        }
        self.role = role;
        self.role_data = data;
    }

    /// Checks if surface has a specific role
    pub fn hasRole(self: *Self, role: Role) bool {
        return self.role == role;
    }

    /// Adds a child subsurface
    pub fn addChild(self: *Self, child: *Surface) Error!void {
        try self.children.append(self.allocator, child);
        child.parent = self;
    }

    /// Removes a child subsurface
    pub fn removeChild(self: *Self, child: *Surface) void {
        for (self.children.items, 0..) |surface_child, i| {
            if (surface_child == child) {
                _ = self.children.swapRemove(i);
                child.parent = null;
                return;
            }
        }
    }
};

// Tests
const testing = core.testing;

test "Surface - init and deinit" {
    const allocator = testing.allocator;

    var server = @import("wayland").Server.init(allocator, null) catch return;
    defer server.deinit();

    const cli = @import("core.cli");
    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
    defer compositor.deinit();

    var surface = try Surface.init(allocator, compositor, 1);
    defer surface.deinit();

    try testing.expectEqual(@as(u32, 1), surface.id);
    try testing.expectEqual(Role.none, surface.role);
    try testing.expectFalse(surface.mapped);
}

test "Surface - attach and commit" {
    const allocator = testing.allocator;

    var server = @import("wayland").Server.init(allocator, null) catch return;
    defer server.deinit();

    const cli = @import("core.cli");
    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
    defer compositor.deinit();

    var surface = try Surface.init(allocator, compositor, 1);
    defer surface.deinit();

    // Create a dummy buffer resource (in real usage this would be a wl_resource from client)
    var dummy_resource: u32 = 0xDEADBEEF;
    const dummy_buffer: *c.wl_resource = @ptrCast(@alignCast(&dummy_resource));

    surface.attach(dummy_buffer, 0, 0);
    try testing.expectEqual(dummy_buffer, surface.pending.buffer.buffer);

    surface.commit();
    try testing.expectEqual(dummy_buffer, surface.current.buffer.buffer);
    try testing.expectEqual(@as(?*c.wl_resource, null), surface.pending.buffer.buffer);
    try testing.expect(surface.mapped);
}

test "Surface - damage tracking" {
    const allocator = testing.allocator;

    var server = @import("wayland").Server.init(allocator, null) catch return;
    defer server.deinit();

    const cli = @import("core.cli");
    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
    defer compositor.deinit();

    var surface = try Surface.init(allocator, compositor, 1);
    defer surface.deinit();

    try surface.damage(10, 20, 100, 200);
    try testing.expectEqual(@as(usize, 1), surface.pending.damage.surface_damage.items.len);

    const box = surface.pending.damage.surface_damage.items[0];
    try testing.expectEqual(@as(i32, 10), box.x);
    try testing.expectEqual(@as(i32, 20), box.y);
    try testing.expectEqual(@as(i32, 100), box.width);
    try testing.expectEqual(@as(i32, 200), box.height);
}

test "Surface - role management" {
    const allocator = testing.allocator;

    var server = @import("wayland").Server.init(allocator, null) catch return;
    defer server.deinit();

    const cli = @import("core.cli");
    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
    defer compositor.deinit();

    var surface = try Surface.init(allocator, compositor, 1);
    defer surface.deinit();

    try surface.setRole(.xdg_toplevel, null);
    try testing.expectEqual(Role.xdg_toplevel, surface.role);
    try testing.expect(surface.hasRole(.xdg_toplevel));

    // Setting same role should succeed
    try surface.setRole(.xdg_toplevel, null);

    // Setting different role should fail
    const result = surface.setRole(.xdg_popup, null);
    try testing.expectError(error.OutOfMemory, result);
}

test "Surface - parent/child relationships" {
    const allocator = testing.allocator;

    var server = @import("wayland").Server.init(allocator, null) catch return;
    defer server.deinit();

    const cli = @import("core.cli");
    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
    defer compositor.deinit();

    var parent = try Surface.init(allocator, compositor, 1);
    defer parent.deinit();

    var child = try Surface.init(allocator, compositor, 2);
    defer child.deinit();

    try parent.addChild(child);
    try testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try testing.expectEqual(parent, child.parent);

    parent.removeChild(child);
    try testing.expectEqual(@as(usize, 0), parent.children.items.len);
    try testing.expectNull(child.parent);
}
