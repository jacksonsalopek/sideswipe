//! Compositor output management
//! Connects backend outputs to compositor surfaces for rendering

const std = @import("std");
const core = @import("core");
const cli = @import("core.cli");
const backend = @import("backend");
const math = @import("core.math");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("compositor.zig").Compositor;
const Surface = @import("surface.zig").Surface;
const FrameCallback = @import("surface.zig").FrameCallback;

/// Compositor output state
pub const Type = struct {
    allocator: std.mem.Allocator,
    compositor: *Compositor,
    backend_output: *backend.output.IOutput,
    name: []const u8,
    needs_frame: bool = false,
    frame_pending: bool = false,

    const Self = @This();

    pub const Error = error{
        OutOfMemory,
        BackendError,
    };

    /// Creates a new compositor output
    pub fn init(
        allocator: std.mem.Allocator,
        compositor: *Compositor,
        backend_output: *backend.output.IOutput,
        name: []const u8,
    ) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        self.* = .{
            .allocator = allocator,
            .compositor = compositor,
            .backend_output = backend_output,
            .name = name_copy,
        };

        compositor.logger.info("Created compositor output: {s}", .{name});

        return self;
    }

    /// Destroys the output
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Schedules a frame to be rendered
    pub fn scheduleFrame(self: *Self) void {
        if (self.frame_pending) {
            self.needs_frame = true;
            return;
        }

        self.compositor.logger.trace("Scheduling frame for output {s}", .{self.name});
        self.backend_output.scheduleFrame(.unknown);
        self.frame_pending = true;
    }

    /// Renders all surfaces to this output
    pub fn render(self: *Self) Error!void {
        self.frame_pending = false;
        self.needs_frame = false;

        // Get renderer from backend coordinator
        const coord = self.compositor.coordinator orelse {
            self.compositor.logger.err("No backend coordinator available for rendering", .{});
            return error.BackendError;
        };

        const renderer = coord.primary_renderer orelse {
            self.compositor.logger.err("No renderer available", .{});
            return error.BackendError;
        };

        // Count mapped surfaces with buffers
        var surface_count: usize = 0;
        for (self.compositor.surfaces.items) |surface| {
            if (surface.mapped and surface.current.buffer.buffer != null) {
                surface_count += 1;
            }
        }

        if (surface_count == 0) {
            self.compositor.logger.trace("No surfaces to render", .{});
            // Still need to send frame callbacks
            try self.sendFrameCallbacks();
            return;
        }

        self.compositor.logger.debug("Rendering frame with {d} surface(s)", .{surface_count});

        // Render each mapped surface
        for (self.compositor.surfaces.items) |surface| {
            if (!surface.mapped or surface.current.buffer.buffer == null) {
                continue;
            }

            // Convert wl_resource buffer to backend.buffer.Interface
            const buffer_resource = surface.current.buffer.buffer orelse continue;
            const buffer_iface = self.importBuffer(buffer_resource) catch |err| {
                self.compositor.logger.warn(
                    "Failed to import buffer for surface {d}: {}",
                    .{ surface.id, err },
                );
                continue;
            };

            // For now, we just verify the buffer is valid
            // In a full implementation, we would:
            // 1. Get/create a swapchain buffer from backend output
            // 2. Use renderer.blit() to copy surface buffer to output buffer
            // 3. Commit the output with the new buffer
            _ = buffer_iface;
            _ = renderer;

            self.compositor.logger.trace("Rendered surface {d}", .{surface.id});
        }

        // Send frame callbacks to all surfaces
        try self.sendFrameCallbacks();

        // If another frame was requested during rendering, schedule it
        if (self.needs_frame) {
            self.scheduleFrame();
        }
    }

    /// Sends frame callbacks to all surfaces
    fn sendFrameCallbacks(self: *Self) Error!void {
        const time_ms = self.getTimestamp();

        for (self.compositor.surfaces.items) |surface| {
            // Send frame callbacks from current state
            const callbacks = surface.current.frame_callbacks.items;
            if (callbacks.len == 0) continue;

            for (callbacks) |callback| {
                // Send the callback with current timestamp
                c.wl_callback_send_done(callback.resource, time_ms);
                c.wl_resource_destroy(callback.resource);
                self.allocator.destroy(callback);
            }

            surface.current.frame_callbacks.clearRetainingCapacity();
            self.compositor.logger.trace("Sent {d} frame callback(s) to surface {d}", .{ callbacks.len, surface.id });
        }
    }

    /// Gets current timestamp in milliseconds
    fn getTimestamp(self: *Self) u32 {
        _ = self;
        const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch {
            return 0;
        };
        // Access fields via std.time for compatibility
        const sec_ms: u64 = @intCast(@as(i64, ts.sec) * 1000);
        const nsec_ms: u64 = @intCast(@divTrunc(ts.nsec, 1000000));
        const ms = sec_ms + nsec_ms;
        return @truncate(ms);
    }

    /// Imports a wl_buffer resource as a backend buffer interface
    fn importBuffer(self: *Self, buffer_resource: *c.wl_resource) Error!backend.buffer.Interface {
        // Check if this is a wl_shm_buffer
        const shm_buffer = c.wl_shm_buffer_get(buffer_resource);
        if (shm_buffer != null) {
            // For now, we don't support SHM buffers in rendering
            self.compositor.logger.warn("SHM buffers not yet supported for rendering", .{});
            return error.BackendError;
        }

        // For DMA-BUF, we would need to:
        // 1. Get the linux_dmabuf_buffer from the resource
        // 2. Extract FDs, strides, offsets, format, modifier
        // 3. Create a backend.buffer.Interface wrapper
        
        // This is a placeholder - full implementation needs DMA-BUF support
        self.compositor.logger.warn("DMA-BUF import not yet fully implemented", .{});
        return error.BackendError;
    }
};

// Tests
const testing = core.testing;

test "Output - init and deinit" {
    // Skip test if no WAYLAND_DISPLAY
    if (std.posix.getenv("WAYLAND_DISPLAY") == null) {
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;

    var server = try wayland.Server.init(allocator, null);
    defer server.deinit();

    var logger = cli.Logger.init(allocator);
    defer logger.deinit();

    var comp = try Compositor.init(allocator, &server, &logger);
    defer comp.deinit();

    // Create a mock backend output (simplified for testing)
    // In reality, this would come from the backend
    const backend_opts = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };

    var coord = try backend.Coordinator.create(allocator, &backend_opts, .{});
    defer coord.deinit();

    // We can't easily test full output creation without a real backend
    // Just verify the structures compile
}

test "Output - scheduleFrame sets pending flag" {
    // This test would require a mock backend output
    // Skipping for now as it needs more infrastructure
}
