//! Protocol specification system

const std = @import("std");
const core = @import("core");
const VTable = core.vtable.Interface;
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
pub const Object = struct {
    base: VTable(VTableDef),

    pub const VTableDef = struct {
        object_name: *const fn (ptr: *anyopaque) []const u8,
        /// Client-to-server methods
        c2s: *const fn (ptr: *anyopaque) []const Method,
        /// Server-to-client methods
        s2c: *const fn (ptr: *anyopaque) []const Method,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Self = @This();

    pub fn init(ptr: anytype, vtable: *const VTableDef) Self {
        return .{ .base = VTable(VTableDef).init(ptr, vtable) };
    }

    pub fn objectName(self: Self) []const u8 {
        return self.base.vtable.object_name(self.base.ptr);
    }

    pub fn clientToServer(self: Self) []const Method {
        return self.base.vtable.c2s(self.base.ptr);
    }

    pub fn serverToClient(self: Self) []const Method {
        return self.base.vtable.s2c(self.base.ptr);
    }

    pub fn deinit(self: Self) void {
        self.base.vtable.deinit(self.base.ptr);
    }
};

/// Protocol specification interface
pub const Protocol = struct {
    base: VTable(VTableDef),

    pub const VTableDef = struct {
        spec_name: *const fn (ptr: *anyopaque) []const u8,
        spec_ver: *const fn (ptr: *anyopaque) u32,
        objects: *const fn (ptr: *anyopaque) []const Object,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Self = @This();

    pub fn init(ptr: anytype, vtable: *const VTableDef) Self {
        return .{ .base = VTable(VTableDef).init(ptr, vtable) };
    }

    pub fn specName(self: Self) []const u8 {
        return self.base.vtable.spec_name(self.base.ptr);
    }

    pub fn specVer(self: Self) u32 {
        return self.base.vtable.spec_ver(self.base.ptr);
    }

    pub fn objects(self: Self) []const Object {
        return self.base.vtable.objects(self.base.ptr);
    }

    pub fn deinit(self: Self) void {
        self.base.vtable.deinit(self.base.ptr);
    }

    /// Format as protocol spec string (name@version)
    pub fn formatSpec(self: Self, allocator: std.mem.Allocator) ![]u8 {
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

const testing = core.testing;

// Tests
test "Method - structure" {
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
    var obj = Instance.init(testing.allocator, 1, "test_protocol", 1);
    defer obj.deinit();

    var user_value: u32 = 42;
    obj.setData(&user_value);

    const retrieved_data = obj.getData().?;
    const retrieved_value: *u32 = @ptrCast(@alignCast(retrieved_data));
    try testing.expectEqual(@as(u32, 42), retrieved_value.*);
}

test "Instance - destroy callback" {
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

        const vtable_instance = Object.VTableDef{
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

    const spec = Object.init(&mock, &MockObjectSpec.vtable_instance);

    try testing.expectEqualStrings("TestObject", spec.objectName());
    try testing.expectEqual(@as(usize, 1), spec.clientToServer().len);
    try testing.expectEqual(@as(usize, 0), spec.serverToClient().len);
}

test "Protocol - interface" {
    const MockProtocolSpec = struct {
        name: []const u8,
        version: u32,
        object_specs: []const Object,

        fn specNameFn(ptr: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.name;
        }

        fn specVerFn(ptr: *anyopaque) u32 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.version;
        }

        fn objectsFn(ptr: *anyopaque) []const Object {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.object_specs;
        }

        fn deinitFn(ptr: *anyopaque) void {
            _ = ptr;
        }

        const vtable_instance = Protocol.VTableDef{
            .spec_name = specNameFn,
            .spec_ver = specVerFn,
            .objects = objectsFn,
            .deinit = deinitFn,
        };
    };

    var mock = MockProtocolSpec{
        .name = "test_protocol",
        .version = 1,
        .object_specs = &[_]Object{},
    };

    const spec = Protocol.init(&mock, &MockProtocolSpec.vtable_instance);

    try testing.expectEqualStrings("test_protocol", spec.specName());
    try testing.expectEqual(@as(u32, 1), spec.specVer());

    const formatted = try spec.formatSpec(testing.allocator);
    defer testing.allocator.free(formatted);
    try testing.expectEqualStrings("test_protocol@1", formatted);
}
