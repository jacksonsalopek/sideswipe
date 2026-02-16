//! Main compositor state and management
//! Coordinates surfaces, backends, and protocol implementations

const std = @import("std");
const wayland = @import("wayland");
const backend = @import("backend");
const core = @import("core");
const cli = @import("core.cli");

const Surface = @import("surface.zig").Surface;
const Output = @import("output.zig").Type;

/// Main compositor state
pub const Compositor = struct {
    allocator: std.mem.Allocator,
    server: *wayland.Server,
    coordinator: ?*backend.Coordinator,
    surfaces: std.ArrayList(*Surface),
    outputs: std.ArrayList(*Output),
    next_surface_id: u32,
    logger: *cli.Logger,

    const Self = @This();

    pub const Error = error{
        InitFailed,
        OutOfMemory,
        BackendError,
    };

    /// Creates a new compositor instance
    pub fn init(allocator: std.mem.Allocator, server: *wayland.Server, logger: *cli.Logger) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .server = server,
            .coordinator = null,
            .surfaces = std.ArrayList(*Surface){},
            .outputs = std.ArrayList(*Output){},
            .next_surface_id = 1,
            .logger = logger,
        };

        return self;
    }

    /// Destroys the compositor and frees all resources
    pub fn deinit(self: *Self) void {
        // Clean up all outputs
        for (self.outputs.items) |output| {
            output.deinit();
        }
        self.outputs.deinit(self.allocator);

        // Clean up all surfaces
        for (self.surfaces.items) |surface| {
            surface.deinit();
        }
        self.surfaces.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Attaches a backend coordinator to the compositor
    pub fn attachBackend(self: *Self, coord: *backend.Coordinator) Error!void {
        self.coordinator = coord;
        
        // Create compositor outputs from backend implementations
        for (coord.implementations.items) |impl| {
            if (impl.backendType() == .wayland) {
                try self.connectWaylandBackendOutputs(impl);
            }
        }
    }

    fn connectWaylandBackendOutputs(self: *Self, impl: backend.Implementation) Error!void {
        self.logger.debug("Discovering outputs from Wayland backend", .{});

        const backend_ptr = impl.base.ptr orelse return;

        // Cast to Wayland Backend
        const wayland_backend = @import("backend").wayland.Backend;
        const wl_backend: *wayland_backend = @ptrCast(@alignCast(backend_ptr));
        
        // For each output in the backend, create a compositor output
        for (wl_backend.outputs.items) |wl_output| {
            var backend_output = wl_output.iface();
            const comp_output = try self.createOutput(&backend_output, wl_output.name);
            
            // Register frame callback
            wl_output.setFrameCallback(outputFrameCallback, comp_output);
            
            self.logger.info("Connected compositor output to backend output: {s}", .{wl_output.name});
        }
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

    /// Creates a compositor output from a backend output
    pub fn createOutput(self: *Self, backend_output: *backend.output.IOutput, name: []const u8) Error!*Output {
        const output = try Output.init(self.allocator, self, backend_output, name);
        errdefer output.deinit();

        try self.outputs.append(self.allocator, output);
        return output;
    }

    /// Schedules a frame on all outputs
    pub fn scheduleFrame(self: *Self) void {
        for (self.outputs.items) |output| {
            output.scheduleFrame();
        }
    }
};

/// Frame callback from backend output
fn outputFrameCallback(userdata: ?*anyopaque) void {
    const output: *Output = @ptrCast(@alignCast(userdata orelse return));
    
    // Trigger rendering on this output
    output.render() catch |err| {
        output.compositor.logger.err("Failed to render frame: {}", .{err});
    };
}

// Tests
const testing = core.testing;

test "Compositor - init and deinit" {
    const allocator = testing.allocator;

    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
    defer compositor.deinit();

    try testing.expectEqual(@as(u32, 1), compositor.next_surface_id);
    try testing.expectEqual(@as(usize, 0), compositor.surfaces.items.len);
    try testing.expectNull(compositor.coordinator);
}

test "Compositor - create and destroy surface" {
    const allocator = testing.allocator;

    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
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

    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var compositor = try Compositor.init(allocator, &server, &logger);
    defer compositor.deinit();

    const s1 = try compositor.createSurface();
    const s2 = try compositor.createSurface();
    const s3 = try compositor.createSurface();

    try testing.expectEqual(@as(usize, 3), compositor.surfaces.items.len);
    try testing.expectEqual(@as(u32, 1), s1.id);
    try testing.expectEqual(@as(u32, 2), s2.id);
    try testing.expectEqual(@as(u32, 3), s3.id);
}
