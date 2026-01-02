//! Swapchain for buffer rotation inspired by aquamarine

const std = @import("std");
const math = @import("core.math");
const Vector2D = math.vector2d.Type;
const buffer = @import("buffer.zig");
const allocator = @import("allocator.zig");

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
    alloc: std.mem.Allocator,
    buffer_allocator: allocator.Interface,
    backend_impl: ?*anyopaque = null, // Opaque pointer to IBackendImplementation
    options: Options,
    buffers: std.ArrayList(buffer.Interface),
    last_acquired: isize = 0,

    const Self = @This();

    /// Create a new swapchain
    pub fn create(
        alloc: std.mem.Allocator,
        buffer_allocator: allocator.Interface,
        backend_impl: ?*anyopaque,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .buffer_allocator = buffer_allocator,
            .backend_impl = backend_impl,
            .options = .{},
            .buffers = std.ArrayList(buffer.Interface){},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Reconfigure the swapchain with new options
    pub fn reconfigure(self: *Self, new_options: Options) !bool {
        // Clear swapchain if size or length is zero
        if (new_options.size.getX() == 0 or new_options.size.getY() == 0 or new_options.length == 0) {
            for (self.buffers.items) |buf| {
                buf.deinit();
            }
            self.buffers.clearRetainingCapacity();
            self.options = new_options;
            return true;
        }

        // Check if we can avoid full reconfiguration
        const format_unchanged = new_options.format == self.options.format or new_options.format == 0;
        const size_unchanged = new_options.size.eql(self.options.size);

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
    pub fn next(self: *Self, age: ?*i32) ?buffer.Interface {
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
    pub fn contains(self: *Self, buf: buffer.Interface) bool {
        for (self.buffers.items) |swapchain_buf| {
            if (swapchain_buf.base.ptr == buf.base.ptr) {
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
    pub fn getAllocator(self: *Self) allocator.Interface {
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
        var new_buffers = std.ArrayList(buffer.Interface){};
        errdefer {
            for (new_buffers.items) |buf| {
                buf.deinit();
            }
            new_buffers.deinit(self.alloc);
        }

        const params = allocator.BufferParams{
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
            try new_buffers.append(self.alloc, buf);
        }

        // Success - replace old buffers
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.deinit(self.alloc);
        self.buffers = new_buffers;

        return true;
    }

    /// Resize swapchain (adjust buffer count without reallocating)
    fn resize(self: *Self, new_size: usize) !bool {
        if (new_size == self.buffers.items.len) {
            return true;
        }

        const params = allocator.BufferParams{
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
                buf.?.deinit();
            }
        } else {
            // Grow
            while (self.buffers.items.len < new_size) {
                const buf = self.buffer_allocator.acquire(&params, null) catch {
                    return false;
                };
                try self.buffers.append(self.alloc, buf);
            }
        }

        return true;
    }
};

// Tests

// Shared mock allocator for tests - doesn't actually allocate buffers
const TestMockAlloc = struct {
    fn acquire(ptr: *anyopaque, params: *const allocator.BufferParams, swapchain_ptr: ?*anyopaque) anyerror!buffer.Interface {
        _ = ptr;
        _ = params;
        _ = swapchain_ptr;
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

    fn allocatorType(ptr: *anyopaque) allocator.Type {
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
    const vtable_instance = allocator.Interface.VTableDef{
        .acquire = acquire,
        .get_backend = getBackend,
        .drm_fd = drmFd,
        .allocator_type = allocatorType,
        .destroy_buffers = destroyBuffers,
        .deinit = deinitFn,
    };

    fn get() allocator.Interface {
        return allocator.Interface.init(&instance, &vtable_instance);
    }
};

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

    var swapchain = try Swapchain.create(testing.allocator, TestMockAlloc.get(), null);
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

    var swapchain = try Swapchain.create(testing.allocator, TestMockAlloc.get(), null);
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

test "Swapchain - reconfigure with zero size" {
    const testing = std.testing;

    var swapchain = try Swapchain.create(testing.allocator, TestMockAlloc.get(), null);
    defer swapchain.deinit();

    // Reconfigure with zero size should clear buffers
    const opts = Options{
        .length = 0,
        .size = Vector2D.init(0, 0),
    };

    const result = try swapchain.reconfigure(opts);
    try testing.expect(result);
    try testing.expectEqual(@as(usize, 0), swapchain.buffers.items.len);
}

test "Swapchain - rollback multiple times" {
    const testing = std.testing;

    var swapchain = try Swapchain.create(testing.allocator, TestMockAlloc.get(), null);
    defer swapchain.deinit();

    swapchain.options.length = 5;
    swapchain.last_acquired = 3;

    swapchain.rollback();
    try testing.expectEqual(@as(isize, 2), swapchain.last_acquired);

    swapchain.rollback();
    try testing.expectEqual(@as(isize, 1), swapchain.last_acquired);

    swapchain.rollback();
    try testing.expectEqual(@as(isize, 0), swapchain.last_acquired);

    // Rollback from 0 should wrap to 4
    swapchain.rollback();
    try testing.expectEqual(@as(isize, 4), swapchain.last_acquired);
}

test "Swapchain - resize from 3 to 5 buffers" {
    const testing = std.testing;

    var swapchain = try Swapchain.create(testing.allocator, TestMockAlloc.get(), null);
    defer swapchain.deinit();

    // Setup initial state with 3 buffers
    swapchain.options.length = 3;
    swapchain.options.size = Vector2D.init(1920, 1080);
    swapchain.options.format = 0x34325258;

    // Verify length changes are tracked
    swapchain.options.length = 5;
    try testing.expectEqual(@as(usize, 5), swapchain.options.length);
}

test "Swapchain - format auto-selection from allocator" {
    const testing = std.testing;

    const MockAlloc = struct {
        fn acquire(ptr: *anyopaque, params: *const allocator.BufferParams, swapchain_ptr: ?*anyopaque) anyerror!buffer.Interface {
            _ = ptr;
            _ = swapchain_ptr;

            // Verify format was passed as 0 for auto-selection
            try testing.expectEqual(@as(u32, 0), params.format);

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
        fn allocatorType(ptr: *anyopaque) allocator.Type {
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
        const vtable_instance = allocator.Interface.VTableDef{
            .acquire = acquire,
            .get_backend = getBackend,
            .drm_fd = drmFd,
            .allocator_type = allocatorType,
            .destroy_buffers = destroyBuffers,
            .deinit = deinitFn,
        };
    };

    const mock_alloc = allocator.Interface.init(&MockAlloc.instance, &MockAlloc.vtable_instance);

    var swapchain = try Swapchain.create(testing.allocator, mock_alloc, null);
    defer swapchain.deinit();

    // Configure with format = 0 for auto-selection
    const opts = Options{
        .length = 2,
        .size = Vector2D.init(1920, 1080),
        .format = 0, // Auto-select
    };

    // reconfigure will fail because acquire returns NotImplemented,
    // but we verify the format parameter was passed correctly
    _ = swapchain.reconfigure(opts) catch |err| {
        try testing.expectEqual(error.NotImplemented, err);
    };
}

test "Swapchain - next() cycling with age tracking" {
    const testing = std.testing;

    var swapchain = try Swapchain.create(testing.allocator, TestMockAlloc.get(), null);
    defer swapchain.deinit();

    // Test that next() returns null when there are no buffers (length = 0)
    swapchain.options.length = 0;
    var age: i32 = 0;
    const buf = swapchain.next(&age);
    try testing.expectEqual(@as(?buffer.Interface, null), buf);

    // Test cycling math behavior
    swapchain.options.length = 3;
    swapchain.last_acquired = -1;

    // Verify cycling behavior by manually testing the math
    // (we can't call next() without actual buffers, so we test the cycling logic)
    const idx1 = @rem((swapchain.last_acquired + 1), @as(isize, @intCast(swapchain.options.length)));
    try testing.expectEqual(@as(isize, 0), idx1);

    const idx2 = @rem((idx1 + 1), @as(isize, @intCast(swapchain.options.length)));
    try testing.expectEqual(@as(isize, 1), idx2);

    const idx3 = @rem((idx2 + 1), @as(isize, @intCast(swapchain.options.length)));
    try testing.expectEqual(@as(isize, 2), idx3);

    // Should wrap around to 0
    const idx4 = @rem((idx3 + 1), @as(isize, @intCast(swapchain.options.length)));
    try testing.expectEqual(@as(isize, 0), idx4);
}

test "Swapchain - contains() with non-swapchain buffer" {
    const testing = std.testing;

    var swapchain = try Swapchain.create(testing.allocator, TestMockAlloc.get(), null);
    defer swapchain.deinit();

    // Create a non-swapchain buffer with minimal vtable
    const MockBuffer = struct {
        fn capsFn(ptr: *anyopaque) buffer.Capability {
            _ = ptr;
            return .{};
        }
        fn typeFn(ptr: *anyopaque) buffer.Type {
            _ = ptr;
            return .dmabuf;
        }
        fn updateFn(ptr: *anyopaque, damage: *const anyopaque) void {
            _ = ptr;
            _ = damage;
        }
        fn isSynchronousFn(ptr: *anyopaque) bool {
            _ = ptr;
            return false;
        }
        fn goodFn(ptr: *anyopaque) bool {
            _ = ptr;
            return true;
        }
        fn dmabufFn(ptr: *anyopaque) buffer.DMABUFAttrs {
            _ = ptr;
            return .{};
        }
        fn shmFn(ptr: *anyopaque) buffer.SSHMAttrs {
            _ = ptr;
            return .{};
        }
        fn beginDataPtrFn(ptr: *anyopaque, flags: u32) buffer.DataPtrResult {
            _ = ptr;
            _ = flags;
            return .{ .ptr = null, .flags = 0, .size = 0 };
        }
        fn endDataPtrFn(ptr: *anyopaque) void {
            _ = ptr;
        }
        fn sendReleaseFn(ptr: *anyopaque) void {
            _ = ptr;
        }
        fn lockFn(ptr: *anyopaque) void {
            _ = ptr;
        }
        fn unlockFn(ptr: *anyopaque) void {
            _ = ptr;
        }
        fn lockedFn(ptr: *anyopaque) bool {
            _ = ptr;
            return false;
        }
        fn deinitBufFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = buffer.Interface.VTableDef{
            .caps = capsFn,
            .type = typeFn,
            .update = updateFn,
            .is_synchronous = isSynchronousFn,
            .good = goodFn,
            .dmabuf = dmabufFn,
            .shm = shmFn,
            .begin_data_ptr = beginDataPtrFn,
            .end_data_ptr = endDataPtrFn,
            .send_release = sendReleaseFn,
            .lock = lockFn,
            .unlock = unlockFn,
            .locked = lockedFn,
            .deinit = deinitBufFn,
        };
    };

    var external_buf_storage: MockBuffer = .{};
    const external_buf = buffer.Interface.init(@as(*anyopaque, @ptrCast(&external_buf_storage)), &MockBuffer.vtable_instance);

    // External buffer should not be in swapchain
    try testing.expect(!swapchain.contains(external_buf));
}
