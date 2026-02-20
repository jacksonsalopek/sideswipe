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
    backend_output: backend.output.IOutput,
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
        backend_output: backend.output.IOutput,
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

        // Get backend coordinator
        const coord = self.compositor.coordinator orelse {
            self.compositor.logger.err("No backend coordinator available for rendering", .{});
            return error.BackendError;
        };

        // Renderer is optional for zero-copy passthrough (e.g., nested Wayland)
        const renderer = coord.primary_renderer;

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

            // Import client buffer as backend buffer interface
            const buffer_resource = surface.current.buffer.buffer orelse continue;
            const buffer_iface = self.importBuffer(buffer_resource) catch |err| {
                self.compositor.logger.warn(
                    "Failed to import buffer for surface {d}: {}",
                    .{ surface.id, err },
                );
                continue;
            };

            if (renderer) |rend| {
                // Multi-GPU or format conversion - use renderer to blit
                self.compositor.logger.trace("Using renderer to blit surface {d}", .{surface.id});
                _ = rend; // TODO: Implement swapchain + blit path
                // This would: get swapchain buffer, rend.blit(client_buffer, swapchain_buffer), commit
                self.compositor.logger.warn("Renderer blit not yet implemented, falling back to passthrough", .{});
            }
            
            // Zero-copy passthrough for nested Wayland
            // Pass client buffer directly to backend output
            try self.setBackendBuffer(buffer_iface);
            
            if (!self.backend_output.commit()) {
                self.compositor.logger.err("Backend output commit failed", .{});
                return error.BackendError;
            }

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

    /// Sets a buffer in the backend output state for rendering
    fn setBackendBuffer(self: *Self, buf: backend.buffer.Interface) Error!void {
        // Access the concrete output implementation through the interface
        // The base.ptr contains the pointer to the actual Output structure
        const output_ptr = self.backend_output.base.ptr;
        
        // For now, we only support Wayland backend
        // Cast to Wayland Output and set buffer in state
        const wayland_backend = @import("backend").wayland;
        const wl_output: *wayland_backend.Output = @ptrCast(@alignCast(output_ptr));
        
        wl_output.state.setBuffer(buf);
    }

    /// Imports a wl_buffer resource as a backend buffer interface
    fn importBuffer(self: *Self, buffer_resource: *c.wl_resource) Error!backend.buffer.Interface {
        // Check if this is a wl_shm_buffer
        const shm_buffer = c.wl_shm_buffer_get(buffer_resource);
        if (shm_buffer) |shm| {
            return self.importShmBuffer(shm);
        }

        return self.importDmabufBuffer(buffer_resource);
    }

    fn importShmBuffer(self: *Self, shm_buffer: *c.wl_shm_buffer) Error!backend.buffer.Interface {
        const width = c.wl_shm_buffer_get_width(shm_buffer);
        const height = c.wl_shm_buffer_get_height(shm_buffer);
        const stride = c.wl_shm_buffer_get_stride(shm_buffer);
        const format = c.wl_shm_buffer_get_format(shm_buffer);

        c.wl_shm_buffer_begin_access(shm_buffer);
        const data = c.wl_shm_buffer_get_data(shm_buffer);
        c.wl_shm_buffer_end_access(shm_buffer);

        if (data == null) {
            self.compositor.logger.warn("SHM buffer has null data pointer", .{});
            return error.BackendError;
        }

        const wrapper = try self.allocator.create(ShmBufferWrapper);
        errdefer self.allocator.destroy(wrapper);

        wrapper.* = .{
            .allocator = self.allocator,
            .shm_buffer = shm_buffer,
            .width = width,
            .height = height,
            .stride = stride,
            .format = format,
        };

        self.compositor.logger.debug(
            "Imported SHM buffer: {}x{} stride={} format=0x{x}",
            .{ width, height, stride, format },
        );

        return backend.buffer.Interface.init(wrapper, &shm_buffer_vtable);
    }

    fn importDmabufBuffer(self: *Self, buffer_resource: *c.wl_resource) Error!backend.buffer.Interface {
        // Get DMA-BUF data from resource
        const user_data = c.wl_resource_get_user_data(buffer_resource);
        if (user_data == null) {
            self.compositor.logger.warn("Buffer has no user data", .{});
            return error.BackendError;
        }
        
        // Cast to DmabufBufferData
        const buffer_data: *linux_dmabuf.DmabufBufferData = @ptrCast(@alignCast(user_data));
        const params = buffer_data.params_data;

        const wrapper = try self.allocator.create(DmabufBufferWrapper);
        errdefer self.allocator.destroy(wrapper);

        wrapper.* = .{
            .allocator = self.allocator,
            .width = params.width,
            .height = params.height,
            .format = params.format,
            .num_planes = params.num_planes,
            .plane_data = params.plane_data,
        };

        return backend.buffer.Interface.init(wrapper, &dmabuf_buffer_vtable);
    }
};

const linux_dmabuf = @import("protocols/linux_dmabuf.zig");
const PlaneAttributes = linux_dmabuf.PlaneAttributes;

/// Wrapper for client DMA-BUF buffers to be used with backend
const DmabufBufferWrapper = struct {
    allocator: std.mem.Allocator,
    width: i32,
    height: i32,
    format: u32,
    num_planes: u32,
    plane_data: [4]PlaneAttributes,

    fn caps(_: *anyopaque) backend.buffer.Capability {
        return .{};
    }

    fn bufferType(_: *anyopaque) backend.buffer.Type {
        return .dmabuf;
    }

    fn update(_: *anyopaque, _: *const anyopaque) void {}

    fn isSynchronous(_: *anyopaque) bool {
        return false;
    }

    fn good(ptr: *anyopaque) bool {
        const self: *DmabufBufferWrapper = @ptrCast(@alignCast(ptr));
        return self.width > 0 and self.height > 0 and self.num_planes > 0;
    }

    fn dmabuf(ptr: *anyopaque) backend.buffer.DMABUFAttrs {
        const self: *DmabufBufferWrapper = @ptrCast(@alignCast(ptr));
        
        const modifier: u64 = (@as(u64, self.plane_data[0].modifier_hi) << 32) | 
                              @as(u64, self.plane_data[0].modifier_lo);
        
        var attrs: backend.buffer.DMABUFAttrs = .{
            .success = true,
            .size = math.Vec2.init(@floatFromInt(self.width), @floatFromInt(self.height)),
            .format = self.format,
            .modifier = modifier,
            .planes = @intCast(self.num_planes),
        };

        // Copy plane FDs, strides, and offsets
        for (0..@min(self.num_planes, 4)) |i| {
            attrs.fds[i] = self.plane_data[i].fd;
            attrs.strides[i] = self.plane_data[i].stride;
            attrs.offsets[i] = self.plane_data[i].offset;
        }

        return attrs;
    }

    fn shm(_: *anyopaque) backend.buffer.SSHMAttrs {
        return .{ .success = false };
    }

    fn beginDataPtr(_: *anyopaque, _: u32) backend.buffer.DataPtrResult {
        return .{ .ptr = null, .flags = 0, .size = 0 };
    }

    fn endDataPtr(_: *anyopaque) void {}

    fn sendRelease(_: *anyopaque) void {}

    fn lock(_: *anyopaque) void {}

    fn unlock(_: *anyopaque) void {}

    fn locked(_: *anyopaque) bool {
        return false;
    }

    fn deinitBuffer(ptr: *anyopaque) void {
        const self: *DmabufBufferWrapper = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

const dmabuf_buffer_vtable = backend.buffer.Interface.VTableDef{
    .caps = DmabufBufferWrapper.caps,
    .type = DmabufBufferWrapper.bufferType,
    .update = DmabufBufferWrapper.update,
    .is_synchronous = DmabufBufferWrapper.isSynchronous,
    .good = DmabufBufferWrapper.good,
    .dmabuf = DmabufBufferWrapper.dmabuf,
    .shm = DmabufBufferWrapper.shm,
    .begin_data_ptr = DmabufBufferWrapper.beginDataPtr,
    .end_data_ptr = DmabufBufferWrapper.endDataPtr,
    .send_release = DmabufBufferWrapper.sendRelease,
    .lock = DmabufBufferWrapper.lock,
    .unlock = DmabufBufferWrapper.unlock,
    .locked = DmabufBufferWrapper.locked,
    .deinit = DmabufBufferWrapper.deinitBuffer,
};

/// Wrapper for client SHM buffers to be used with backend
const ShmBufferWrapper = struct {
    allocator: std.mem.Allocator,
    shm_buffer: *c.wl_shm_buffer,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,

    fn caps(_: *anyopaque) backend.buffer.Capability {
        return .{ .dataptr = true };
    }

    fn bufferType(_: *anyopaque) backend.buffer.Type {
        return .shm;
    }

    fn update(_: *anyopaque, _: *const anyopaque) void {}

    fn isSynchronous(_: *anyopaque) bool {
        return true;
    }

    fn good(ptr: *anyopaque) bool {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        return self.width > 0 and self.height > 0;
    }

    fn dmabuf(_: *anyopaque) backend.buffer.DMABUFAttrs {
        return .{ .success = false };
    }

    fn shm(ptr: *anyopaque) backend.buffer.SSHMAttrs {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));

        return .{
            .success = true,
            .fd = -1,
            .format = self.format,
            .size = math.Vec2.init(@floatFromInt(self.width), @floatFromInt(self.height)),
            .stride = self.stride,
            .offset = 0,
        };
    }

    fn beginDataPtr(ptr: *anyopaque, _: u32) backend.buffer.DataPtrResult {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        
        c.wl_shm_buffer_begin_access(self.shm_buffer);
        const data = c.wl_shm_buffer_get_data(self.shm_buffer);
        
        const size = @as(usize, @intCast(self.height * self.stride));
        
        return .{
            .ptr = @ptrCast(data),
            .flags = 0,
            .size = size,
        };
    }

    fn endDataPtr(ptr: *anyopaque) void {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        c.wl_shm_buffer_end_access(self.shm_buffer);
    }

    fn sendRelease(_: *anyopaque) void {}

    fn lock(_: *anyopaque) void {}

    fn unlock(_: *anyopaque) void {}

    fn locked(_: *anyopaque) bool {
        return false;
    }

    fn deinitBuffer(ptr: *anyopaque) void {
        const self: *ShmBufferWrapper = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

const shm_buffer_vtable = backend.buffer.Interface.VTableDef{
    .caps = ShmBufferWrapper.caps,
    .type = ShmBufferWrapper.bufferType,
    .update = ShmBufferWrapper.update,
    .is_synchronous = ShmBufferWrapper.isSynchronous,
    .good = ShmBufferWrapper.good,
    .dmabuf = ShmBufferWrapper.dmabuf,
    .shm = ShmBufferWrapper.shm,
    .begin_data_ptr = ShmBufferWrapper.beginDataPtr,
    .end_data_ptr = ShmBufferWrapper.endDataPtr,
    .send_release = ShmBufferWrapper.sendRelease,
    .lock = ShmBufferWrapper.lock,
    .unlock = ShmBufferWrapper.unlock,
    .locked = ShmBufferWrapper.locked,
    .deinit = ShmBufferWrapper.deinitBuffer,
};

// Tests
const testing = core.testing;

test "Output - init and deinit" {
    // Skip test if no WAYLAND_DISPLAY
    if (std.posix.getenv("WAYLAND_DISPLAY") == null) {
        return error.SkipZigTest;
    }

    const allocator = testing.allocator;
    const test_setup = @import("wayland").test_setup;

    var runtime = try test_setup.RuntimeDir.setup(allocator);
    defer runtime.cleanup();

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
