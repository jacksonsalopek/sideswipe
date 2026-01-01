//! Generic VTable (virtual table) implementation for interface polymorphism
//! Provides utilities for creating type-erased interfaces similar to C++ virtual classes

const std = @import("std");

/// Generic interface wrapper with vtable pattern
/// 
/// Example usage:
/// ```
/// const IExample = VTable(struct {
///     foo: *const fn(ptr: *anyopaque, x: i32) i32,
///     bar: *const fn(ptr: *anyopaque) void,
/// });
/// ```
pub fn VTable(comptime VTableType: type) type {
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

/// Helper to create a vtable implementation from a concrete type
/// 
/// Example:
/// ```
/// const MyImpl = struct {
///     value: i32,
///     pub fn foo(self: *@This(), x: i32) i32 { return self.value + x; }
///     pub fn bar(self: *@This()) void { }
/// };
/// 
/// const vtable = makeVTable(MyImpl, VTableDef, .{
///     .foo = MyImpl.foo,
///     .bar = MyImpl.bar,
/// });
/// ```
pub fn makeVTable(
    comptime ImplType: type,
    comptime VTableType: type,
    comptime impl: anytype,
) VTableType {
    var result: VTableType = undefined;
    
    inline for (@typeInfo(@TypeOf(impl)).Struct.fields) |field| {
        const wrapper = struct {
            fn wrap(ptr: *anyopaque, args: anytype) @typeInfo(@TypeOf(@field(impl, field.name))).Fn.return_type.? {
                const self: *ImplType = @ptrCast(@alignCast(ptr));
                return @call(.auto, @field(impl, field.name), .{self} ++ args);
            }
        };
        @field(result, field.name) = wrapper.wrap;
    }
    
    return result;
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

    const Base = VTable(VTableDef);

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

/// Type-erased pointer wrapper
pub fn Opaque(comptime T: type) type {
    return struct {
        ptr: *T,

        pub fn init(ptr: *T) @This() {
            return .{ .ptr = ptr };
        }

        pub fn toAnyOpaque(self: @This()) *anyopaque {
            return @ptrCast(self.ptr);
        }

        pub fn fromAnyOpaque(ptr: *anyopaque) @This() {
            return .{ .ptr = @ptrCast(@alignCast(ptr)) };
        }

        pub fn get(self: @This()) *T {
            return self.ptr;
        }
    };
}

// Tests
test "VTable - basic interface creation" {
    const testing = std.testing;

    const TestVTable = struct {
        get_value: *const fn (ptr: *anyopaque) i32,
        set_value: *const fn (ptr: *anyopaque, val: i32) void,
    };

    const ITest = VTable(TestVTable);

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

test "Opaque - type-erased pointer" {
    const testing = std.testing;

    const TestType = struct {
        value: i32,
    };

    var instance = TestType{ .value = 42 };
    const wrapped = Opaque(TestType).init(&instance);

    const any_ptr = wrapped.toAnyOpaque();
    const restored = Opaque(TestType).fromAnyOpaque(any_ptr);

    try testing.expectEqual(@as(i32, 42), restored.get().value);
}

test "Opaque - roundtrip" {
    const testing = std.testing;

    var value: i32 = 123;
    const wrapped = Opaque(i32).init(&value);
    const any_ptr = wrapped.toAnyOpaque();
    const back = Opaque(i32).fromAnyOpaque(any_ptr);

    try testing.expectEqual(@as(i32, 123), back.get().*);
    back.get().* = 456;
    try testing.expectEqual(@as(i32, 456), value);
}
