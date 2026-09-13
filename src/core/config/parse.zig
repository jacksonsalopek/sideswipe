//! Best-effort TOML parser. Invalid lines are skipped; only OOM fails.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");
const value = @import("value.zig");

pub const Document = value.Document;
pub const Table = value.Table;
pub const Value = value.Value;

pub const Kind = enum { unknown_key, bad_value, syntax };

pub const Diagnostics = struct {
    log: bool = false,
    count: usize = 0,

    pub fn report(self: *Diagnostics, kind: Kind, context: string) void {
        self.count += 1;
        if (self.log) std.log.warn("config: {s}: {s}", .{ @tagName(kind), context });
    }
};

const ParseFail = error{ Invalid, OutOfMemory };

/// Parses `source` into an arena-backed document. Syntax errors increment `diag`
/// and skip the offending line.
pub fn parse(gpa: std.mem.Allocator, source: string, diag: *Diagnostics) std.mem.Allocator.Error!Document {
    var doc = Document.init(gpa);
    errdefer doc.deinit();
    var parser = Parser{
        .arena = doc.allocator(),
        .src = source,
        .root = &doc.root,
        .current = &doc.root,
        .diag = diag,
    };
    try parser.run();
    return doc;
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: string,
    pos: usize = 0,
    root: *Table,
    current: *Table,
    diag: *Diagnostics,

    fn run(self: *Parser) std.mem.Allocator.Error!void {
        while (!self.eof()) {
            try self.line();
        }
    }

    fn line(self: *Parser) std.mem.Allocator.Error!void {
        self.skipSpace();
        if (self.eof() or self.peek() == '\n' or self.peek() == '\r' or self.peek() == '#') {
            self.skipLine();
            return;
        }
        if (self.peek() == '[') {
            self.header() catch |err| return self.failLine(err, "table header");
            return;
        }
        self.assignment() catch |err| return self.failLine(err, "key/value");
    }

    fn failLine(self: *Parser, err: ParseFail, context: string) std.mem.Allocator.Error!void {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        self.diag.report(.syntax, context);
        self.skipLine();
    }

    fn header(self: *Parser) ParseFail!void {
        std.debug.assert(self.peek() == '[');
        self.pos += 1;
        const array_of_tables = self.peek() == '[';
        if (array_of_tables) self.pos += 1;
        self.skipSpace();

        var path_buf: [8]string = undefined;
        const path = try self.keyPath(&path_buf);
        self.skipSpace();
        if (array_of_tables) {
            try self.expect(']');
        }
        try self.expect(']');
        self.finishLine();
        try self.select(path, array_of_tables);
    }

    fn assignment(self: *Parser) ParseFail!void {
        var path_buf: [8]string = undefined;
        const path = try self.keyPath(&path_buf);
        self.skipSpace();
        try self.expect('=');
        self.skipSpace();
        const parsed = try self.parseValue();
        self.finishLine();
        try self.insert(self.current, path, parsed);
    }

    fn select(self: *Parser, path: []const string, array_of_tables: bool) ParseFail!void {
        if (path.len == 0) return error.Invalid;
        var table = self.root;
        const last = path.len - 1;
        for (path[0..last]) |part| {
            table = try table.ensureTable(self.arena, part);
        }
        if (array_of_tables) {
            self.current = try table.appendTable(self.arena, path[last]);
            return;
        }
        self.current = try table.ensureTable(self.arena, path[last]);
    }

    fn insert(self: *Parser, start: *Table, path: []const string, parsed: Value) ParseFail!void {
        if (path.len == 0) return error.Invalid;
        var table = start;
        const last = path.len - 1;
        for (path[0..last]) |part| {
            table = try table.ensureTable(self.arena, part);
        }
        try table.put(self.arena, path[last], parsed);
    }

    fn keyPath(self: *Parser, buf: []string) ParseFail![]string {
        var count: usize = 0;
        while (true) {
            if (count >= buf.len) return error.Invalid;
            buf[count] = try self.key();
            count += 1;
            self.skipSpace();
            if (self.peek() != '.') break;
            self.pos += 1;
            self.skipSpace();
        }
        return buf[0..count];
    }

    fn key(self: *Parser) ParseFail!string {
        if (self.eof()) return error.Invalid;
        if (self.peek() == '"') return self.basicString();
        if (self.peek() == '\'') return self.literalString();
        return self.bareKey();
    }

    fn bareKey(self: *Parser) ParseFail!string {
        const start = self.pos;
        while (!self.eof() and isBare(self.peek())) self.pos += 1;
        if (self.pos == start) return error.Invalid;
        return self.arena.dupe(u8, self.src[start..self.pos]);
    }

    fn parseValue(self: *Parser) ParseFail!Value {
        if (self.eof()) return error.Invalid;
        return switch (self.peek()) {
            '"' => .{ .string = try self.basicString() },
            '\'' => .{ .string = try self.literalString() },
            '[' => .{ .array = try self.parseArray() },
            '{' => .{ .table = try self.inlineTable() },
            't', 'f' => try self.boolOrIdent(),
            '-', '+', '0'...'9' => try self.number(),
            else => .{ .string = try self.identifier() },
        };
    }

    fn boolOrIdent(self: *Parser) ParseFail!Value {
        const ident = try self.identifier();
        if (std.mem.eql(u8, ident, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, ident, "false")) return .{ .boolean = false };
        return .{ .string = ident };
    }

    fn identifier(self: *Parser) ParseFail!string {
        const start = self.pos;
        while (!self.eof() and isIdent(self.peek())) self.pos += 1;
        if (self.pos == start) return error.Invalid;
        return self.arena.dupe(u8, self.src[start..self.pos]);
    }

    fn number(self: *Parser) ParseFail!Value {
        const start = self.pos;
        if (self.peek() == '+' or self.peek() == '-') self.pos += 1;
        var seen_dot = false;
        var seen_exp = false;
        while (!self.eof()) {
            const char = self.peek();
            if (char == '_' ) {
                self.pos += 1;
                continue;
            }
            if (char == '.' and !seen_dot and !seen_exp) {
                seen_dot = true;
                self.pos += 1;
                continue;
            }
            if ((char == 'e' or char == 'E') and !seen_exp) {
                seen_exp = true;
                self.pos += 1;
                self.consumeOptionalSign();
                continue;
            }
            if (char < '0' or char > '9') break;
            self.pos += 1;
        }
        return self.finishNumber(start, seen_dot or seen_exp);
    }

    fn consumeOptionalSign(self: *Parser) void {
        if (self.peek() != '+' and self.peek() != '-') return;
        self.pos += 1;
    }

    fn finishNumber(self: *Parser, start: usize, is_float: bool) ParseFail!Value {
        var buf: [64]u8 = undefined;
        const raw = try stripUnderscores(self.src[start..self.pos], &buf);
        if (is_float) {
            const parsed = std.fmt.parseFloat(f64, raw) catch return error.Invalid;
            return .{ .float = parsed };
        }
        const parsed = std.fmt.parseInt(i64, raw, 10) catch return error.Invalid;
        return .{ .integer = parsed };
    }

    fn parseArray(self: *Parser) ParseFail!value.Array {
        try self.expect('[');
        var arr = value.Array{};
        while (true) {
            self.skipJunk();
            if (self.eof()) return error.Invalid;
            if (self.peek() == ']') {
                self.pos += 1;
                return arr;
            }
            const item = try self.parseValue();
            try arr.items.append(self.arena, item);
            self.skipJunk();
            if (self.peek() == ',') {
                self.pos += 1;
                continue;
            }
            try self.expect(']');
            return arr;
        }
    }

    fn inlineTable(self: *Parser) ParseFail!Table {
        try self.expect('{');
        var table = Table{};
        while (true) {
            self.skipSpace();
            if (self.eof()) return error.Invalid;
            if (self.peek() == '}') {
                self.pos += 1;
                return table;
            }
            var path_buf: [8]string = undefined;
            const path = try self.keyPath(&path_buf);
            self.skipSpace();
            try self.expect('=');
            self.skipSpace();
            const parsed = try self.parseValue();
            try self.insert(&table, path, parsed);
            self.skipSpace();
            if (self.peek() == ',') {
                self.pos += 1;
                continue;
            }
            try self.expect('}');
            return table;
        }
    }

    fn basicString(self: *Parser) ParseFail!string {
        try self.expect('"');
        var out: std.ArrayList(u8) = .empty;
        while (!self.eof()) {
            const char = self.peek();
            self.pos += 1;
            if (char == '"') return out.toOwnedSlice(self.arena);
            if (char == '\n') return error.Invalid;
            if (char != '\\') {
                try out.append(self.arena, char);
                continue;
            }
            try out.append(self.arena, try self.escape());
        }
        return error.Invalid;
    }

    fn escape(self: *Parser) ParseFail!u8 {
        if (self.eof()) return error.Invalid;
        const char = self.peek();
        self.pos += 1;
        return switch (char) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            'b' => 0x08,
            'f' => 0x0c,
            else => char,
        };
    }

    fn literalString(self: *Parser) ParseFail!string {
        try self.expect('\'');
        const start = self.pos;
        while (!self.eof()) {
            const char = self.peek();
            if (char == '\'') {
                const slice = self.src[start..self.pos];
                self.pos += 1;
                return self.arena.dupe(u8, slice);
            }
            if (char == '\n') return error.Invalid;
            self.pos += 1;
        }
        return error.Invalid;
    }

    fn finishLine(self: *Parser) void {
        self.skipSpace();
        if (!self.eof() and self.peek() == '#') self.skipLine();
        if (!self.eof() and (self.peek() == '\n' or self.peek() == '\r')) self.consumeNewline();
    }

    fn skipLine(self: *Parser) void {
        while (!self.eof() and self.peek() != '\n' and self.peek() != '\r') self.pos += 1;
        if (!self.eof()) self.consumeNewline();
    }

    fn skipJunk(self: *Parser) void {
        while (!self.eof()) {
            const char = self.peek();
            if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
                self.pos += 1;
                continue;
            }
            if (char == '#') {
                self.skipLine();
                continue;
            }
            return;
        }
    }

    fn skipSpace(self: *Parser) void {
        while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t')) self.pos += 1;
    }

    fn consumeNewline(self: *Parser) void {
        if (self.peek() == '\r') self.pos += 1;
        if (!self.eof() and self.peek() == '\n') self.pos += 1;
    }

    fn expect(self: *Parser, char: u8) ParseFail!void {
        if (self.eof() or self.peek() != char) return error.Invalid;
        self.pos += 1;
    }

    fn peek(self: Parser) u8 {
        if (self.eof()) return 0;
        return self.src[self.pos];
    }

    fn eof(self: Parser) bool {
        return self.pos >= self.src.len;
    }
};

fn isBare(char: u8) bool {
    return isIdent(char) or char == '-';
}

fn stripUnderscores(raw: string, buf: []u8) ParseFail!string {
    var count: usize = 0;
    for (raw) |char| {
        if (char == '_') continue;
        if (count >= buf.len) return error.Invalid;
        buf[count] = char;
        count += 1;
    }
    if (count == 0) return error.Invalid;
    return buf[0..count];
}

fn isIdent(char: u8) bool {
    return (char >= '0' and char <= '9') or
        (char >= 'A' and char <= 'Z') or
        (char >= 'a' and char <= 'z') or
        char == '_';
}

fn parseOk(gpa: std.mem.Allocator, source: string) !Document {
    var diag = Diagnostics{};
    return parse(gpa, source, &diag);
}

test "parse tables, quoted keys, and comments" {
    const gpa = testing.allocator;
    var doc = try parseOk(gpa,
        \\# comment
        \\[output]
        \\hdr = on
        \\
        \\[output."DP-1"]
        \\scale = 1.5
        \\
        \\[output.HDMI-A-1]
        \\scale = 2
    );
    defer doc.deinit();

    try testing.expectEqualStrings("on", doc.getString(&.{ "output", "hdr" }).?);
    try testing.expectEqual(@as(?f64, 1.5), doc.getFloat(&.{ "output", "DP-1", "scale" }));
    try testing.expectEqual(@as(?f64, 2), doc.getFloat(&.{ "output", "HDMI-A-1", "scale" }));
}

test "parse array of tables and skip bad lines" {
    const gpa = testing.allocator;
    var diag = Diagnostics{};
    var doc = try parse(gpa,
        \\[[window_rules]]
        \\app_id = "foot"
        \\ssd = true
        \\not a key
        \\
        \\[[window_rules]]
        \\app_id = 'kitty'
        \\placement = "sheet"
    , &diag);
    defer doc.deinit();

    try testing.expect(diag.count >= 1);
    const rules = doc.get(&.{"window_rules"}).?.asArray() catch unreachable;
    try testing.expectEqual(@as(usize, 2), rules.items.items.len);
    try testing.expectEqualStrings("foot", rules.items.items[0].table.get("app_id").?.string);
    try testing.expect(rules.items.items[0].table.get("ssd").?.boolean);
    try testing.expectEqualStrings("kitty", rules.items.items[1].table.get("app_id").?.string);
}

test "parse arrays, inline tables, and escapes" {
    const gpa = testing.allocator;
    var doc = try parseOk(gpa,
        \\ids = [1, 2, 3]
        \\point = { x = 4, y = 5 }
        \\label = "hello\nworld"
    );
    defer doc.deinit();

    const ids = doc.get(&.{"ids"}).?.array;
    try testing.expectEqual(@as(i64, 1), ids.items.items[0].integer);
    try testing.expectEqual(@as(i64, 3), ids.items.items[2].integer);
    try testing.expectEqual(@as(i64, 4), doc.getInt(&.{ "point", "x" }).?);
    try testing.expectEqualStrings("hello\nworld", doc.getString(&.{"label"}).?);
}

test "parse underscored integers and truncated headers" {
    const gpa = testing.allocator;
    var doc = try parseOk(gpa, "count = 1_000\n");
    defer doc.deinit();
    try testing.expectEqual(@as(?i64, 1000), doc.getInt(&.{"count"}));

    var diag = Diagnostics{};
    var broken = try parse(gpa, "[output", &diag);
    defer broken.deinit();
    try testing.expect(diag.count >= 1);
}

test "parse dotted keys relative to the current table" {
    const gpa = testing.allocator;
    var doc = try parseOk(gpa,
        \\[shell]
        \\gesture.dead_zone = 6
    );
    defer doc.deinit();
    try testing.expectEqual(@as(?i64, 6), doc.getInt(&.{ "shell", "gesture", "dead_zone" }));
}
