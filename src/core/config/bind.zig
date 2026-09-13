//! Merge a TOML table into a Zig struct, keeping defaults for missing or bad keys.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");
const value = @import("value.zig");
const parse = @import("parse.zig");

pub const Table = value.Table;
pub const Value = value.Value;
pub const Diagnostics = parse.Diagnostics;

/// Applies known keys from `table` onto `dest`. Unknown keys and bad values
/// increment `diag` and leave the existing field value in place.
pub fn merge(
    comptime T: type,
    dest: *T,
    arena: std.mem.Allocator,
    table: Table,
    diag: *Diagnostics,
) std.mem.Allocator.Error!void {
    try mergeFields(T, dest, arena, table, diag);
    try reportUnknown(T, table, diag);
}

/// Like `merge` but does not flag keys that are not fields of `T`.
pub fn mergeFields(
    comptime T: type,
    dest: *T,
    arena: std.mem.Allocator,
    table: Table,
    diag: *Diagnostics,
) std.mem.Allocator.Error!void {
    inline for (std.meta.fields(T)) |field| {
        if (table.get(field.name)) |found| {
            try applyFound(field.type, &@field(dest, field.name), arena, found, field.name, diag);
        }
    }
}

fn applyFound(
    comptime T: type,
    dest: *T,
    arena: std.mem.Allocator,
    found: Value,
    name: string,
    diag: *Diagnostics,
) std.mem.Allocator.Error!void {
    mergeField(T, dest, arena, found, name, diag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        diag.report(.bad_value, name);
    };
}

fn reportUnknown(comptime T: type, table: Table, diag: *Diagnostics) std.mem.Allocator.Error!void {
    for (table.map.keys()) |key| {
        if (!knownField(T, key)) diag.report(.unknown_key, key);
    }
}

fn knownField(comptime T: type, key: string) bool {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, key)) return true;
    }
    return false;
}

fn mergeField(
    comptime T: type,
    dest: *T,
    arena: std.mem.Allocator,
    found: Value,
    key: string,
    diag: *Diagnostics,
) !void {
    switch (@typeInfo(T)) {
        .optional => |info| return mergeOptional(info.child, dest, arena, found, key, diag),
        .bool => dest.* = try found.asBool(),
        .int => dest.* = try mergeInt(T, found),
        .float => dest.* = @floatCast(try found.asFloat()),
        .@"enum" => dest.* = try mergeEnum(T, found),
        .pointer => |info| return mergePointer(T, info, dest, arena, found, key, diag),
        .@"struct" => return mergeStruct(T, dest, arena, found, key, diag),
        else => return error.Type,
    }
}

fn mergeOptional(
    comptime Child: type,
    dest: *?Child,
    arena: std.mem.Allocator,
    found: Value,
    key: string,
    diag: *Diagnostics,
) !void {
    var inner: Child = if (dest.*) |existing| existing else fallback(Child);
    try mergeField(Child, &inner, arena, found, key, diag);
    dest.* = inner;
}

fn fallback(comptime Child: type) Child {
    return switch (@typeInfo(Child)) {
        .@"struct" => .{},
        .pointer => |info| fallbackPointer(Child, info),
        else => undefined,
    };
}

fn fallbackPointer(comptime Child: type, info: std.builtin.Type.Pointer) Child {
    if (info.size != .slice) return undefined;
    if (info.child == u8) return "";
    return &.{};
}

fn mergeInt(comptime T: type, found: Value) !T {
    const parsed = try found.asInt();
    return std.math.cast(T, parsed) orelse error.Type;
}

fn mergeEnum(comptime T: type, found: Value) !T {
    const text = try found.asString();
    if (@hasDecl(T, "parse")) {
        return T.parse(text) orelse error.Type;
    }
    return std.meta.stringToEnum(T, text) orelse error.Type;
}

fn mergePointer(
    comptime T: type,
    info: std.builtin.Type.Pointer,
    dest: *T,
    arena: std.mem.Allocator,
    found: Value,
    key: string,
    diag: *Diagnostics,
) !void {
    if (info.size != .slice) return error.Type;
    if (info.child == u8) {
        dest.* = try arena.dupe(u8, try found.asString());
        return;
    }
    try mergeSlice(info.child, dest, arena, found, key, diag);
}

fn mergeStruct(
    comptime T: type,
    dest: *T,
    arena: std.mem.Allocator,
    found: Value,
    key: string,
    diag: *Diagnostics,
) !void {
    if (typedValue(T, found)) |parsed| {
        dest.* = parsed;
        return;
    }
    if (@hasDecl(T, "fromValue")) return error.Type;
    _ = key;
    const table = try found.asTable();
    try merge(T, dest, arena, table, diag);
}

fn typedValue(comptime T: type, found: Value) ?T {
    if (!@hasDecl(T, "fromValue")) return null;
    return T.fromValue(found);
}

fn mergeSlice(
    comptime Child: type,
    dest: *[]const Child,
    arena: std.mem.Allocator,
    found: Value,
    key: string,
    diag: *Diagnostics,
) !void {
    const arr = try found.asArray();
    var list: std.ArrayList(Child) = .empty;
    for (arr.items.items) |item| {
        try appendRow(Child, &list, arena, item, key, diag);
    }
    dest.* = list.items;
}

fn appendRow(
    comptime Child: type,
    list: *std.ArrayList(Child),
    arena: std.mem.Allocator,
    item: Value,
    key: string,
    diag: *Diagnostics,
) !void {
    var row: Child = fallback(Child);
    if (@typeInfo(Child) == .@"struct") {
        const table = item.asTable() catch {
            diag.report(.bad_value, key);
            return;
        };
        try merge(Child, &row, arena, table, diag);
        if (skipEmptyApp(Child, row)) return;
        try list.append(arena, row);
        return;
    }
    try mergeField(Child, &row, arena, item, key, diag);
    try list.append(arena, row);
}

fn skipEmptyApp(comptime Child: type, row: Child) bool {
    if (!@hasField(Child, "app_id")) return false;
    return @field(row, "app_id").len == 0;
}

/// Writes struct fields into a table. Null optionals are omitted.
pub fn fromStruct(comptime T: type, arena: std.mem.Allocator, src: T) !Table {
    var table = Table{};
    inline for (std.meta.fields(T)) |field| {
        try putField(field.type, &table, arena, field.name, @field(src, field.name));
    }
    return table;
}

fn putField(
    comptime T: type,
    table: *Table,
    arena: std.mem.Allocator,
    name: string,
    src: T,
) !void {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (src) |inner| try putField(info.child, table, arena, name, inner);
        },
        else => try table.put(arena, name, try toValue(T, arena, src)),
    }
}

fn toValue(comptime T: type, arena: std.mem.Allocator, src: T) !Value {
    if (comptime encodedValue(T)) return src.encode();
    switch (@typeInfo(T)) {
        .bool => return .{ .boolean = src },
        .int => return .{ .integer = @intCast(src) },
        .float => return .{ .float = @floatCast(src) },
        .@"enum" => return .{ .string = enumText(T, src) },
        .pointer => |info| return toPointerValue(T, info, arena, src),
        .@"struct" => return .{ .table = try fromStruct(T, arena, src) },
        else => return error.Type,
    }
}

fn encodedValue(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "fromValue") and @hasDecl(T, "encode");
}

fn enumText(comptime T: type, src: T) string {
    if (@hasDecl(T, "toml")) return src.toml();
    return @tagName(src);
}

fn toPointerValue(
    comptime T: type,
    info: std.builtin.Type.Pointer,
    arena: std.mem.Allocator,
    src: T,
) !Value {
    if (info.size != .slice) return error.Type;
    if (info.child == u8) {
        const owned = try arena.dupe(u8, src);
        return .{ .string = owned };
    }
    var arr = value.Array{};
    for (src) |item| {
        try arr.items.append(arena, try toValue(info.child, arena, item));
    }
    return .{ .array = arr };
}

const Sample = struct {
    name: string = "",
    count: u32 = 3,
    ratio: f32 = 1,
    on: bool = false,
    kind: enum { a, b } = .a,
    extra: ?string = null,
};

test "merge keeps defaults for missing and bad keys" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var table = Table{};
    try table.put(alloc, "name", .{ .string = "ok" });
    try table.put(alloc, "count", .{ .string = "nope" });
    try table.put(alloc, "ratio", .{ .integer = 2 });
    try table.put(alloc, "on", .{ .boolean = true });
    try table.put(alloc, "kind", .{ .string = "b" });
    try table.put(alloc, "unknown", .{ .integer = 1 });

    var dest = Sample{};
    var diag = Diagnostics{};
    try merge(Sample, &dest, alloc, table, &diag);

    try testing.expectEqualStrings("ok", dest.name);
    try testing.expectEqual(@as(u32, 3), dest.count);
    try testing.expectEqual(@as(f32, 2), dest.ratio);
    try testing.expect(dest.on);
    try testing.expectEqual(.b, dest.kind);
    try testing.expectEqual(@as(?string, null), dest.extra);
    try testing.expectEqual(@as(usize, 2), diag.count);
}

test "fromStruct omits null optionals" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const table = try fromStruct(Sample, arena.allocator(), .{ .name = "x", .extra = null });
    try testing.expect(table.get("name") != null);
    try testing.expectEqual(@as(?Value, null), table.get("extra"));
}
