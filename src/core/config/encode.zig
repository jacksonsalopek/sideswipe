//! Canonical TOML encoder. Last writer wins; comments are not preserved.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");
const value = @import("value.zig");
const parse = @import("parse.zig");

pub const Table = value.Table;
pub const Value = value.Value;
pub const Array = value.Array;

const EncodeError = std.mem.Allocator.Error || error{PathTooDeep};

/// Encodes `table` as UTF-8 TOML. Caller owns the returned slice.
pub fn encode(gpa: std.mem.Allocator, table: Table) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeTable(&out, gpa, table, &.{});
    return out.toOwnedSlice(gpa);
}

fn writeTable(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    table: Table,
    path: []const string,
) EncodeError!void {
    if (hasNonTable(table)) {
        if (path.len > 0) try writeHeader(out, gpa, path, false);
        try writeNonTables(out, gpa, table);
        try out.append(gpa, '\n');
    }
    try writeChildTables(out, gpa, table, path);
    try writeArrayTables(out, gpa, table, path);
}

fn writeChildTables(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    table: Table,
    path: []const string,
) EncodeError!void {
    var child: [16]string = undefined;
    if (path.len + 1 > child.len) return error.PathTooDeep;
    @memcpy(child[0..path.len], path);
    for (table.map.keys(), table.map.values()) |key, val| {
        if (val != .table) continue;
        child[path.len] = key;
        try writeTable(out, gpa, val.table, child[0 .. path.len + 1]);
    }
}

fn writeArrayTables(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    table: Table,
    path: []const string,
) EncodeError!void {
    var child: [16]string = undefined;
    if (path.len + 1 > child.len) return error.PathTooDeep;
    @memcpy(child[0..path.len], path);
    for (table.map.keys(), table.map.values()) |key, val| {
        if (val != .array or !isTableArray(val.array)) continue;
        child[path.len] = key;
        try writeTableArray(out, gpa, val.array, child[0 .. path.len + 1]);
    }
}

fn writeTableArray(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    arr: Array,
    path: []const string,
) EncodeError!void {
    for (arr.items.items) |item| {
        std.debug.assert(item == .table);
        try writeHeader(out, gpa, path, true);
        try writeNonTables(out, gpa, item.table);
        try out.append(gpa, '\n');
        try writeChildTables(out, gpa, item.table, path);
        try writeArrayTables(out, gpa, item.table, path);
    }
}

fn writeNonTables(out: *std.ArrayList(u8), gpa: std.mem.Allocator, table: Table) EncodeError!void {
    for (table.map.keys(), table.map.values()) |key, val| {
        if (skipAsSection(val)) continue;
        try writeKey(out, gpa, key);
        try out.appendSlice(gpa, " = ");
        try writeValue(out, gpa, val);
        try out.append(gpa, '\n');
    }
}

fn skipAsSection(val: Value) bool {
    return switch (val) {
        .table => true,
        .array => |arr| isTableArray(arr),
        else => false,
    };
}

fn hasNonTable(table: Table) bool {
    for (table.map.values()) |val| {
        if (!skipAsSection(val)) return true;
    }
    return false;
}

fn isTableArray(arr: Array) bool {
    if (arr.items.items.len == 0) return false;
    for (arr.items.items) |item| {
        if (item != .table) return false;
    }
    return true;
}

fn writeHeader(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    path: []const string,
    array: bool,
) EncodeError!void {
    try out.appendSlice(gpa, if (array) "[[" else "[");
    for (path, 0..) |key, i| {
        if (i != 0) try out.append(gpa, '.');
        try writeKey(out, gpa, key);
    }
    try out.appendSlice(gpa, if (array) "]]\n" else "]\n");
}

fn writeKey(out: *std.ArrayList(u8), gpa: std.mem.Allocator, key: string) EncodeError!void {
    if (isBare(key)) {
        try out.appendSlice(gpa, key);
        return;
    }
    try writeString(out, gpa, key);
}

fn writeValue(out: *std.ArrayList(u8), gpa: std.mem.Allocator, val: Value) EncodeError!void {
    switch (val) {
        .boolean => |v| try out.appendSlice(gpa, if (v) "true" else "false"),
        .integer => |v| try out.print(gpa, "{d}", .{v}),
        .float => |v| try writeFloat(out, gpa, v),
        .string => |v| try writeString(out, gpa, v),
        .array => |arr| try writeInlineArray(out, gpa, arr),
        .table => |table| try writeInlineTable(out, gpa, table),
    }
}

fn writeFloat(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: f64) EncodeError!void {
    if (std.math.isNan(v)) {
        try out.appendSlice(gpa, "nan");
        return;
    }
    if (!std.math.isFinite(v)) {
        try out.appendSlice(gpa, if (v > 0) "inf" else "-inf");
        return;
    }
    try out.print(gpa, "{d}", .{v});
}

fn writeString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: string) EncodeError!void {
    try out.append(gpa, '"');
    for (text) |char| {
        try appendEscaped(out, gpa, char);
    }
    try out.append(gpa, '"');
}

fn appendEscaped(out: *std.ArrayList(u8), gpa: std.mem.Allocator, char: u8) EncodeError!void {
    switch (char) {
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        else => try out.append(gpa, char),
    }
}

fn writeInlineArray(out: *std.ArrayList(u8), gpa: std.mem.Allocator, arr: Array) EncodeError!void {
    try out.append(gpa, '[');
    for (arr.items.items, 0..) |item, i| {
        if (i != 0) try out.appendSlice(gpa, ", ");
        try writeValue(out, gpa, item);
    }
    try out.append(gpa, ']');
}

fn writeInlineTable(out: *std.ArrayList(u8), gpa: std.mem.Allocator, table: Table) EncodeError!void {
    try out.appendSlice(gpa, "{ ");
    for (table.map.keys(), table.map.values(), 0..) |key, val, i| {
        if (i != 0) try out.appendSlice(gpa, ", ");
        try writeKey(out, gpa, key);
        try out.appendSlice(gpa, " = ");
        try writeValue(out, gpa, val);
    }
    try out.appendSlice(gpa, " }");
}

fn isBare(key: string) bool {
    if (key.len == 0) return false;
    for (key) |char| {
        const ok = (char >= '0' and char <= '9') or
            (char >= 'A' and char <= 'Z') or
            (char >= 'a' and char <= 'z') or
            char == '_' or
            char == '-';
        if (!ok) return false;
    }
    return true;
}

test "encode round-trips named output and window rules" {
    const gpa = testing.allocator;
    var diag = parse.Diagnostics{};
    var doc = try parse.parse(gpa,
        \\[theme]
        \\appearance = "dark"
        \\
        \\[output.DP-1]
        \\scale = 1.5
        \\
        \\[[window_rules]]
        \\app_id = "foot"
        \\ssd = true
    , &diag);
    defer doc.deinit();

    const text = try encode(gpa, doc.root);
    defer gpa.free(text);

    var again = try parse.parse(gpa, text, &diag);
    defer again.deinit();
    try testing.expectEqualStrings("dark", again.getString(&.{ "theme", "appearance" }).?);
    try testing.expectEqual(@as(?f64, 1.5), again.getFloat(&.{ "output", "DP-1", "scale" }));
    try testing.expectEqualStrings("foot", again.get(&.{"window_rules"}).?.array.items.items[0].table.get("app_id").?.string);
}

test "encode quotes keys that are not bare" {
    const gpa = testing.allocator;
    var doc = value.Document.init(gpa);
    defer doc.deinit();
    try doc.setInt(&.{ "weird key", "x" }, 1);
    const text = try encode(gpa, doc.root);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"weird key\"") != null);
}
