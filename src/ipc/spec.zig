//! Protocol specification system

const std = @import("std");
const message = @import("message.zig");
const Magic = message.Magic;

/// Method specification
pub const Method = struct {
    idx: u32 = 0,
    params: []const Magic,
    returns_type: []const u8 = "",
    since: u32 = 1,
};

/// Object specification interface
pub const ObjectSpec = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        object_name: *const fn (ptr: *anyopaque) []const u8,
        /// Client-to-server methods
        c2s: *const fn (ptr: *anyopaque) []const Method,
        /// Server-to-client methods
        s2c: *const fn (ptr: *anyopaque) []const Method,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn objectName(self: ObjectSpec) []const u8 {
        return self.vtable.object_name(self.ptr);
    }

    pub fn clientToServer(self: ObjectSpec) []const Method {
        return self.vtable.c2s(self.ptr);
    }

    pub fn serverToClient(self: ObjectSpec) []const Method {
        return self.vtable.s2c(self.ptr);
    }

    pub fn deinit(self: ObjectSpec) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Protocol specification interface
pub const Protocol = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        spec_name: *const fn (ptr: *anyopaque) []const u8,
        spec_ver: *const fn (ptr: *anyopaque) u32,
        objects: *const fn (ptr: *anyopaque) []const ObjectSpec,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn specName(self: Protocol) []const u8 {
        return self.vtable.spec_name(self.ptr);
    }

    pub fn specVer(self: Protocol) u32 {
        return self.vtable.spec_ver(self.ptr);
    }

    pub fn objects(self: Protocol) []const ObjectSpec {
        return self.vtable.objects(self.ptr);
    }

    pub fn deinit(self: Protocol) void {
        self.vtable.deinit(self.ptr);
    }

    /// Format as protocol spec string (name@version)
    pub fn formatSpec(self: Protocol, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s}@{d}", .{ self.specName(), self.specVer() });
    }
};

/// Instance with user data and lifecycle management
pub const Instance = struct {
    id: u32,
    protocol_name: []const u8,
    version: u32,
    user_data: ?*anyopaque = null,
    on_destroy: ?*const fn (*anyopaque) void = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: u32, protocol_name: []const u8, version: u32) Self {
        return .{
            .id = id,
            .protocol_name = protocol_name,
            .version = version,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.on_destroy) |destroy_fn| {
            if (self.user_data) |data| {
                destroy_fn(data);
            }
        }
    }

    /// Set user data for this object
    pub fn setData(self: *Self, data: *anyopaque) void {
        self.user_data = data;
    }

    /// Get user data for this object
    pub fn getData(self: *const Self) ?*anyopaque {
        return self.user_data;
    }

    /// Set destroy callback
    pub fn setOnDestroy(self: *Self, callback: *const fn (*anyopaque) void) void {
        self.on_destroy = callback;
    }
};

// Tests
test "Method - structure" {
    const testing = std.testing;

    const method = Method{
        .idx = 0,
        .params = &[_]Magic{ .type_uint, .type_varchar },
        .returns_type = "Result",
        .since = 1,
    };

    try testing.expectEqual(@as(u32, 0), method.idx);
    try testing.expectEqual(@as(usize, 2), method.params.len);
    try testing.expectEqualStrings("Result", method.returns_type);
}

test "Instance - user data management" {
    const testing = std.testing;

    var obj = Instance.init(testing.allocator, 1, "test_protocol", 1);
    defer obj.deinit();

    var user_value: u32 = 42;
    obj.setData(&user_value);

    const retrieved_data = obj.getData().?;
    const retrieved_value: *u32 = @ptrCast(@alignCast(retrieved_data));
    try testing.expectEqual(@as(u32, 42), retrieved_value.*);
}

test "Instance - destroy callback" {
    const testing = std.testing;

    const State = struct {
        var destroyed: bool = false;

        fn destroyCallback(data: *anyopaque) void {
            _ = data;
            destroyed = true;
        }
    };
    State.destroyed = false;

    var obj = Instance.init(testing.allocator, 1, "test", 1);
    
    var dummy_data: u32 = 0;
    obj.setData(&dummy_data);
    obj.setOnDestroy(State.destroyCallback);
    
    obj.deinit();

    try testing.expect(State.destroyed);
}

test "ObjectSpec - interface" {
    const testing = std.testing;

    const MockObjectSpec = struct {
        name: []const u8,
        c2s_methods: []const Method,
        s2c_methods: []const Method,

        fn objectNameFn(ptr: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn c2sFn(ptr: *anyopaque) []const Method {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.c2s_methods;
        }

        fn s2cFn(ptr: *anyopaque) []const Method {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.s2c_methods;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = ObjectSpec.VTable{
            .object_name = objectNameFn,
            .c2s = c2sFn,
            .s2c = s2cFn,
            .deinit = deinitFn,
        };
    };

    const methods = [_]Method{.{
        .idx = 0,
        .params = &[_]Magic{.type_uint},
        .returns_type = "",
        .since = 1,
    }};

    var mock = MockObjectSpec{
        .name = "TestObject",
        .c2s_methods = &methods,
        .s2c_methods = &[_]Method{},
    };

    const spec = ObjectSpec{
        .ptr = &mock,
        .vtable = &MockObjectSpec.vtable_instance,
    };

    try testing.expectEqualStrings("TestObject", spec.objectName());
    try testing.expectEqual(@as(usize, 1), spec.clientToServer().len);
    try testing.expectEqual(@as(usize, 0), spec.serverToClient().len);
}

test "Protocol - interface" {
    const testing = std.testing;

    const MockProtocolSpec = struct {
        name: []const u8,
        version: u32,
        object_specs: []const ObjectSpec,

        fn specNameFn(ptr: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn specVerFn(ptr: *anyopaque) u32 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.version;
        }

        fn objectsFn(ptr: *anyopaque) []const ObjectSpec {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.object_specs;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = Protocol.VTable{
            .spec_name = specNameFn,
            .spec_ver = specVerFn,
            .objects = objectsFn,
            .deinit = deinitFn,
        };
    };

    var mock = MockProtocolSpec{
        .name = "test_protocol",
        .version = 1,
        .object_specs = &[_]ObjectSpec{},
    };

    const spec = Protocol{
        .ptr = &mock,
        .vtable = &MockProtocolSpec.vtable_instance,
    };

    try testing.expectEqualStrings("test_protocol", spec.specName());
    try testing.expectEqual(@as(u32, 1), spec.specVer());

    const formatted = try spec.formatSpec(testing.allocator);
    defer testing.allocator.free(formatted);
    try testing.expectEqualStrings("test_protocol@1", formatted);
}
