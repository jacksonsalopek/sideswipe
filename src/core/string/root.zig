const std = @import("std");

/// UTF-8 string slice (immutable)
pub const string = []const u8;

/// Mutable UTF-8 string slice
pub const string_mut = []u8;

/// Null-terminated C string
pub const c_string = [*:0]const u8;

/// Owned string that manages its own memory
pub const String = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .data = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn initFromSlice(allocator: std.mem.Allocator, str: string) !Self {
        var result = Self.init(allocator);
        try result.data.appendSlice(allocator, str);
        return result;
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }

    pub fn append(self: *Self, str: string) !void {
        try self.data.appendSlice(self.allocator, str);
    }

    pub fn clear(self: *Self) void {
        self.data.clearRetainingCapacity();
    }

    pub fn toSlice(self: Self) string {
        return self.data.items;
    }

    pub fn toOwned(self: *Self) !string {
        return try self.data.toOwnedSlice(self.allocator);
    }

    pub fn len(self: Self) usize {
        return self.data.items.len;
    }
};

/// Check if a string is empty
pub fn isEmpty(str: string) bool {
    return str.len == 0;
}

/// Check if string starts with prefix
pub fn startsWith(str: string, prefix: string) bool {
    return std.mem.startsWith(u8, str, prefix);
}

/// Check if string ends with suffix
pub fn endsWith(str: string, suffix: string) bool {
    return std.mem.endsWith(u8, str, suffix);
}

/// Find index of substring
pub fn indexOf(str: string, needle: string) ?usize {
    return std.mem.indexOf(u8, str, needle);
}

/// Find last index of substring
pub fn lastIndexOf(str: string, needle: string) ?usize {
    return std.mem.lastIndexOf(u8, str, needle);
}

/// Check if string contains substring
pub fn contains(str: string, needle: string) bool {
    return indexOf(str, needle) != null;
}

/// Compare two strings for equality
pub fn equals(a: string, b: string) bool {
    return std.mem.eql(u8, a, b);
}

/// Trim whitespace from both ends
pub fn trim(str: string) string {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

/// Trim whitespace from left
pub fn trimLeft(str: string) string {
    return std.mem.trimLeft(u8, str, &std.ascii.whitespace);
}

/// Trim whitespace from right
pub fn trimRight(str: string) string {
    return std.mem.trimRight(u8, str, &std.ascii.whitespace);
}

/// Duplicate a string (caller owns returned memory)
pub fn duplicate(allocator: std.mem.Allocator, str: string) !string {
    return try allocator.dupe(u8, str);
}

/// Create a null-terminated duplicate (caller owns returned memory)
pub fn duplicateZ(allocator: std.mem.Allocator, str: string) ![:0]const u8 {
    return try allocator.dupeZ(u8, str);
}

/// Split string by delimiter
pub const SplitIterator = struct {
    buffer: string,
    delimiter: string,
    index: usize = 0,

    pub fn next(self: *SplitIterator) ?string {
        if (self.index >= self.buffer.len) return null;

        const start = self.index;
        const delimiter_index = std.mem.indexOfPos(u8, self.buffer, start, self.delimiter);

        if (delimiter_index) |end| {
            self.index = end + self.delimiter.len;
            return self.buffer[start..end];
        } else {
            self.index = self.buffer.len;
            return self.buffer[start..];
        }
    }

    pub fn rest(self: *SplitIterator) string {
        const result = self.buffer[self.index..];
        self.index = self.buffer.len;
        return result;
    }
};

pub fn split(str: string, delimiter: string) SplitIterator {
    return .{ .buffer = str, .delimiter = delimiter };
}

/// Join strings with separator (caller owns returned memory)
pub fn join(allocator: std.mem.Allocator, strings: []const string, separator: string) !string {
    if (strings.len == 0) return try allocator.dupe(u8, "");
    if (strings.len == 1) return try allocator.dupe(u8, strings[0]);

    var total_len: usize = 0;
    for (strings) |s| {
        total_len += s.len;
    }
    total_len += separator.len * (strings.len - 1);

    var result = try std.ArrayList(u8).initCapacity(allocator, total_len);
    errdefer result.deinit(allocator);

    for (strings, 0..) |s, i| {
        if (i > 0) {
            try result.appendSlice(allocator, separator);
        }
        try result.appendSlice(allocator, s);
    }

    return try result.toOwnedSlice(allocator);
}

/// Replace all occurrences of 'from' with 'to' (caller owns returned memory)
pub fn replace(allocator: std.mem.Allocator, str: string, from: string, to: string) !string {
    if (from.len == 0) return try allocator.dupe(u8, str);

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < str.len) {
        if (std.mem.indexOfPos(u8, str, pos, from)) |found| {
            try result.appendSlice(allocator, str[pos..found]);
            try result.appendSlice(allocator, to);
            pos = found + from.len;
        } else {
            try result.appendSlice(allocator, str[pos..]);
            break;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Convert string to uppercase (caller owns returned memory)
pub fn toUpper(allocator: std.mem.Allocator, str: string) !string {
    const result = try allocator.alloc(u8, str.len);
    _ = std.ascii.upperString(result, str);
    return result;
}

/// Convert string to lowercase (caller owns returned memory)
pub fn toLower(allocator: std.mem.Allocator, str: string) !string {
    const result = try allocator.alloc(u8, str.len);
    _ = std.ascii.lowerString(result, str);
    return result;
}

/// Check if string is a valid number
pub fn isNumber(str: string, allow_float: bool) bool {
    if (str.len == 0) return false;

    var decimal_parsed = false;

    for (str, 0..) |c, i| {
        // Allow '-' only at the beginning
        if (i == 0 and c == '-') {
            continue;
        }

        if (!std.ascii.isDigit(c)) {
            if (!allow_float) return false;
            if (c != '.') return false;
            if (i == 0) return false;
            if (decimal_parsed) return false;

            decimal_parsed = true;
            continue;
        }
    }

    return std.ascii.isDigit(str[str.len - 1]);
}

/// Replace occurrences in-place within a mutable string buffer
/// Returns a new string with replacements (caller owns memory)
pub fn replaceInString(allocator: std.mem.Allocator, str: string, from: string, to: string) !string {
    if (str.len == 0 or from.len == 0) return try allocator.dupe(u8, str);

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < str.len) {
        if (std.mem.indexOfPos(u8, str, pos, from)) |found| {
            try result.appendSlice(allocator, str[pos..found]);
            try result.appendSlice(allocator, to);
            pos = found + from.len;
        } else {
            try result.appendSlice(allocator, str[pos..]);
            break;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Check if a string represents a truthy value
/// Accepts: "1", "true", "yes", "on" (case-insensitive)
/// Returns false for: "0", "false", "no", "off", or anything else
pub fn truthy(str: string) bool {
    if (str.len == 0) return false;

    if (std.mem.eql(u8, str, "1")) return true;
    if (std.mem.eql(u8, str, "0")) return false;

    // Create a lowercase buffer for comparison
    var lower_buf: [32]u8 = undefined;
    if (str.len > lower_buf.len) return false;

    const lower = std.ascii.lowerString(&lower_buf, str);

    return std.mem.startsWith(u8, lower, "true") or
        std.mem.startsWith(u8, lower, "yes") or
        std.mem.startsWith(u8, lower, "on");
}

test "String - init and append" {
    var str_obj = String.init(std.testing.allocator);
    defer str_obj.deinit();

    try str_obj.append("Hello");
    try str_obj.append(", ");
    try str_obj.append("World!");

    try std.testing.expectEqualStrings("Hello, World!", str_obj.toSlice());
}

test "String - initFromSlice" {
    var str_obj = try String.initFromSlice(std.testing.allocator, "Test");
    defer str_obj.deinit();

    try std.testing.expectEqualStrings("Test", str_obj.toSlice());
    try std.testing.expectEqual(@as(usize, 4), str_obj.len());
}

test "isEmpty" {
    try std.testing.expect(isEmpty(""));
    try std.testing.expect(!isEmpty("hello"));
}

test "startsWith and endsWith" {
    const str = "Hello, World!";
    try std.testing.expect(startsWith(str, "Hello"));
    try std.testing.expect(endsWith(str, "World!"));
    try std.testing.expect(!startsWith(str, "World"));
}

test "contains and indexOf" {
    const str = "Hello, World!";
    try std.testing.expect(contains(str, "World"));
    try std.testing.expect(!contains(str, "xyz"));
    try std.testing.expectEqual(@as(?usize, 7), indexOf(str, "World"));
}

test "trim" {
    const str = "  Hello, World!  ";
    try std.testing.expectEqualStrings("Hello, World!", trim(str));
}

test "split" {
    const str = "one,two,three";
    var iter = split(str, ",");

    try std.testing.expectEqualStrings("one", iter.next().?);
    try std.testing.expectEqualStrings("two", iter.next().?);
    try std.testing.expectEqualStrings("three", iter.next().?);
    try std.testing.expect(iter.next() == null);
}

test "join" {
    const strings = [_]string{ "one", "two", "three" };
    const result = try join(std.testing.allocator, &strings, ", ");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("one, two, three", result);
}

test "replace" {
    const str = "Hello World World";
    const result = try replace(std.testing.allocator, str, "World", "Zig");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("Hello Zig Zig", result);
}

test "toUpper and toLower" {
    const upper = try toUpper(std.testing.allocator, "hello");
    defer std.testing.allocator.free(upper);
    try std.testing.expectEqualStrings("HELLO", upper);

    const lower = try toLower(std.testing.allocator, "WORLD");
    defer std.testing.allocator.free(lower);
    try std.testing.expectEqualStrings("world", lower);
}

test "isNumber - integers" {
    try std.testing.expect(isNumber("123", false));
    try std.testing.expect(isNumber("-456", false));
    try std.testing.expect(!isNumber("12.34", false));
    try std.testing.expect(!isNumber("abc", false));
    try std.testing.expect(!isNumber("", false));
    try std.testing.expect(!isNumber("12a", false));
}

test "isNumber - floats" {
    try std.testing.expect(isNumber("123.456", true));
    try std.testing.expect(isNumber("-789.123", true));
    try std.testing.expect(isNumber("123", true));
    try std.testing.expect(!isNumber(".123", true));
    try std.testing.expect(!isNumber("12.34.56", true));
    try std.testing.expect(!isNumber("12.", true));
}

test "replaceInString" {
    const result = try replaceInString(std.testing.allocator, "Hello World World", "World", "Zig");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello Zig Zig", result);

    const empty = try replaceInString(std.testing.allocator, "", "World", "Zig");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "truthy" {
    try std.testing.expect(truthy("1"));
    try std.testing.expect(truthy("true"));
    try std.testing.expect(truthy("True"));
    try std.testing.expect(truthy("TRUE"));
    try std.testing.expect(truthy("yes"));
    try std.testing.expect(truthy("Yes"));
    try std.testing.expect(truthy("on"));
    try std.testing.expect(truthy("ON"));

    try std.testing.expect(!truthy("0"));
    try std.testing.expect(!truthy("false"));
    try std.testing.expect(!truthy("no"));
    try std.testing.expect(!truthy("off"));
    try std.testing.expect(!truthy(""));
    try std.testing.expect(!truthy("random"));
}
