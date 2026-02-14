//! GBM (Generic Buffer Manager) allocator implementation
//! Provides hardware-accelerated buffer allocation for DRM/KMS

const std = @import("std");
const core = @import("core");
const math = @import("core.math");
const Vector2D = math.Vec2;
const allocator = @import("allocator.zig");
const buffer = @import("buffer.zig");
const Buffer = buffer.Interface;

const gbm = @cImport({
    @cInclude("gbm.h");
});

/// GBM allocator using libgbm
pub const Allocator = struct {
    base: allocator.Implementation,
    drm_fd: i32,
    gbm_device: ?*gbm.struct_gbm_device = null,

    const Self = @This();

    /// Create a GBM allocator for the given DRM file descriptor
    pub fn create(alloc: std.mem.Allocator, drm_fd: i32) !*Self {
        if (drm_fd < 0) {
            return error.InvalidDrmFd;
        }

        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        self.* = .{
            .base = allocator.Implementation.init(alloc),
            .drm_fd = drm_fd,
        };

        // Initialize GBM device
        self.gbm_device = gbm.gbm_create_device(drm_fd);
        if (self.gbm_device == null) {
            alloc.destroy(self);
            return error.GbmDeviceCreationFailed;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Destroy GBM device
        if (self.gbm_device) |device| {
            gbm.gbm_device_destroy(device);
        }

        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    /// Get the VTable for this allocator to use as IAllocator
    pub fn asInterface(self: *Self) allocator.Interface {
        const vtable = comptime allocator.Interface.VTableDef{
            .acquire = acquireImpl,
            .get_backend = getBackendImpl,
            .drm_fd = drmFdImpl,
            .allocator_type = allocatorTypeImpl,
            .destroy_buffers = destroyBuffersImpl,
            .deinit = deinitImpl,
        };

        return allocator.Interface.init(self, &vtable);
    }

    fn acquireImpl(
        ptr: *anyopaque,
        params: *const allocator.BufferParams,
        swapchain: ?*anyopaque,
    ) anyerror!Buffer {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = swapchain; // Currently unused - could be used for buffer tracking

        if (self.gbm_device == null) {
            return error.NoGbmDevice;
        }

        // Convert parameters to GBM flags
        var usage: u32 = gbm.GBM_BO_USE_RENDERING;
        if (params.scanout) usage |= gbm.GBM_BO_USE_SCANOUT;
        if (params.cursor) usage |= gbm.GBM_BO_USE_CURSOR;

        // Allocate GBM buffer object
        const bo = gbm.gbm_bo_create(
            self.gbm_device,
            @intFromFloat(params.size.getX()),
            @intFromFloat(params.size.getY()),
            params.format,
            usage,
        );

        if (bo == null) {
            return error.GbmAllocationFailed;
        }

        // Wrap GBM BO in Buffer interface
        const gbm_buffer = try GBMBuffer.init(self.base.allocator, bo.?, self.drm_fd);
        errdefer gbm_buffer.deinit();

        return gbm_buffer.asInterface();
    }

    fn getBackendImpl(ptr: *anyopaque) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.base.backend_ptr;
    }

    fn drmFdImpl(ptr: *anyopaque) i32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.drm_fd;
    }

    fn allocatorTypeImpl(ptr: *anyopaque) allocator.Type {
        _ = ptr;
        return .gbm;
    }

    fn destroyBuffersImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.base.destroyBuffers();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// GBM buffer wrapper implementing Buffer interface
const GBMBuffer = struct {
    base: buffer.Buffer,
    gbm_bo: *gbm.struct_gbm_bo,
    drm_fd: i32,
    dmabuf_attrs: buffer.DMABUFAttrs,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, bo: *gbm.struct_gbm_bo, drm_fd: i32) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        // Extract DMA-BUF attributes from GBM BO
        const dmabuf_attrs = extractDMABUFAttrs(bo) catch |err| {
            alloc.destroy(self);
            return err;
        };

        self.* = .{
            .base = buffer.Buffer.init(alloc),
            .gbm_bo = bo,
            .drm_fd = drm_fd,
            .dmabuf_attrs = dmabuf_attrs,
        };

        // Set buffer size
        self.base.size = dmabuf_attrs.size;

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Close DMA-BUF file descriptors
        for (self.dmabuf_attrs.fds) |fd| {
            if (fd >= 0) {
                std.posix.close(fd);
            }
        }

        // Destroy GBM BO
        gbm.gbm_bo_destroy(self.gbm_bo);

        // Clean up base
        self.base.deinit();
        self.base.allocator.destroy(self);
    }

    pub fn asInterface(self: *Self) Buffer {
        return Buffer.init(self, &vtable);
    }

    // Buffer interface implementations

    fn caps(_: *anyopaque) buffer.Capability {
        return .{};
    }

    fn bufferType(_: *anyopaque) buffer.Type {
        return .dmabuf;
    }

    fn update(_: *anyopaque, _: *const anyopaque) void {
        // GBM buffers don't need explicit updates
    }

    fn isSynchronous(_: *anyopaque) bool {
        return false;
    }

    fn good(_: *anyopaque) bool {
        return true;
    }

    fn dmabuf(ptr: *anyopaque) buffer.DMABUFAttrs {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.dmabuf_attrs;
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn lock(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        buffer.Buffer.defaultLock(&self.base);
    }

    fn unlock(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        buffer.Buffer.defaultUnlock(&self.base);
    }

    fn locked(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return buffer.Buffer.defaultLocked(&self.base);
    }

    const vtable = Buffer.VTableDef{
        .caps = caps,
        .type = bufferType,
        .update = update,
        .is_synchronous = isSynchronous,
        .good = good,
        .dmabuf = dmabuf,
        .shm = buffer.Buffer.defaultShm,
        .begin_data_ptr = buffer.Buffer.defaultBeginDataPtr,
        .end_data_ptr = buffer.Buffer.defaultEndDataPtr,
        .send_release = buffer.Buffer.defaultSendRelease,
        .lock = lock,
        .unlock = unlock,
        .locked = locked,
        .deinit = deinitVTable,
    };
};

/// Extract DMA-BUF attributes from GBM buffer object
fn extractDMABUFAttrs(bo: *gbm.struct_gbm_bo) !buffer.DMABUFAttrs {
    var attrs: buffer.DMABUFAttrs = .{
        .success = true,
        .size = Vector2D.init(
            @floatFromInt(gbm.gbm_bo_get_width(bo)),
            @floatFromInt(gbm.gbm_bo_get_height(bo)),
        ),
        .format = gbm.gbm_bo_get_format(bo),
        .modifier = gbm.gbm_bo_get_modifier(bo),
        .planes = @intCast(gbm.gbm_bo_get_plane_count(bo)),
        .fds = [_]i32{-1} ** 4,
        .strides = [_]u32{0} ** 4,
        .offsets = [_]u32{0} ** 4,
    };

    // Export DMA-BUF FDs for each plane
    var i: usize = 0;
    while (i < attrs.planes) : (i += 1) {
        attrs.fds[i] = gbm.gbm_bo_get_fd_for_plane(bo, @intCast(i));
        if (attrs.fds[i] < 0) {
            // Clean up already opened FDs
            var j: usize = 0;
            while (j < i) : (j += 1) {
                std.posix.close(attrs.fds[j]);
            }
            return error.FailedToExportDMABUF;
        }
        attrs.strides[i] = @intCast(gbm.gbm_bo_get_stride_for_plane(bo, @intCast(i)));
        attrs.offsets[i] = @intCast(gbm.gbm_bo_get_offset(bo, @intCast(i)));
    }

    return attrs;
}

const testing = core.testing;

// Tests
test "Allocator - invalid fd fails" {
    const result = Allocator.create(testing.allocator, -1);
    try testing.expectError(error.InvalidDrmFd, result);
}

test "Allocator - interface type is GBM" {
    // Use a fake fd for testing (won't actually initialize GBM)
    var alloc_impl = Allocator{
        .base = allocator.Implementation.init(testing.allocator),
        .drm_fd = 99,
    };
    defer alloc_impl.base.deinit();

    const interface = alloc_impl.asInterface();
    try testing.expectEqual(allocator.Type.gbm, interface.allocatorType());
    try testing.expectEqual(@as(i32, 99), interface.drmFd());
}

test "GBMBuffer - buffer type is dmabuf" {
    // Create a mock buffer structure for testing vtable
    var base_buffer = buffer.Buffer.init(testing.allocator);
    defer base_buffer.deinit();

    const mock_buf = struct {
        var instance: u8 = 0;
    };

    const buf_interface = Buffer.init(&mock_buf.instance, &GBMBuffer.vtable);

    try testing.expectEqual(buffer.Type.dmabuf, buf_interface.bufferType());
    try testing.expect(buf_interface.good());
    try testing.expectFalse(buf_interface.isSynchronous());
}

test "GBMBuffer - locking mechanism" {
    var base_buffer = buffer.Buffer.init(testing.allocator);
    defer base_buffer.deinit();

    // Test lock/unlock through base buffer
    try testing.expectEqual(@as(i32, 0), base_buffer.locks);
    buffer.Buffer.defaultLock(&base_buffer);
    try testing.expectEqual(@as(i32, 1), base_buffer.locks);
    try testing.expect(buffer.Buffer.defaultLocked(&base_buffer));

    buffer.Buffer.defaultUnlock(&base_buffer);
    try testing.expectEqual(@as(i32, 0), base_buffer.locks);
    try testing.expectFalse(buffer.Buffer.defaultLocked(&base_buffer));
}

test "extractDMABUFAttrs - attrs structure" {
    // This test validates the structure of DMABUFAttrs
    // Cannot test actual extraction without GBM device
    const attrs = buffer.DMABUFAttrs{
        .success = true,
        .size = Vector2D.init(1920, 1080),
        .format = 0x34325258, // DRM_FORMAT_XRGB8888
        .modifier = 0,
        .planes = 1,
        .fds = [_]i32{ 42, -1, -1, -1 },
        .strides = [_]u32{ 7680, 0, 0, 0 },
        .offsets = [_]u32{ 0, 0, 0, 0 },
    };

    try testing.expect(attrs.success);
    try testing.expectEqual(@as(i32, 1), attrs.planes);
    try testing.expectEqual(@as(i32, 42), attrs.fds[0]);
    try testing.expectEqual(@as(i32, -1), attrs.fds[1]);
    try testing.expectEqual(@as(u32, 7680), attrs.strides[0]);
}

test "GBMBuffer - capabilities" {
    const mock_buf = struct {
        var instance: u8 = 0;
    };

    const buf_interface = Buffer.init(&mock_buf.instance, &GBMBuffer.vtable);
    const caps = buf_interface.caps();

    try testing.expectFalse(caps.dataptr);
}
