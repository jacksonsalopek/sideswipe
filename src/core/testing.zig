//! Testing utilities that extend std.testing with additional assertions

const std = @import("std");

// Re-export commonly used std.testing functions for convenience
pub const expect = std.testing.expect;
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualStrings = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;
pub const expectError = std.testing.expectError;
pub const expectApproxEqAbs = std.testing.expectApproxEqAbs;
pub const allocator = std.testing.allocator;

/// Assert that a value is null
pub fn expectNull(actual: anytype) !void {
    const T = @TypeOf(actual);
    const type_info = @typeInfo(T);

    if (type_info != .optional) {
        @compileError("expectNull requires an optional type, got " ++ @typeName(T));
    }

    if (actual != null) {
        return error.TestExpectedNull;
    }
}

/// Assert that a value is not null
pub fn expectNotNull(actual: anytype) !void {
    const T = @TypeOf(actual);
    const type_info = @typeInfo(T);

    if (type_info != .optional) {
        @compileError("expectNotNull requires an optional type, got " ++ @typeName(T));
    }

    if (actual == null) {
        return error.TestExpectedNotNull;
    }
}

/// Assert that a boolean value is false (inverse of expect)
pub fn expectFalse(actual: bool) !void {
    if (actual) {
        return error.TestExpectedFalse;
    }
}

/// Assert that two values are not equal (inverse of expectEqual)
pub fn expectNotEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    if (std.meta.eql(expected, actual)) {
        return error.TestExpectedNotEqual;
    }
}

test "expectNull - passes with null" {
    const value: ?u32 = null;
    try expectNull(value);
}

test "expectNull - fails with non-null" {
    const value: ?u32 = 42;
    try std.testing.expectError(error.TestExpectedNull, expectNull(value));
}

test "expectNotNull - passes with non-null" {
    const value: ?u32 = 42;
    try expectNotNull(value);
}

test "expectNotNull - fails with null" {
    const value: ?u32 = null;
    try std.testing.expectError(error.TestExpectedNotNull, expectNotNull(value));
}

test "expectFalse - passes with false" {
    try expectFalse(false);
}

test "expectFalse - fails with true" {
    try std.testing.expectError(error.TestExpectedFalse, expectFalse(true));
}

test "expectNotEqual - passes with different values" {
    try expectNotEqual(@as(u32, 42), @as(u32, 43));
    try expectNotEqual("hello", "world");
}

test "expectNotEqual - fails with equal values" {
    try std.testing.expectError(error.TestExpectedNotEqual, expectNotEqual(@as(u32, 42), @as(u32, 42)));
    try std.testing.expectError(error.TestExpectedNotEqual, expectNotEqual("hello", "hello"));
}
