//! Buffer allocator interface inspired by aquamarine
//! Provides abstraction for different buffer allocation methods (GBM, DRM dumb buffers)

const std = @import("std");
const math = @import("core.math");
const Vector2D = math.Vector2D;
const buffer = @import("buffer.zig");
const IBuffer = buffer.IBuffer;

/// DRM format constants (from drm_fourcc.h)
pub const DRM_FORMAT_INVALID: u32 = 0;

/// Buffer allocation parameters
pub const BufferParams = struct {
    size: Vector2D = .{},
    format: u32 = DRM_FORMAT_INVALID,
    scanout: bool = false,
    cursor: bool = false,
    multigpu: bool = false,
};

/// Allocator type enumeration
pub const Type = enum(u32) {
    gbm = 0,
    drm_dumb = 1,
};

/// Allocator interface using vtable pattern
pub const IAllocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Acquire/allocate a new buffer with the given parameters
        acquire: *const fn (
            ptr: *anyopaque,
            params: *const BufferParams,
            swapchain: ?*anyopaque,
        ) anyerror!IBuffer,

        /// Get the backend associated with this allocator
        get_backend: *const fn (ptr: *anyopaque) ?*anyopaque,

        /// Get the DRM file descriptor
        drm_fd: *const fn (ptr: *anyopaque) i32,

        /// Get the allocator type
        allocator_type: *const fn (ptr: *anyopaque) Type,

        /// Destroy all buffers allocated by this allocator
        destroy_buffers: *const fn (ptr: *anyopaque) void,

        /// Cleanup the allocator
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Acquire a new buffer with the given parameters
    pub fn acquire(
        self: IAllocator,
        params: *const BufferParams,
        swapchain: ?*anyopaque,
    ) !IBuffer {
        return self.vtable.acquire(self.ptr, params, swapchain);
    }

    /// Get the backend associated with this allocator
    pub fn getBackend(self: IAllocator) ?*anyopaque {
        return self.vtable.get_backend(self.ptr);
    }

    /// Get the DRM file descriptor
    pub fn drmFd(self: IAllocator) i32 {
        return self.vtable.drm_fd(self.ptr);
    }

    /// Get the allocator type
    pub fn allocatorType(self: IAllocator) Type {
        return self.vtable.allocator_type(self.ptr);
    }

    /// Destroy all buffers allocated by this allocator
    pub fn destroyBuffers(self: IAllocator) void {
        self.vtable.destroy_buffers(self.ptr);
    }

    /// Cleanup the allocator
    pub fn deinit(self: IAllocator) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Base allocator implementation with common functionality
pub const Allocator = struct {
    allocator: std.mem.Allocator,
    drm_fd_value: i32 = -1,
    backend_ptr: ?*anyopaque = null,
    buffers: std.ArrayList(IBuffer),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .buffers = std.ArrayList(IBuffer){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.destroyBuffers();
        self.buffers.deinit(self.allocator);
    }

    /// Default implementation: destroys all tracked buffers
    pub fn destroyBuffers(self: *Self) void {
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.clearRetainingCapacity();
    }

    /// Helper to track a newly allocated buffer
    pub fn trackBuffer(self: *Self, buf: IBuffer) !void {
        try self.buffers.append(buf);
    }

    /// Helper to untrack a buffer (without destroying it)
    pub fn untrackBuffer(self: *Self, buf: IBuffer) void {
        for (self.buffers.items, 0..) |tracked, i| {
            if (tracked.ptr == buf.ptr) {
                _ = self.buffers.swapRemove(i);
                break;
            }
        }
    }
};

// Tests
test "Allocator - init and deinit" {
    const testing = std.testing;

    var alloc = Allocator.init(testing.allocator);
    defer alloc.deinit();

    try testing.expectEqual(@as(i32, -1), alloc.drm_fd_value);
    try testing.expectEqual(@as(usize, 0), alloc.buffers.items.len);
}

test "BufferParams - default values" {
    const testing = std.testing;

    const params: BufferParams = .{};

    try testing.expectEqual(DRM_FORMAT_INVALID, params.format);
    try testing.expectEqual(false, params.scanout);
    try testing.expectEqual(false, params.cursor);
    try testing.expectEqual(false, params.multigpu);
}

test "Type - enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 0), @intFromEnum(Type.gbm));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(Type.drm_dumb));
}
