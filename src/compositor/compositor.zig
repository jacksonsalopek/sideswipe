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
        CreateFailed,
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
        const backend_ptr = impl.base.ptr;

        // Cast to Wayland Backend
        const wayland_backend = @import("backend").wayland.Backend;
        const wl_backend: *wayland_backend = @ptrCast(@alignCast(backend_ptr));

        // Register backend with server event loop for automatic dispatch
        const wayland_mod = @import("wayland");
        var display = wayland_mod.Display{ .handle = self.server.getDisplay() };
        const event_loop_handle = try display.getEventLoop();
        
        self.logger.debug("About to register backend with event loop (backend_display={})", .{wl_backend.wayland_state.display != null});
        wl_backend.registerWithEventLoop(@ptrCast(event_loop_handle));
        self.logger.debug("Finished registering backend with event loop", .{});

        if (wl_backend.outputs.items.len == 0) {
            self.logger.warn("No backend outputs available to connect", .{});
            return;
        }

        // For each output in the backend, create a compositor output
        for (wl_backend.outputs.items) |wl_output| {
            // Get the IOutput interface by value (not a pointer to stack!)
            const backend_output = wl_output.iface();
            const comp_output = try self.createOutput(backend_output, wl_output.name);

            // Register frame callback
            wl_output.setFrameCallback(outputFrameCallback, comp_output);

            self.logger.info("Connected compositor output to backend output: {s}", .{wl_output.name});
        }
    }

    /// Creates a new surface and registers it with the compositor
    pub fn createSurface(self: *Self) Error!*Surface {
        const id = self.next_surface_id;
        self.next_surface_id += 1;

        self.logger.debug("Compositor: Creating surface {d}", .{id});
        const surface = try Surface.init(self.allocator, self, id);
        errdefer surface.deinit();

        try self.surfaces.append(self.allocator, surface);
        self.logger.debug("Compositor: Surface {d} registered (total surfaces: {d})", .{ id, self.surfaces.items.len });
        return surface;
    }

    /// Removes and destroys a surface. Logs the reason for debugging.
    pub fn destroySurface(self: *Self, surface: *Surface, reason: []const u8) void {
        self.logger.debug("Destroyed surface {d}: {s}", .{ surface.id, reason });

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
    pub fn createOutput(self: *Self, backend_output: backend.output.IOutput, name: []const u8) Error!*Output {
        const output = try Output.init(self.allocator, self, backend_output, name);
        errdefer output.deinit();

        try self.outputs.append(self.allocator, output);
        return output;
    }

    /// Schedules a frame on all outputs
    pub fn scheduleFrame(self: *Self) void {
        self.logger.debug("Compositor: Scheduling frame on {d} output(s)", .{self.outputs.items.len});
        for (self.outputs.items) |output| {
            output.scheduleFrame();
        }
    }
};

/// Frame callback from backend output
fn outputFrameCallback(userdata: ?*anyopaque) void {
    const output: *Output = @ptrCast(@alignCast(userdata orelse return));

    output.compositor.logger.debug("Compositor: Frame callback triggered for output {s}", .{output.name});

    // Trigger rendering on this output
    output.render() catch |err| {
        output.compositor.logger.err("Compositor: Failed to render frame on output {s}: {}", .{ output.name, err });
    };
}

// Tests
const testing = core.testing;

/// Test fixture for setting up compositor test environment
const TestFixture = struct {
    allocator: std.mem.Allocator,
    runtime: wayland.test_setup.RuntimeDir,
    server: wayland.Server,
    logger: cli.Logger,
    compositor: *Compositor,

    fn setup(allocator: std.mem.Allocator) !TestFixture {
        var runtime = try wayland.test_setup.RuntimeDir.setup(allocator);
        errdefer runtime.cleanup();

        var server = try wayland.Server.init(allocator, null);
        errdefer server.deinit();

        var fixture = TestFixture{
            .allocator = allocator,
            .runtime = runtime,
            .server = server,
            .logger = cli.Logger.init(allocator),
            .compositor = undefined,
        };

        fixture.logger.setLogLevel(.err); // Disable debug/info/warn logging in tests
        fixture.logger.setEnableStdout(false);
        errdefer fixture.logger.deinit();

        fixture.compositor = try Compositor.init(allocator, &fixture.server, &fixture.logger);
        errdefer fixture.compositor.deinit();

        return fixture;
    }

    fn cleanup(self: *TestFixture) void {
        self.compositor.deinit();
        self.logger.deinit();
        self.server.deinit();
        self.runtime.cleanup();
    }
};

test "Compositor - init and deinit" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    try testing.expectEqual(@as(u32, 1), fixture.compositor.next_surface_id);
    try testing.expectEqual(@as(usize, 0), fixture.compositor.surfaces.items.len);
    try testing.expectNull(fixture.compositor.coordinator);
}

test "Compositor - create and destroy surface" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    const surface = try fixture.compositor.createSurface();
    try testing.expectEqual(@as(usize, 1), fixture.compositor.surfaces.items.len);
    try testing.expectEqual(@as(u32, 1), surface.id);

    fixture.compositor.destroySurface(surface, "test teardown");
    try testing.expectEqual(@as(usize, 0), fixture.compositor.surfaces.items.len);
}

test "Compositor - multiple surfaces" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    const s1 = try fixture.compositor.createSurface();
    const s2 = try fixture.compositor.createSurface();
    const s3 = try fixture.compositor.createSurface();

    try testing.expectEqual(@as(usize, 3), fixture.compositor.surfaces.items.len);
    try testing.expectEqual(@as(u32, 1), s1.id);
    try testing.expectEqual(@as(u32, 2), s2.id);
    try testing.expectEqual(@as(u32, 3), s3.id);
}
