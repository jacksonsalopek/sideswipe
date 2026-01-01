//! Swapchain for buffer rotation inspired by aquamarine

const std = @import("std");
const math = @import("core.math");
const Vector2D = math.Vector2D;
const buffer_mod = @import("buffer.zig");
const allocator_mod = @import("allocator.zig");

// Forward declarations to avoid circular dependencies
// We don't import backend.zig here!
const IBuffer = buffer_mod.IBuffer;
const IAllocator = allocator_mod.IAllocator;
const BufferParams = allocator_mod.BufferParams;

/// Swapchain options
pub const Options = struct {
    length: usize = 0,
    size: Vector2D = .{},
    format: u32 = 0, // DRM_FORMAT_INVALID if auto-select
    scanout: bool = false,
    cursor: bool = false, // requires scanout = true
    multigpu: bool = false, // if true, will force linear
    scanout_output: ?*anyopaque = null, // Weak pointer to IOutput (opaque to avoid dependency)
};

/// Swapchain manages a rotating buffer pool
pub const Swapchain = struct {
    allocator: std.mem.Allocator,
    buffer_allocator: IAllocator,
    backend_impl: ?*anyopaque = null, // Opaque pointer to IBackendImplementation
    options: Options,
    buffers: std.ArrayList(IBuffer),
    last_acquired: isize = 0,

    const Self = @This();

    /// Create a new swapchain
    pub fn create(
        allocator: std.mem.Allocator,
        buffer_allocator: IAllocator,
        backend_impl: ?*anyopaque,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .buffer_allocator = buffer_allocator,
            .backend_impl = backend_impl,
            .options = .{},
            .buffers = std.ArrayList(IBuffer){},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Reconfigure the swapchain with new options
    pub fn reconfigure(self: *Self, new_options: Options) !bool {
        // Clear swapchain if size or length is zero
        if (new_options.size.x == 0 or new_options.size.y == 0 or new_options.length == 0) {
            for (self.buffers.items) |buf| {
                buf.deinit();
            }
            self.buffers.clearRetainingCapacity();
            self.options = new_options;
            return true;
        }

        // Check if we can avoid full reconfiguration
        const format_unchanged = new_options.format == self.options.format or new_options.format == 0;
        const size_unchanged = new_options.size.equal(self.options.size);

        if (format_unchanged and size_unchanged and
            new_options.length == self.options.length and
            self.buffers.items.len == self.options.length)
        {
            // No reconfiguration needed
            return true;
        }

        if (format_unchanged and size_unchanged) {
            // Just resize the buffer count
            const ok = try self.resize(new_options.length);
            if (!ok) return false;
            self.options = new_options;
            return true;
        }

        // Full reconfiguration needed
        const ok = try self.fullReconfigure(new_options);
        if (!ok) return false;

        self.options = new_options;

        // Update format if it was auto-selected
        if (self.options.format == 0 and self.buffers.items.len > 0) {
            self.options.format = self.buffers.items[0].dmabuf().format;
        }

        return true;
    }

    /// Get the next buffer in rotation
    pub fn next(self: *Self, age: ?*i32) ?IBuffer {
        if (self.options.length == 0) {
            return null;
        }

        self.last_acquired = @rem((self.last_acquired + 1), @as(isize, @intCast(self.options.length)));

        if (age) |age_ptr| {
            age_ptr.* = @intCast(self.options.length); // We always just rotate
        }

        const idx: usize = @intCast(self.last_acquired);
        return self.buffers.items[idx];
    }

    /// Check if swapchain contains a buffer
    pub fn contains(self: *Self, buf: IBuffer) bool {
        for (self.buffers.items) |swapchain_buf| {
            if (swapchain_buf.ptr == buf.ptr) {
                return true;
            }
        }
        return false;
    }

    /// Get current swapchain options
    pub fn currentOptions(self: *Self) Options {
        return self.options;
    }

    /// Get the allocator used by this swapchain
    pub fn getAllocator(self: *Self) IAllocator {
        return self.buffer_allocator;
    }

    /// Roll back to previous buffer (e.g., if commit fails)
    pub fn rollback(self: *Self) void {
        self.last_acquired -= 1;
        if (self.last_acquired < 0) {
            self.last_acquired = @as(isize, @intCast(self.options.length)) - 1;
        }
    }

    /// Full reconfiguration - reallocate all buffers
    fn fullReconfigure(self: *Self, new_options: Options) !bool {
        var new_buffers = std.ArrayList(IBuffer){};
        errdefer {
            for (new_buffers.items) |buf| {
                buf.deinit();
            }
            new_buffers.deinit(self.allocator);
        }

        const params = BufferParams{
            .size = new_options.size,
            .format = new_options.format,
            .scanout = new_options.scanout,
            .cursor = new_options.cursor,
            .multigpu = new_options.multigpu,
        };

        var i: usize = 0;
        while (i < new_options.length) : (i += 1) {
            const buf = self.buffer_allocator.acquire(&params, null) catch {
                return false;
            };
            try new_buffers.append(self.allocator, buf);
        }

        // Success - replace old buffers
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.deinit(self.allocator);
        self.buffers = new_buffers;

        return true;
    }

    /// Resize swapchain (adjust buffer count without reallocating)
    fn resize(self: *Self, new_size: usize) !bool {
        if (new_size == self.buffers.items.len) {
            return true;
        }

        const params = BufferParams{
            .size = self.options.size,
            .format = self.options.format,
            .scanout = self.options.scanout,
            .cursor = self.options.cursor,
            .multigpu = self.options.multigpu,
        };

        if (new_size < self.buffers.items.len) {
            // Shrink
            while (self.buffers.items.len > new_size) {
                const buf = self.buffers.pop();
                buf.deinit();
            }
        } else {
            // Grow
            while (self.buffers.items.len < new_size) {
                const buf = self.buffer_allocator.acquire(&params, null) catch {
                    return false;
                };
                try self.buffers.append(self.allocator, buf);
            }
        }

        return true;
    }
};

// Tests
test "Swapchain - Options defaults" {
    const testing = std.testing;

    const opts: Options = .{};
    try testing.expectEqual(@as(usize, 0), opts.length);
    try testing.expectEqual(@as(u32, 0), opts.format);
    try testing.expectEqual(false, opts.scanout);
    try testing.expectEqual(false, opts.cursor);
    try testing.expectEqual(false, opts.multigpu);
}

test "Swapchain - rollback wraps around" {
    const testing = std.testing;

    // Create a mock allocator that doesn't actually allocate
    const MockAllocator = struct {
        fn acquire(ptr: *anyopaque, params: *const BufferParams, swapchain: ?*anyopaque) anyerror!IBuffer {
            _ = ptr;
            _ = params;
            _ = swapchain;
            return error.NotImplemented;
        }

        fn getBackend(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn drmFd(ptr: *anyopaque) i32 {
            _ = ptr;
            return -1;
        }

        fn allocatorType(ptr: *anyopaque) allocator_mod.Type {
            _ = ptr;
            return .gbm;
        }

        fn destroyBuffers(ptr: *anyopaque) void {
            _ = ptr;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        var instance: u8 = 0;
        const vtable_instance = IAllocator.VTable{
            .acquire = acquire,
            .get_backend = getBackend,
            .drm_fd = drmFd,
            .allocator_type = allocatorType,
            .destroy_buffers = destroyBuffers,
            .deinit = deinitFn,
        };
    };

    const mock_alloc = IAllocator{
        .ptr = &MockAllocator.instance,
        .vtable = &MockAllocator.vtable_instance,
    };

    var swapchain = try Swapchain.create(testing.allocator, mock_alloc, null);
    defer swapchain.deinit();

    swapchain.options.length = 3;
    swapchain.last_acquired = 0;

    swapchain.rollback();
    try testing.expectEqual(@as(isize, 2), swapchain.last_acquired);

    swapchain.rollback();
    try testing.expectEqual(@as(isize, 1), swapchain.last_acquired);
}

test "Swapchain - currentOptions returns options" {
    const testing = std.testing;

    const MockAllocator = struct {
        fn acquire(ptr: *anyopaque, params: *const BufferParams, swapchain: ?*anyopaque) anyerror!IBuffer {
            _ = ptr;
            _ = params;
            _ = swapchain;
            return error.NotImplemented;
        }

        fn getBackend(ptr: *anyopaque) ?*anyopaque {
            _ = ptr;
            return null;
        }

        fn drmFd(ptr: *anyopaque) i32 {
            _ = ptr;
            return -1;
        }

        fn allocatorType(ptr: *anyopaque) allocator_mod.Type {
            _ = ptr;
            return .gbm;
        }

        fn destroyBuffers(ptr: *anyopaque) void {
            _ = ptr;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        var instance: u8 = 0;
        const vtable_instance = IAllocator.VTable{
            .acquire = acquire,
            .get_backend = getBackend,
            .drm_fd = drmFd,
            .allocator_type = allocatorType,
            .destroy_buffers = destroyBuffers,
            .deinit = deinitFn,
        };
    };

    const mock_alloc = IAllocator{
        .ptr = &MockAllocator.instance,
        .vtable = &MockAllocator.vtable_instance,
    };

    var swapchain = try Swapchain.create(testing.allocator, mock_alloc, null);
    defer swapchain.deinit();

    const test_opts = Options{
        .length = 3,
        .size = Vector2D.init(1920, 1080),
        .format = 0x34325258, // Some DRM format
    };

    swapchain.options = test_opts;
    const current = swapchain.currentOptions();

    try testing.expectEqual(@as(usize, 3), current.length);
    try testing.expect(current.size.eql(Vector2D.init(1920, 1080)));
}
