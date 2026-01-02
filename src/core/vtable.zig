//! Generic VTable (virtual table) implementation for interface polymorphism
//! Provides utilities for creating type-erased interfaces similar to C++ virtual classes

const std = @import("std");

/// Generic interface wrapper with vtable pattern
///
/// Example usage:
/// ```
/// const IExample = Interface(struct {
///     foo: *const fn(ptr: *anyopaque, x: i32) i32,
///     bar: *const fn(ptr: *anyopaque) void,
/// });
/// ```
pub fn Interface(comptime VTableType: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTableType,

        const Self = @This();

        /// Create an interface from a concrete implementation
        pub fn init(ptr: anytype, vtable: *const VTableType) Self {
            return .{
                .ptr = ptr,
                .vtable = vtable,
            };
        }
    };
}

/// Create a common device interface with standard get_libinput_handle, get_name, and deinit methods
/// This is useful for input device interfaces that share the same basic structure
pub fn DeviceInterface(comptime name: []const u8) type {
    _ = name; // For future use in error messages

    const VTableDef = struct {
        get_libinput_handle: *const fn (ptr: *anyopaque) ?*anyopaque,
        get_name: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Base = Interface(VTableDef);

    return struct {
        base: Base,

        const Self = @This();
        pub const VTable = VTableDef;

        pub fn init(ptr: anytype, vtable: *const VTableDef) Self {
            return .{ .base = Base.init(ptr, vtable) };
        }

        pub fn getLibinputHandle(self: Self) ?*anyopaque {
            return self.base.vtable.get_libinput_handle(self.base.ptr);
        }

        pub fn getName(self: Self) []const u8 {
            return self.base.vtable.get_name(self.base.ptr);
        }

        pub fn deinit(self: Self) void {
            self.base.vtable.deinit(self.base.ptr);
        }
    };
}

// Tests
test "Interface - basic interface creation" {
    const testing = std.testing;

    const TestVTable = struct {
        get_value: *const fn (ptr: *anyopaque) i32,
        set_value: *const fn (ptr: *anyopaque, val: i32) void,
    };

    const ITest = Interface(TestVTable);

    const TestImpl = struct {
        value: i32 = 0,

        fn getValue(ptr: *anyopaque) i32 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.value;
        }

        fn setValue(ptr: *anyopaque, val: i32) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value = val;
        }
    };

    const vtable = TestVTable{
        .get_value = TestImpl.getValue,
        .set_value = TestImpl.setValue,
    };

    var impl = TestImpl{ .value = 42 };
    const interface = ITest.init(&impl, &vtable);

    const result = interface.vtable.get_value(interface.ptr);
    try testing.expectEqual(@as(i32, 42), result);

    interface.vtable.set_value(interface.ptr, 100);
    try testing.expectEqual(@as(i32, 100), impl.value);
}
