//! GBM (Generic Buffer Manager) allocator implementation
//! Provides hardware-accelerated buffer allocation for DRM/KMS

const std = @import("std");
const core = @import("core");
const math = @import("core.math");
const Vector2D = math.vector2d.Type;
const allocator = @import("allocator.zig");
const Buffer = @import("buffer.zig").Interface;

const gbm = @cImport({
    @cInclude("gbm.h");
});

/// GBM allocator using libgbm
pub const GBMAllocator = struct {
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
        _ = swapchain; // TODO: Use for buffer tracking

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

        // TODO: Wrap GBM BO in Buffer and return
        // For now, clean up and return error
        gbm.gbm_bo_destroy(bo);
        return error.NotFullyImplemented;
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

const testing = core.testing;

// Tests
test "GBMAllocator - invalid fd fails" {
    const result = GBMAllocator.create(testing.allocator, -1);
    try testing.expectError(error.InvalidDrmFd, result);
}

test "GBMAllocator - interface type is GBM" {
    // Use a fake fd for testing (won't actually initialize GBM)
    var alloc_impl = GBMAllocator{
        .base = allocator.Implementation.init(testing.allocator),
        .drm_fd = 99,
    };
    defer alloc_impl.base.deinit();

    const interface = alloc_impl.asInterface();
    try testing.expectEqual(allocator.Type.gbm, interface.allocatorType());
    try testing.expectEqual(@as(i32, 99), interface.drmFd());
}
