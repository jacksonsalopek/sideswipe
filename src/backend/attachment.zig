//! Attachment manager for type-erased attachments
//! Allows arbitrary data to be attached to objects (like buffers)

const std = @import("std");
const core = @import("core");

/// Base interface for all attachments
pub const IAttachment = blk: {
    const VTableDef = struct {
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Base = core.vtable.VTable(VTableDef);

    break :blk struct {
        base: Base,

        pub const VTable = VTableDef;
        const Self = @This();

        pub fn init(ptr: anytype, vtable: *const VTable) Self {
            return .{ .base = Base.init(ptr, vtable) };
        }

        pub fn deinit(self: Self) void {
            self.base.vtable.deinit(self.base.ptr);
        }
    };
};

/// Type ID for identifying attachment types
const TypeId = u64;

/// Generate a unique type ID for a type at compile time
fn typeId(comptime T: type) TypeId {
    const type_name = @typeName(T);
    return comptime blk: {
        var hash: u64 = 0xcbf29ce484222325;
        for (type_name) |byte| {
            hash ^= byte;
            hash *%= 0x100000001b3;
        }
        break :blk hash;
    };
}

/// Attachment manager - stores one attachment per type
pub const Manager = struct {
    attachments: std.AutoHashMap(TypeId, IAttachment),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .attachments = std.AutoHashMap(TypeId, IAttachment).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
        self.attachments.deinit();
    }

    /// Check if an attachment of type T exists
    pub fn has(self: *const Self, comptime T: type) bool {
        return self.attachments.contains(typeId(T));
    }

    /// Get attachment of type T (returns null if not found)
    pub fn get(self: *const Self, comptime T: type) ?*T {
        const attachment = self.attachments.get(typeId(T)) orelse return null;
        const ptr: *T = @ptrCast(@alignCast(attachment.base.ptr));
        return ptr;
    }

    /// Add an attachment (replaces previous attachment of same type)
    pub fn add(self: *Self, comptime T: type, attachment: IAttachment) !void {
        // Remove old attachment of same type if it exists
        if (self.attachments.fetchRemove(typeId(T))) |kv| {
            kv.value.deinit();
        }

        try self.attachments.put(typeId(T), attachment);
    }

    /// Remove attachment by type
    pub fn removeByType(self: *Self, comptime T: type) void {
        if (self.attachments.fetchRemove(typeId(T))) |kv| {
            kv.value.deinit();
        }
    }

    /// Clear all attachments
    pub fn clear(self: *Self) void {
        var it = self.attachments.valueIterator();
        while (it.next()) |attachment| {
            attachment.deinit();
        }
        self.attachments.clearRetainingCapacity();
    }
};

// Tests
test "Manager - initialization and cleanup" {
    const testing = std.testing;

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    try testing.expectEqual(@as(usize, 0), manager.attachments.count());
}

test "Manager - add and get attachment" {
    const testing = std.testing;

    const TestAttachment = struct {
        value: i32,

        fn deinitImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self;
        }

        const vtable_instance = IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    var test_data = TestAttachment{ .value = 42 };
    const attachment = IAttachment.init(&test_data, &TestAttachment.vtable_instance);

    try manager.add(TestAttachment, attachment);

    try testing.expect(manager.has(TestAttachment));

    const retrieved = manager.get(TestAttachment);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(i32, 42), retrieved.?.value);
}

test "Manager - has returns false for non-existent type" {
    const testing = std.testing;

    const TestAttachment = struct {
        value: i32,
    };

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    try testing.expect(!manager.has(TestAttachment));
}

test "Manager - get returns null for non-existent type" {
    const testing = std.testing;

    const TestAttachment = struct {
        value: i32,
    };

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    const result = manager.get(TestAttachment);
    try testing.expect(result == null);
}

test "Manager - add replaces previous attachment of same type" {
    const testing = std.testing;

    const TestAttachment = struct {
        value: i32,
        deinit_called: *bool,

        fn deinitImpl(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.deinit_called.* = true;
        }

        const vtable_instance = IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    var deinit_flag1 = false;
    var test_data1 = TestAttachment{ .value = 1, .deinit_called = &deinit_flag1 };
    const attachment1 = IAttachment.init(&test_data1, &TestAttachment.vtable_instance);

    try manager.add(TestAttachment, attachment1);
    try testing.expect(!deinit_flag1);

    var deinit_flag2 = false;
    var test_data2 = TestAttachment{ .value = 2, .deinit_called = &deinit_flag2 };
    const attachment2 = IAttachment.init(&test_data2, &TestAttachment.vtable_instance);

    // Adding second attachment should deinit the first
    try manager.add(TestAttachment, attachment2);
    try testing.expect(deinit_flag1); // First was cleaned up
    try testing.expect(!deinit_flag2); // Second is still active

    const retrieved = manager.get(TestAttachment);
    try testing.expectEqual(@as(i32, 2), retrieved.?.value);
}

test "Manager - removeByType" {
    const testing = std.testing;

    const TestAttachment = struct {
        value: i32,

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    var test_data = TestAttachment{ .value = 42 };
    const attachment = IAttachment.init(&test_data, &TestAttachment.vtable_instance);

    try manager.add(TestAttachment, attachment);
    try testing.expect(manager.has(TestAttachment));

    manager.removeByType(TestAttachment);
    try testing.expect(!manager.has(TestAttachment));
}

test "Manager - clear removes all attachments" {
    const testing = std.testing;

    const Attachment1 = struct {
        value: i32,

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    const Attachment2 = struct {
        name: []const u8,

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    var data1 = Attachment1{ .value = 42 };
    var data2 = Attachment2{ .name = "test" };

    try manager.add(Attachment1, IAttachment.init(&data1, &Attachment1.vtable_instance));
    try manager.add(Attachment2, IAttachment.init(&data2, &Attachment2.vtable_instance));

    try testing.expectEqual(@as(usize, 2), manager.attachments.count());

    manager.clear();
    try testing.expectEqual(@as(usize, 0), manager.attachments.count());
}

test "Manager - multiple different attachment types" {
    const testing = std.testing;

    const IntAttachment = struct {
        value: i32,

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    const StringAttachment = struct {
        text: []const u8,

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = IAttachment.VTable{
            .deinit = deinitImpl,
        };
    };

    var manager = Manager.init(testing.allocator);
    defer manager.deinit();

    var int_data = IntAttachment{ .value = 123 };
    var string_data = StringAttachment{ .text = "hello" };

    try manager.add(IntAttachment, IAttachment.init(&int_data, &IntAttachment.vtable_instance));
    try manager.add(StringAttachment, IAttachment.init(&string_data, &StringAttachment.vtable_instance));

    try testing.expect(manager.has(IntAttachment));
    try testing.expect(manager.has(StringAttachment));

    const int_att = manager.get(IntAttachment);
    const string_att = manager.get(StringAttachment);

    try testing.expectEqual(@as(i32, 123), int_att.?.value);
    try testing.expectEqualStrings("hello", string_att.?.text);
}
