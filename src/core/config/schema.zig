//! Typed sideswipe `config.toml` schema. Field names match TOML keys.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");
const value = @import("value.zig");
const parse = @import("parse.zig");
const bind = @import("bind.zig");
const toml = @import("toml.zig");
const dir = @import("dir.zig");

pub const Document = value.Document;
pub const Diagnostics = parse.Diagnostics;

pub const ShellButton = enum {
    middle,
    side,
    extra,

    pub fn parse(text: string) ?ShellButton {
        if (eqlAny(text, &.{ "BTN_MIDDLE", "middle" })) return .middle;
        if (eqlAny(text, &.{ "BTN_SIDE", "side" })) return .side;
        if (eqlAny(text, &.{ "BTN_EXTRA", "extra" })) return .extra;
        return null;
    }

    pub fn toml(self: ShellButton) string {
        return switch (self) {
            .middle => "BTN_MIDDLE",
            .side => "BTN_SIDE",
            .extra => "BTN_EXTRA",
        };
    }

    /// Linux `BTN_*` code. Compositor maps this onto the seat.
    pub fn code(self: ShellButton) u32 {
        return switch (self) {
            .middle => 0x112,
            .side => 0x113,
            .extra => 0x114,
        };
    }
};

pub const Appearance = enum { system, light, dark };

pub const HdrPolicy = enum { auto, on, off };

pub const Fraction = @import("fraction.zig").Fraction;
pub const ColumnWidth = Fraction;

pub const Placement = enum { column, sheet };

pub const Shell = struct {
    button: ShellButton = .middle,
    dead_zone: f64 = 6,
    hold_ms: u32 = 250,
    flick_ms: u32 = 300,
    axis_lock: f64 = 12,
};

pub const Theme = struct {
    appearance: Appearance = .system,
};

pub const Output = struct {
    scale: ?f32 = null,
    hdr: ?HdrPolicy = null,
    is_oled: ?bool = null,
    idle_dim_ms: ?u32 = null,
};

pub const ResolvedOutput = struct {
    scale: ?f32 = null,
    hdr: HdrPolicy = .auto,
    is_oled: bool = false,
    idle_dim_ms: ?u32 = null,
};

pub const OutputMap = struct {
    defaults: Output = .{},
    named: std.StringArrayHashMapUnmanaged(Output) = .empty,

    pub fn resolve(self: OutputMap, name: string) ResolvedOutput {
        return overlay(self.defaults, self.named.get(name));
    }
};

pub const WindowRule = struct {
    app_id: string = "",
    title_substring: ?string = null,
    column_width: ?ColumnWidth = null,
    placement: ?Placement = null,
    ssd: ?bool = null,
};

/// Canonical compositor / shell / Settings schema. Strings live in `arena`.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    shell: Shell = .{},
    theme: Theme = .{},
    window_rules: []const WindowRule = &.{},
    outputs: OutputMap = .{},

    pub fn init(gpa: std.mem.Allocator) Config {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn output(self: *const Config, name: string) ResolvedOutput {
        return self.outputs.resolve(name);
    }

    /// Missing file or unreadable contents yield compiled defaults. Never
    /// fails except on out-of-memory.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: string) std.mem.Allocator.Error!Config {
        var diag = Diagnostics{ .log = true };
        var doc = try toml.load(gpa, io, path, &diag);
        defer doc.deinit();
        return fromDocument(gpa, doc, &diag);
    }

    pub fn parse(gpa: std.mem.Allocator, source: string) std.mem.Allocator.Error!Config {
        var diag = Diagnostics{};
        return parseDiag(gpa, source, &diag);
    }

    pub fn parseLogged(gpa: std.mem.Allocator, source: string) std.mem.Allocator.Error!Config {
        var diag = Diagnostics{ .log = true };
        return parseDiag(gpa, source, &diag);
    }

    pub fn save(self: Config, gpa: std.mem.Allocator, io: std.Io, path: string) !void {
        var doc = try self.toDocument(gpa);
        defer doc.deinit();
        try toml.save(gpa, io, path, doc);
    }

    pub fn fromDocument(gpa: std.mem.Allocator, doc: Document, diag: *Diagnostics) std.mem.Allocator.Error!Config {
        var cfg = Config.init(gpa);
        errdefer cfg.deinit();
        try applyRoot(&cfg, doc.root, diag);
        return cfg;
    }

    pub fn toDocument(self: Config, gpa: std.mem.Allocator) !Document {
        var doc = Document.init(gpa);
        errdefer doc.deinit();
        try writeRoot(&doc, self);
        return doc;
    }
};

fn parseDiag(gpa: std.mem.Allocator, source: string, diag: *Diagnostics) std.mem.Allocator.Error!Config {
    var doc = try parse.parse(gpa, source, diag);
    defer doc.deinit();
    return Config.fromDocument(gpa, doc, diag);
}

fn applyRoot(cfg: *Config, root: value.Table, diag: *Diagnostics) !void {
    const arena = cfg.arena.allocator();
    try applyTable(Shell, &cfg.shell, arena, root, "shell", diag);
    try applyTable(Theme, &cfg.theme, arena, root, "theme", diag);
    try applyRules(&cfg.window_rules, arena, root, diag);
    try applyOutputs(&cfg.outputs, arena, root, diag);
    try reportRootUnknown(root, diag);
}

fn applyTable(
    comptime T: type,
    dest: *T,
    arena: std.mem.Allocator,
    root: value.Table,
    name: string,
    diag: *Diagnostics,
) !void {
    const found = root.get(name) orelse return;
    const table = found.asTable() catch {
        diag.report(.bad_value, name);
        return;
    };
    try bind.merge(T, dest, arena, table, diag);
}

fn applyRules(dest: *[]const WindowRule, arena: std.mem.Allocator, root: value.Table, diag: *Diagnostics) !void {
    const Wrap = struct { window_rules: []const WindowRule = &.{} };
    var wrap = Wrap{ .window_rules = dest.* };
    try bind.mergeFields(Wrap, &wrap, arena, root, diag);
    dest.* = wrap.window_rules;
}

fn applyOutputs(map: *OutputMap, arena: std.mem.Allocator, root: value.Table, diag: *Diagnostics) !void {
    const found = root.get("output") orelse return;
    const table = found.asTable() catch {
        diag.report(.bad_value, "output");
        return;
    };
    for (table.map.keys(), table.map.values()) |key, val| {
        try applyOutputEntry(map, arena, key, val, diag);
    }
}

fn applyOutputEntry(
    map: *OutputMap,
    arena: std.mem.Allocator,
    key: string,
    val: value.Value,
    diag: *Diagnostics,
) !void {
    if (val == .table) {
        var settings = Output{};
        try bind.merge(Output, &settings, arena, val.table, diag);
        try map.named.put(arena, try arena.dupe(u8, key), settings);
        return;
    }
    if (!isOutputKey(key)) {
        diag.report(.unknown_key, key);
        return;
    }
    var single = value.Table{};
    try single.put(arena, key, val);
    try bind.mergeFields(Output, &map.defaults, arena, single, diag);
}

fn isOutputKey(key: string) bool {
    inline for (std.meta.fields(Output)) |field| {
        if (std.mem.eql(u8, field.name, key)) return true;
    }
    return false;
}

fn reportRootUnknown(root: value.Table, diag: *Diagnostics) !void {
    for (root.map.keys()) |key| {
        if (isRootKey(key)) continue;
        diag.report(.unknown_key, key);
    }
}

fn isRootKey(key: string) bool {
    return eqlAny(key, &.{ "shell", "theme", "window_rules", "output" });
}

fn writeRoot(doc: *Document, cfg: Config) !void {
    const arena = doc.allocator();
    try doc.root.put(arena, "shell", .{ .table = try bind.fromStruct(Shell, arena, cfg.shell) });
    try doc.root.put(arena, "theme", .{ .table = try bind.fromStruct(Theme, arena, cfg.theme) });
    try writeRules(doc, cfg.window_rules);
    try writeOutputs(doc, cfg.outputs);
}

fn writeRules(doc: *Document, rules: []const WindowRule) !void {
    if (rules.len == 0) return;
    const arena = doc.allocator();
    var arr = value.Array{};
    for (rules) |rule| {
        try arr.items.append(arena, .{ .table = try bind.fromStruct(WindowRule, arena, rule) });
    }
    try doc.root.put(arena, "window_rules", .{ .array = arr });
}

fn writeOutputs(doc: *Document, map: OutputMap) !void {
    const arena = doc.allocator();
    const table = try doc.root.ensureTable(arena, "output");
    const defaults = try bind.fromStruct(Output, arena, map.defaults);
    for (defaults.map.keys(), defaults.map.values()) |key, val| {
        try table.put(arena, key, val);
    }
    for (map.named.keys(), map.named.values()) |name, settings| {
        try table.put(arena, name, .{ .table = try bind.fromStruct(Output, arena, settings) });
    }
}

fn overlay(defaults: Output, named: ?Output) ResolvedOutput {
    const over = named orelse Output{};
    return .{
        .scale = over.scale orelse defaults.scale,
        .hdr = over.hdr orelse defaults.hdr orelse .auto,
        .is_oled = over.is_oled orelse defaults.is_oled orelse false,
        .idle_dim_ms = over.idle_dim_ms orelse defaults.idle_dim_ms,
    };
}

fn eqlAny(text: string, options: []const string) bool {
    for (options) |option| {
        if (std.mem.eql(u8, text, option)) return true;
    }
    return false;
}

/// Resolves the user `config.toml` and loads it. Missing XDG/HOME yields defaults.
pub fn loadUser(gpa: std.mem.Allocator, io: std.Io, xdg_home: ?string, home_env: ?string) std.mem.Allocator.Error!Config {
    const path = (try dir.resolveFile(gpa, xdg_home, home_env, dir.files.main)) orelse return Config.init(gpa);
    defer gpa.free(path);
    return Config.load(gpa, io, path);
}

test "fromDocument does not depend on the parser" {
    const gpa = testing.allocator;
    var doc = Document.init(gpa);
    defer doc.deinit();
    try doc.setString(&.{ "theme", "appearance" }, "dark");
    try doc.setFloat(&.{ "output", "DP-1", "scale" }, 1.5);
    try doc.setString(&.{ "output", "hdr" }, "off");

    var diag = Diagnostics{};
    var cfg = try Config.fromDocument(gpa, doc, &diag);
    defer cfg.deinit();

    try testing.expectEqual(Appearance.dark, cfg.theme.appearance);
    try testing.expectEqual(HdrPolicy.off, cfg.output("HDMI-A-1").hdr);
    try testing.expectEqual(@as(?f32, 1.5), cfg.output("DP-1").scale);
    try testing.expectEqual(HdrPolicy.off, cfg.output("DP-1").hdr);
}

test "parse missing keys keep compiled defaults" {
    const gpa = testing.allocator;
    var cfg = try Config.parse(gpa, "");
    defer cfg.deinit();
    try testing.expectEqual(ShellButton.middle, cfg.shell.button);
    try testing.expectEqual(@as(f64, 6), cfg.shell.dead_zone);
    try testing.expectEqual(@as(u32, 250), cfg.shell.hold_ms);
    try testing.expectEqual(Appearance.system, cfg.theme.appearance);
    try testing.expectEqual(@as(?f32, null), cfg.output("eDP-1").scale);
    try testing.expectEqual(HdrPolicy.auto, cfg.output("eDP-1").hdr);
}

test "parse unknown keys and bad values fall back per key" {
    const gpa = testing.allocator;
    var diag = Diagnostics{};
    var cfg = try parseDiag(gpa,
        \\[shell]
        \\button = "BTN_SIDE"
        \\dead_zone = "nope"
        \\mystery = 1
        \\
        \\[output."DP-1"]
        \\scale = 1.5
        \\hdr = "nope"
        \\
        \\[[window_rules]]
        \\app_id = "foot"
        \\column_width = "not-a-width"
        \\placement = "sheet"
    , &diag);
    defer cfg.deinit();

    try testing.expectEqual(ShellButton.side, cfg.shell.button);
    try testing.expectEqual(@as(f64, 6), cfg.shell.dead_zone);
    try testing.expectEqual(@as(?f32, 1.5), cfg.output("DP-1").scale);
    try testing.expectEqual(HdrPolicy.auto, cfg.output("DP-1").hdr);
    try testing.expectEqual(@as(usize, 1), cfg.window_rules.len);
    try testing.expectEqual(@as(?ColumnWidth, null), cfg.window_rules[0].column_width);
    try testing.expectEqual(Placement.sheet, cfg.window_rules[0].placement.?);
    try testing.expect(diag.count >= 3);
}

test "window_rules column_width accepts percent, ratio, and decimal" {
    const gpa = testing.allocator;
    var cfg = try Config.parse(gpa,
        \\[[window_rules]]
        \\app_id = "percent"
        \\column_width = "33.33%"
        \\
        \\[[window_rules]]
        \\app_id = "ratio"
        \\column_width = "1/2"
        \\
        \\[[window_rules]]
        \\app_id = "decimal"
        \\column_width = 0.25
        \\
        \\[[window_rules]]
        \\app_id = "bare-int"
        \\column_width = 50
        \\
        \\[[window_rules]]
        \\app_id = "word"
        \\column_width = "half"
    );
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 5), cfg.window_rules.len);
    try testing.expectApproxEqAbs(0.3333, cfg.window_rules[0].column_width.?.ratio, 1e-12);
    try testing.expectApproxEqAbs(0.5, cfg.window_rules[1].column_width.?.ratio, 1e-12);
    try testing.expectApproxEqAbs(0.25, cfg.window_rules[2].column_width.?.ratio, 1e-12);
    try testing.expectEqual(@as(?ColumnWidth, null), cfg.window_rules[3].column_width);
    try testing.expectEqual(@as(?ColumnWidth, null), cfg.window_rules[4].column_width);
}

test "parse named output wins over [output] defaults" {
    const gpa = testing.allocator;
    var cfg = try Config.parse(gpa,
        \\[output]
        \\hdr = on
        \\scale = 1.25
        \\
        \\[output."DP-1"]
        \\hdr = off
    );
    defer cfg.deinit();
    try testing.expectEqual(HdrPolicy.off, cfg.output("DP-1").hdr);
    try testing.expectEqual(@as(?f32, 1.25), cfg.output("DP-1").scale);
    try testing.expectEqual(HdrPolicy.on, cfg.output("HDMI-A-1").hdr);
}

test "save then load round-trips the schema" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const file_path = try std.fmt.allocPrint(gpa, "{s}/config.toml", .{path_buf[0..dir_len]});
    defer gpa.free(file_path);

    var cfg = try Config.parse(gpa,
        \\[shell]
        \\button = "BTN_EXTRA"
        \\hold_ms = 400
        \\
        \\[theme]
        \\appearance = "light"
        \\
        \\[output.HDMI-A-1]
        \\scale = 2
        \\is_oled = true
        \\
        \\[[window_rules]]
        \\app_id = "org.gnome.Calculator"
        \\column_width = "1/3"
        \\placement = "sheet"
        \\ssd = true
    );
    defer cfg.deinit();
    try cfg.save(gpa, std.testing.io, file_path);

    var loaded = try Config.load(gpa, std.testing.io, file_path);
    defer loaded.deinit();
    try testing.expectEqual(ShellButton.extra, loaded.shell.button);
    try testing.expectEqual(@as(u32, 400), loaded.shell.hold_ms);
    try testing.expectEqual(Appearance.light, loaded.theme.appearance);
    try testing.expectEqual(@as(?f32, 2), loaded.output("HDMI-A-1").scale);
    try testing.expect(loaded.output("HDMI-A-1").is_oled);
    try testing.expectEqual(@as(usize, 1), loaded.window_rules.len);
    try testing.expectApproxEqAbs(1.0 / 3.0, loaded.window_rules[0].column_width.?.ratio, 1e-12);
    try testing.expectEqual(Placement.sheet, loaded.window_rules[0].placement.?);
    try testing.expect(loaded.window_rules[0].ssd.?);
}

test "load missing file uses defaults" {
    const gpa = testing.allocator;
    var cfg = try Config.load(gpa, std.testing.io, "/this/path/does/not/exist.toml");
    defer cfg.deinit();
    try testing.expectEqual(ShellButton.middle, cfg.shell.button);
    try testing.expectEqual(@as(usize, 0), cfg.window_rules.len);
}

test "resolveFile used by loadUser matches XDG layout" {
    const gpa = testing.allocator;
    const path = (try dir.resolveFile(gpa, "/xdg", null, dir.files.main)).?;
    defer gpa.free(path);
    try testing.expectEqualStrings("/xdg/sideswipe/config.toml", path);
}
