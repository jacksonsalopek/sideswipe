const std = @import("std");
const math = @import("core.math");
const Vector2D = math.Vector2D;
const attachment = @import("attachment.zig");

/// Buffer capability flags
pub const BufferCapability = packed struct(u32) {
    dataptr: bool = false,
    _padding: u31 = 0,

    pub const none: BufferCapability = .{};
};

/// Buffer type enumeration
pub const BufferType = enum(u32) {
    dmabuf = 0,
    shm = 1,
    misc = 2,
};

/// DMA-BUF attributes
pub const DMABUFAttrs = struct {
    success: bool = false,
    size: Vector2D = .{},
    format: u32 = 0, // fourcc
    modifier: u64 = 0,
    planes: i32 = 1,
    offsets: [4]u32 = [_]u32{0} ** 4,
    strides: [4]u32 = [_]u32{0} ** 4,
    fds: [4]i32 = [_]i32{-1} ** 4,
};

/// Shared memory attributes
pub const SSHMAttrs = struct {
    success: bool = false,
    fd: i32 = 0,
    format: u32 = 0,
    size: Vector2D = .{},
    stride: i32 = 0,
    offset: i64 = 0,
};

/// Data pointer result tuple
pub const DataPtrResult = struct {
    ptr: ?[*]u8,
    flags: u32,
    size: usize,
};

/// Buffer interface using vtable pattern
pub const IBuffer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Get buffer capabilities
        caps: *const fn (ptr: *anyopaque) BufferCapability,
        /// Get buffer type
        type: *const fn (ptr: *anyopaque) BufferType,
        /// Update buffer with damage region
        update: *const fn (ptr: *anyopaque, damage: *const anyopaque) void,
        /// Check if buffer updates are synchronous (CPU-based)
        is_synchronous: *const fn (ptr: *anyopaque) bool,
        /// Check if buffer is in good state
        good: *const fn (ptr: *anyopaque) bool,
        /// Get DMA-BUF attributes (optional, returns default if not supported)
        dmabuf: *const fn (ptr: *anyopaque) DMABUFAttrs,
        /// Get shared memory attributes (optional, returns default if not supported)
        shm: *const fn (ptr: *anyopaque) SSHMAttrs,
        /// Begin direct data pointer access
        begin_data_ptr: *const fn (ptr: *anyopaque, flags: u32) DataPtrResult,
        /// End direct data pointer access
        end_data_ptr: *const fn (ptr: *anyopaque) void,
        /// Send release signal to buffer
        send_release: *const fn (ptr: *anyopaque) void,
        /// Lock the buffer (increment lock count)
        lock: *const fn (ptr: *anyopaque) void,
        /// Unlock the buffer (decrement lock count, release if zero)
        unlock: *const fn (ptr: *anyopaque) void,
        /// Check if buffer is locked
        locked: *const fn (ptr: *anyopaque) bool,
        /// Destroy/cleanup the buffer
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn caps(self: IBuffer) BufferCapability {
        return self.vtable.caps(self.ptr);
    }

    pub fn bufferType(self: IBuffer) BufferType {
        return self.vtable.type(self.ptr);
    }

    pub fn update(self: IBuffer, damage: *const anyopaque) void {
        self.vtable.update(self.ptr, damage);
    }

    pub fn isSynchronous(self: IBuffer) bool {
        return self.vtable.is_synchronous(self.ptr);
    }

    pub fn good(self: IBuffer) bool {
        return self.vtable.good(self.ptr);
    }

    pub fn dmabuf(self: IBuffer) DMABUFAttrs {
        return self.vtable.dmabuf(self.ptr);
    }

    pub fn shm(self: IBuffer) SSHMAttrs {
        return self.vtable.shm(self.ptr);
    }

    pub fn beginDataPtr(self: IBuffer, flags: u32) DataPtrResult {
        return self.vtable.begin_data_ptr(self.ptr, flags);
    }

    pub fn endDataPtr(self: IBuffer) void {
        self.vtable.end_data_ptr(self.ptr);
    }

    pub fn sendRelease(self: IBuffer) void {
        self.vtable.send_release(self.ptr);
    }

    pub fn lock(self: IBuffer) void {
        self.vtable.lock(self.ptr);
    }

    pub fn unlock(self: IBuffer) void {
        self.vtable.unlock(self.ptr);
    }

    pub fn locked(self: IBuffer) bool {
        return self.vtable.locked(self.ptr);
    }

    pub fn deinit(self: IBuffer) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Base buffer implementation with default behavior
pub const Buffer = struct {
    size: Vector2D = .{},
    is_opaque: bool = false,
    locked_by_backend: bool = false,
    locks: i32 = 0,
    attachments: attachment.Manager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{
            .attachments = attachment.Manager.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.attachments.deinit();
    }

    /// Default implementation: returns empty DMA-BUF attributes
    pub fn defaultDmabuf(_: *anyopaque) DMABUFAttrs {
        return DMABUFAttrs{};
    }

    /// Default implementation: returns empty SHM attributes
    pub fn defaultShm(_: *anyopaque) SSHMAttrs {
        return SSHMAttrs{};
    }

    /// Default implementation: returns null data pointer
    pub fn defaultBeginDataPtr(_: *anyopaque, _: u32) DataPtrResult {
        return DataPtrResult{
            .ptr = null,
            .flags = 0,
            .size = 0,
        };
    }

    /// Default implementation: no-op
    pub fn defaultEndDataPtr(_: *anyopaque) void {}

    /// Default implementation: no-op
    pub fn defaultSendRelease(_: *anyopaque) void {}

    /// Lock the buffer (increment lock count)
    pub fn defaultLock(ptr: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(ptr));
        self.locks += 1;
    }

    /// Unlock the buffer (decrement lock count)
    pub fn defaultUnlock(ptr: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(ptr));
        self.locks -= 1;

        std.debug.assert(self.locks >= 0);

        if (self.locks <= 0) {
            // Would call sendRelease here if we had access to vtable
            // In practice, implementations should override this
        }
    }

    /// Check if buffer is locked
    pub fn defaultLocked(ptr: *anyopaque) bool {
        const self: *Buffer = @ptrCast(@alignCast(ptr));
        return self.locks > 0;
    }
};

/// Example of how to implement a concrete buffer type
pub const ExampleBuffer = struct {
    base: Buffer,
    // Add buffer-specific fields here

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .base = Buffer.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.base.deinit();
    }

    pub fn interface(self: *Self) IBuffer {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn caps(_: *anyopaque) BufferCapability {
        return BufferCapability.none;
    }

    fn bufferType(_: *anyopaque) BufferType {
        return .misc;
    }

    fn update(_: *anyopaque, _: *const anyopaque) void {
        // Implement update logic
    }

    fn isSynchronous(_: *anyopaque) bool {
        return true;
    }

    fn good(_: *anyopaque) bool {
        return true;
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = IBuffer.VTable{
        .caps = caps,
        .type = bufferType,
        .update = update,
        .is_synchronous = isSynchronous,
        .good = good,
        .dmabuf = Buffer.defaultDmabuf,
        .shm = Buffer.defaultShm,
        .begin_data_ptr = Buffer.defaultBeginDataPtr,
        .end_data_ptr = Buffer.defaultEndDataPtr,
        .send_release = Buffer.defaultSendRelease,
        .lock = Buffer.defaultLock,
        .unlock = Buffer.defaultUnlock,
        .locked = Buffer.defaultLocked,
        .deinit = deinitVTable,
    };
};

test "BufferCapability - flags" {
    const cap1 = BufferCapability.none;
    try std.testing.expect(!cap1.dataptr);

    const cap2 = BufferCapability{ .dataptr = true };
    try std.testing.expect(cap2.dataptr);
}

test "BufferType - enumeration" {
    try std.testing.expectEqual(BufferType.dmabuf, .dmabuf);
    try std.testing.expectEqual(BufferType.shm, .shm);
    try std.testing.expectEqual(BufferType.misc, .misc);
}

test "DMABUFAttrs - default values" {
    const attrs = DMABUFAttrs{};
    try std.testing.expect(!attrs.success);
    try std.testing.expectEqual(@as(u32, 0), attrs.format);
    try std.testing.expectEqual(@as(i32, 1), attrs.planes);
    try std.testing.expectEqual(@as(i32, -1), attrs.fds[0]);
}

test "ExampleBuffer - interface and locking" {
    var buffer = ExampleBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    const ibuf = buffer.interface();
    try std.testing.expect(ibuf.good());
    try std.testing.expect(ibuf.isSynchronous());
    try std.testing.expectEqual(BufferType.misc, ibuf.bufferType());

    // Test locking mechanism
    try std.testing.expect(!ibuf.locked());
    ibuf.lock();
    try std.testing.expect(ibuf.locked());
    ibuf.unlock();
    try std.testing.expect(!ibuf.locked());
}

test "Buffer - attachments management" {
    const testing = std.testing;

    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    const TestAttachment = struct {
        value: i32,

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = attachment.IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    // Add attachment to buffer
    var test_data = TestAttachment{ .value = 42 };
    const att = attachment.IAttachment.init(&test_data, &TestAttachment.vtable_instance);
    try buffer.attachments.add(TestAttachment, att);

    try testing.expect(buffer.attachments.has(TestAttachment));

    const retrieved = buffer.attachments.get(TestAttachment);
    try testing.expectEqual(@as(i32, 42), retrieved.?.value);
}

test "Buffer - lock/unlock ref counting edge cases" {
    const testing = std.testing;

    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    // Initial state
    try testing.expectEqual(@as(i32, 0), buffer.locks);

    // Multiple locks
    Buffer.defaultLock(&buffer);
    try testing.expectEqual(@as(i32, 1), buffer.locks);

    Buffer.defaultLock(&buffer);
    try testing.expectEqual(@as(i32, 2), buffer.locks);

    Buffer.defaultLock(&buffer);
    try testing.expectEqual(@as(i32, 3), buffer.locks);

    // Unlock one by one
    Buffer.defaultUnlock(&buffer);
    try testing.expectEqual(@as(i32, 2), buffer.locks);

    Buffer.defaultUnlock(&buffer);
    try testing.expectEqual(@as(i32, 1), buffer.locks);

    Buffer.defaultUnlock(&buffer);
    try testing.expectEqual(@as(i32, 0), buffer.locks);
}

test "Buffer - attachment lifecycle with buffer destruction" {
    const testing = std.testing;

    var deinit_called = false;

    const TestAttachment = struct {
        flag: *bool,

        fn deinitImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.flag.* = true;
        }

        const vtable_instance = attachment.IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    {
        var buf = Buffer.init(testing.allocator);

        var test_data = TestAttachment{ .flag = &deinit_called };
        const att = attachment.IAttachment.init(&test_data, &TestAttachment.vtable_instance);
        try buf.attachments.add(TestAttachment, att);

        try testing.expect(!deinit_called);
        // Buffer goes out of scope, should clean up attachments
        buf.deinit();
    }

    try testing.expect(deinit_called);
}

test "Buffer - DMABUFAttrs validation (planes, strides, offsets)" {
    const testing = std.testing;

    const attrs = DMABUFAttrs{
        .success = true,
        .size = Vector2D.init(1920, 1080),
        .format = 0x34325258,
        .modifier = 0x0100000000000002,
        .planes = 3,
        .offsets = [_]u32{ 0, 2073600, 2073600 + 518400, 0 },
        .strides = [_]u32{ 1920, 960, 960, 0 },
        .fds = [_]i32{ 42, 42, 42, -1 },
    };

    try testing.expect(attrs.success);
    try testing.expectEqual(@as(i32, 3), attrs.planes);
    try testing.expectEqual(@as(u32, 1920), attrs.strides[0]);
    try testing.expectEqual(@as(u32, 0), attrs.offsets[0]);
    try testing.expectEqual(@as(i32, 42), attrs.fds[0]);
}

test "Buffer - simultaneous lock by multiple consumers" {
    const testing = std.testing;

    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();

    // Simulate 5 consumers locking
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        Buffer.defaultLock(&buffer);
    }

    try testing.expectEqual(@as(i32, 5), buffer.locks);
    try testing.expect(Buffer.defaultLocked(&buffer));

    // Unlock 3 times - should still be locked
    Buffer.defaultUnlock(&buffer);
    Buffer.defaultUnlock(&buffer);
    Buffer.defaultUnlock(&buffer);

    try testing.expectEqual(@as(i32, 2), buffer.locks);
    try testing.expect(Buffer.defaultLocked(&buffer));

    // Unlock remaining
    Buffer.defaultUnlock(&buffer);
    Buffer.defaultUnlock(&buffer);

    try testing.expectEqual(@as(i32, 0), buffer.locks);
    try testing.expect(!Buffer.defaultLocked(&buffer));
}

test "Buffer - sendRelease called only when fully unlocked" {
    const testing = std.testing;

    var release_count: u32 = 0;

    const TestBuffer = struct {
        base: Buffer,
        release_counter: *u32,

        fn sendReleaseImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.release_counter.* += 1;
        }

        fn lockImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.base.locks += 1;
        }

        fn unlockImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.base.locks -= 1;
            if (self.base.locks <= 0) {
                sendReleaseImpl(ptr);
            }
        }

        fn lockedImpl(ptr: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.base.locks > 0;
        }

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IBuffer.VTable{
            .caps = undefined,
            .type = undefined,
            .update = undefined,
            .is_synchronous = undefined,
            .good = undefined,
            .dmabuf = Buffer.defaultDmabuf,
            .shm = Buffer.defaultShm,
            .begin_data_ptr = Buffer.defaultBeginDataPtr,
            .end_data_ptr = Buffer.defaultEndDataPtr,
            .send_release = sendReleaseImpl,
            .lock = lockImpl,
            .unlock = unlockImpl,
            .locked = lockedImpl,
            .deinit = deinitImpl,
        };
    };

    var test_buf = TestBuffer{
        .base = Buffer.init(testing.allocator),
        .release_counter = &release_count,
    };
    defer test_buf.base.deinit();

    const ibuf = IBuffer{
        .ptr = &test_buf,
        .vtable = &TestBuffer.vtable_instance,
    };

    // Lock 3 times
    ibuf.lock();
    ibuf.lock();
    ibuf.lock();
    try testing.expectEqual(@as(u32, 0), release_count);

    // Unlock twice - should not release yet
    ibuf.unlock();
    ibuf.unlock();
    try testing.expectEqual(@as(u32, 0), release_count);

    // Final unlock - should call sendRelease
    ibuf.unlock();
    try testing.expectEqual(@as(u32, 1), release_count);
}
