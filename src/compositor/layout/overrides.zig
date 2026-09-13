//! W7 window-rule table. Reads `[[window_rules]]` from the shared config store.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("core").testing;
const core = @import("core");
const strip = @import("strip.zig");

pub const Placement = enum { column, sheet };

pub const Rule = struct {
    app_id: string,
    title_substring: ?string = null,
    column_width: ?strip.Width = null,
    placement: ?Placement = null,
    ssd: ?bool = null,
};

pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.ArrayList(Rule) = .empty,

    pub fn init(gpa: std.mem.Allocator) Table {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    /// Returns the most specific matching rule. Title substring wins over app-only.
    pub fn lookup(self: *const Table, app_id: string, title: ?string) ?Rule {
        var generic: ?Rule = null;
        for (self.rules.items) |rule| {
            if (!std.mem.eql(u8, rule.app_id, app_id)) continue;
            if (rule.title_substring) |needle| {
                if (titleMatches(title, needle)) return rule;
                continue;
            }
            generic = rule;
        }
        return generic;
    }
};

/// Loads `$XDG_CONFIG_HOME/sideswipe/config.toml`, or `$HOME/.config` when unset.
pub fn load(gpa: std.mem.Allocator) Table {
    var cfg = core.config.schema.loadUser(
        gpa,
        std.Options.debug_io,
        core.env.get("XDG_CONFIG_HOME"),
        core.env.get("HOME"),
    ) catch return Table.init(gpa);
    defer cfg.deinit();
    return fromSchema(gpa, cfg) catch Table.init(gpa);
}

/// Parses `[[window_rules]]` tables. Unknown keys and bad values are skipped per-key.
pub fn parse(gpa: std.mem.Allocator, contents: string) std.mem.Allocator.Error!Table {
    var cfg = try core.config.Config.parse(gpa, contents);
    defer cfg.deinit();
    return fromSchema(gpa, cfg);
}

/// Resolves the W7 config path. Empty XDG/HOME values are ignored.
pub fn resolveConfigPath(gpa: std.mem.Allocator, xdg_home: ?string, home: ?string) ?[]u8 {
    return core.config.dir.resolveFile(gpa, xdg_home, home, core.config.dir.files.main) catch null;
}

fn titleMatches(title: ?string, needle: string) bool {
    const haystack = title orelse return false;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn fromSchema(gpa: std.mem.Allocator, cfg: core.config.Config) std.mem.Allocator.Error!Table {
    var table = Table.init(gpa);
    errdefer table.deinit();
    const arena = table.arena.allocator();
    for (cfg.window_rules) |rule| {
        try table.rules.append(arena, try copyRule(arena, rule));
    }
    return table;
}

fn copyRule(arena: std.mem.Allocator, rule: core.config.schema.WindowRule) !Rule {
    return .{
        .app_id = try arena.dupe(u8, rule.app_id),
        .title_substring = try dupeOptional(arena, rule.title_substring),
        .column_width = if (rule.column_width) |width| .{ .ratio = width.ratio } else null,
        .placement = if (rule.placement) |placement| toPlacement(placement) else null,
        .ssd = rule.ssd,
    };
}

fn dupeOptional(arena: std.mem.Allocator, text: ?string) !?string {
    const value = text orelse return null;
    return try arena.dupe(u8, value);
}

fn toPlacement(placement: core.config.schema.Placement) Placement {
    return switch (placement) {
        .column => .column,
        .sheet => .sheet,
    };
}

test "overrides parse window_rules and skip invalid keys" {
    var table = try parse(testing.allocator,
        \\[shell]
        \\button = "BTN_MIDDLE"
        \\
        \\[[window_rules]]
        \\app_id = "org.gnome.Calculator"
        \\column_width = "1/3"
        \\placement = "sheet"
        \\ssd = true
        \\unknown = "ignored"
        \\
        \\[[window_rules]]
        \\app_id = "org.gnome.TextEditor"
        \\title_substring = "Preferences"
        \\placement = "column"
        \\column_width = "not-a-width"
        \\
        \\[[window_rules]]
        \\column_width = "100%"
    );
    defer table.deinit();

    try testing.expectEqual(@as(usize, 2), table.rules.items.len);
    const calc = table.lookup("org.gnome.Calculator", null).?;
    try testing.expectApproxEqAbs(1.0 / 3.0, calc.column_width.?.ratio, 1e-12);
    try testing.expectEqual(Placement.sheet, calc.placement.?);
    try testing.expect(calc.ssd.?);

    const prefs = table.lookup("org.gnome.TextEditor", "Open Preferences").?;
    try testing.expectEqual(Placement.column, prefs.placement.?);
    try testing.expectEqual(@as(?strip.Width, null), prefs.column_width);
    try testing.expectEqual(@as(?Rule, null), table.lookup("org.gnome.TextEditor", "Untitled"));
}

test "overrides title substring is more specific than app-only" {
    var table = try parse(testing.allocator,
        \\[[window_rules]]
        \\app_id = "foot"
        \\placement = "column"
        \\
        \\[[window_rules]]
        \\app_id = "foot"
        \\title_substring = "dialog"
        \\placement = "sheet"
    );
    defer table.deinit();

    try testing.expectEqual(Placement.sheet, table.lookup("foot", "Save dialog").?.placement.?);
    try testing.expectEqual(Placement.column, table.lookup("foot", "foot").?.placement.?);
}

test "overrides load missing file as empty table" {
    var cfg = try core.config.schema.loadUser(testing.allocator, std.testing.io, null, null);
    defer cfg.deinit();
    var table = try fromSchema(testing.allocator, cfg);
    defer table.deinit();
    try testing.expectEqual(@as(usize, 0), table.rules.items.len);
}

test "overrides resolve HOME config when XDG_CONFIG_HOME is unset" {
    const path = resolveConfigPath(testing.allocator, null, "/home/sideswipe").?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/sideswipe/.config/sideswipe/config.toml", path);
    try testing.expectEqual(@as(?[]u8, null), resolveConfigPath(testing.allocator, "", ""));
}
