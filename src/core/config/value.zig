//! Untyped TOML value tree. Strings and keys are arena-owned.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");

pub const Error = error{
    EmptyPath,
    Type,
    OutOfMemory,
};

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    string: string,
    array: Array,
    table: Table,

    pub fn asBool(self: Value) Error!bool {
        return switch (self) {
            .boolean => |v| v,
            else => error.Type,
        };
    }

    pub fn asInt(self: Value) Error!i64 {
        return switch (self) {
            .integer => |v| v,
            else => error.Type,
        };
    }

    /// Integers coerce to float so `scale = 2` applies to `f32` fields.
    pub fn asFloat(self: Value) Error!f64 {
        return switch (self) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            else => error.Type,
        };
    }

    pub fn asString(self: Value) Error!string {
        return switch (self) {
            .string => |v| v,
            else => error.Type,
        };
    }

    pub fn asTable(self: Value) Error!Table {
        return switch (self) {
            .table => |v| v,
            else => error.Type,
        };
    }

    pub fn asArray(self: Value) Error!Array {
        return switch (self) {
            .array => |v| v,
            else => error.Type,
        };
    }
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
};

pub const Table = struct {
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,

    pub fn get(self: Table, key: string) ?Value {
        return self.map.get(key);
    }

    pub fn getPtr(self: *Table, key: string) ?*Value {
        return self.map.getPtr(key);
    }

    pub fn put(self: *Table, arena: std.mem.Allocator, key: string, value: Value) !void {
        const owned = try arena.dupe(u8, key);
        try self.map.put(arena, owned, value);
    }

    /// Creates `key` as a table if missing. Replaces a non-table value.
    pub fn ensureTable(self: *Table, arena: std.mem.Allocator, key: string) !*Table {
        if (self.map.getPtr(key)) |existing| {
            if (existing.* != .table) existing.* = .{ .table = .{} };
            return &existing.table;
        }
        const owned = try arena.dupe(u8, key);
        try self.map.put(arena, owned, .{ .table = .{} });
        return &self.map.getPtr(owned).?.table;
    }

    /// Appends an empty table to the array at `key`, creating the array if needed.
    pub fn appendTable(self: *Table, arena: std.mem.Allocator, key: string) !*Table {
        const arr = try self.ensureArray(arena, key);
        try arr.items.append(arena, .{ .table = .{} });
        return &arr.items.items[arr.items.items.len - 1].table;
    }

    fn ensureArray(self: *Table, arena: std.mem.Allocator, key: string) !*Array {
        if (self.map.getPtr(key)) |existing| {
            if (existing.* != .array) existing.* = .{ .array = .{} };
            return &existing.array;
        }
        const owned = try arena.dupe(u8, key);
        try self.map.put(arena, owned, .{ .array = .{} });
        return &self.map.getPtr(owned).?.array;
    }
};

/// Arena-backed TOML document. `deinit` frees every key and string.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Table = .{},

    pub fn init(gpa: std.mem.Allocator) Document {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Returns the value at a dotted path, or null if any component is missing.
    pub fn get(self: *const Document, path: []const string) ?Value {
        if (path.len == 0) return .{ .table = self.root };
        var table = self.root;
        for (path[0 .. path.len - 1]) |key| {
            const child = table.get(key) orelse return null;
            table = child.asTable() catch return null;
        }
        return table.get(path[path.len - 1]);
    }

    pub fn getBool(self: *const Document, path: []const string) ?bool {
        return (self.get(path) orelse return null).asBool() catch null;
    }

    pub fn getInt(self: *const Document, path: []const string) ?i64 {
        return (self.get(path) orelse return null).asInt() catch null;
    }

    pub fn getFloat(self: *const Document, path: []const string) ?f64 {
        return (self.get(path) orelse return null).asFloat() catch null;
    }

    pub fn getString(self: *const Document, path: []const string) ?string {
        return (self.get(path) orelse return null).asString() catch null;
    }

    pub fn set(self: *Document, path: []const string, value: Value) !void {
        const table = try self.tableForPath(path);
        try table.put(self.allocator(), path[path.len - 1], value);
    }

    pub fn setBool(self: *Document, path: []const string, value: bool) !void {
        try self.set(path, .{ .boolean = value });
    }

    pub fn setInt(self: *Document, path: []const string, value: i64) !void {
        try self.set(path, .{ .integer = value });
    }

    pub fn setFloat(self: *Document, path: []const string, value: f64) !void {
        try self.set(path, .{ .float = value });
    }

    pub fn setString(self: *Document, path: []const string, value: string) !void {
        const owned = try self.allocator().dupe(u8, value);
        try self.set(path, .{ .string = owned });
    }

    fn tableForPath(self: *Document, path: []const string) !*Table {
        if (path.len == 0) return error.EmptyPath;
        var table = &self.root;
        for (path[0 .. path.len - 1]) |key| {
            table = try table.ensureTable(self.allocator(), key);
        }
        return table;
    }
};

test "document get and set dotted paths" {
    const gpa = testing.allocator;
    var doc = Document.init(gpa);
    defer doc.deinit();

    try doc.setFloat(&.{ "output", "DP-1", "scale" }, 1.5);
    try doc.setString(&.{ "theme", "appearance" }, "dark");
    try doc.setBool(&.{"nested", "flag"}, true);

    try testing.expectEqual(@as(?f64, 1.5), doc.getFloat(&.{ "output", "DP-1", "scale" }));
    try testing.expectEqualStrings("dark", doc.getString(&.{ "theme", "appearance" }).?);
    try testing.expect(doc.getBool(&.{ "nested", "flag" }).?);
    try testing.expectEqual(@as(?f64, null), doc.getFloat(&.{ "output", "eDP-1", "scale" }));
}

test "document empty path set is an error" {
    const gpa = testing.allocator;
    var doc = Document.init(gpa);
    defer doc.deinit();
    try testing.expectError(error.EmptyPath, doc.set(&.{}, .{ .boolean = true }));
}

test "value integer coerces to float" {
    const value: Value = .{ .integer = 2 };
    try testing.expectEqual(@as(f64, 2), try value.asFloat());
    try testing.expectError(error.Type, value.asString());
}
