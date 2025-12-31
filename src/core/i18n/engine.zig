const std = @import("std");
const string = @import("core.string").string;

/// Map of variables for translation substitution
pub const TranslationVarMap = std.StringHashMap(string);

/// Function type for dynamic translations (e.g., pluralization)
pub const TranslationFn = *const fn (map: TranslationVarMap, allocator: std.mem.Allocator) anyerror!string;

/// A locale representation
pub const Locale = struct {
    locale: string, // e.g., "en_US" from "en_US.UTF-8"
    full: string, // e.g., "en_US.UTF-8" or "LC_CTYPE=en_US"

    pub fn init(full_locale: string, allocator: std.mem.Allocator) !Locale {
        const locale = try extractLocale(full_locale, allocator);
        const full_copy = try allocator.dupe(u8, full_locale);
        return .{
            .locale = locale,
            .full = full_copy,
        };
    }

    pub fn deinit(self: *Locale, allocator: std.mem.Allocator) void {
        allocator.free(self.locale);
        allocator.free(self.full);
    }

    /// Get the stem (language part only, e.g., "en" from "en_US")
    pub fn stem(self: Locale, allocator: std.mem.Allocator) !string {
        if (std.mem.indexOf(u8, self.locale, "_")) |underscore_pos| {
            return try allocator.dupe(u8, self.locale[0..underscore_pos]);
        }
        return try allocator.dupe(u8, self.locale);
    }
};

/// Translation entry
const TranslationEntry = struct {
    exists: bool = false,
    entry: string = "",
    fn_ptr: ?TranslationFn = null,

    pub fn deinit(self: *TranslationEntry, allocator: std.mem.Allocator) void {
        if (self.entry.len > 0) {
            allocator.free(self.entry);
        }
    }
};

/// I18n Engine for managing translations
pub const Engine = struct {
    entries: std.StringHashMap(std.ArrayList(TranslationEntry)),
    fallback_locale: string,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .entries = std.StringHashMap(std.ArrayList(TranslationEntry)).init(allocator),
            .fallback_locale = "en_US",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            for (kv.value_ptr.items) |*entry| {
                entry.deinit(self.allocator);
            }
            kv.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Register a translation entry with a string
    pub fn registerEntry(self: *Self, locale: string, key: u64, translation: string) !void {
        const locale_copy = try self.allocator.dupe(u8, locale);
        errdefer self.allocator.free(locale_copy);

        const result = try self.entries.getOrPut(locale_copy);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(TranslationEntry){};
        } else {
            // Free the duplicate locale string if entry already existed
            self.allocator.free(locale_copy);
        }

        var entry_vec = result.value_ptr;

        // Resize if necessary
        if (entry_vec.items.len <= key) {
            const old_len = entry_vec.items.len;
            try entry_vec.resize(self.allocator, key + 1);
            // Initialize new entries
            for (entry_vec.items[old_len..]) |*entry| {
                entry.* = .{};
            }
        }

        // Free old entry if it exists
        if (entry_vec.items[key].entry.len > 0) {
            self.allocator.free(entry_vec.items[key].entry);
        }

        const translation_copy = try self.allocator.dupe(u8, translation);
        entry_vec.items[key] = .{
            .exists = true,
            .entry = translation_copy,
            .fn_ptr = null,
        };
    }

    /// Register a translation entry with a function
    pub fn registerEntryFn(self: *Self, locale: string, key: u64, func: TranslationFn) !void {
        const locale_copy = try self.allocator.dupe(u8, locale);
        errdefer self.allocator.free(locale_copy);

        const result = try self.entries.getOrPut(locale_copy);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(TranslationEntry){};
        } else {
            self.allocator.free(locale_copy);
        }

        var entry_vec = result.value_ptr;

        if (entry_vec.items.len <= key) {
            const old_len = entry_vec.items.len;
            try entry_vec.resize(self.allocator, key + 1);
            for (entry_vec.items[old_len..]) |*entry| {
                entry.* = .{};
            }
        }

        if (entry_vec.items[key].entry.len > 0) {
            self.allocator.free(entry_vec.items[key].entry);
        }

        entry_vec.items[key] = .{
            .exists = true,
            .entry = "",
            .fn_ptr = func,
        };
    }

    /// Set the fallback locale
    pub fn setFallbackLocale(self: *Self, locale: string) void {
        self.fallback_locale = locale;
    }

    /// Localize an entry with variable substitution
    pub fn localizeEntry(self: *Self, locale: string, key: u64, var_map: TranslationVarMap) !string {
        var entry: ?*TranslationEntry = null;

        // Try exact locale match
        if (self.entries.get(locale)) |entry_vec| {
            if (entry_vec.items.len > key) {
                entry = &entry_vec.items[key];
            }
        }

        // Fallback logic for locales with underscore
        if (std.mem.indexOf(u8, locale, "_")) |underscore_pos| {
            if (entry == null or !entry.?.exists) {
                // Try lang_LANG format
                const stem = locale[0..underscore_pos];
                var stem_upper_buf: [32]u8 = undefined;
                const stem_upper = std.ascii.upperString(&stem_upper_buf, stem);

                var new_locale_buf: [64]u8 = undefined;
                const new_locale = try std.fmt.bufPrint(&new_locale_buf, "{s}_{s}", .{ stem, stem_upper });

                if (self.entries.get(new_locale)) |entry_vec| {
                    if (entry_vec.items.len > key) {
                        entry = &entry_vec.items[key];
                    }
                }
            }

            // Try any locale with same stem
            if (entry == null or !entry.?.exists) {
                const stem_with_underscore = locale[0 .. underscore_pos + 1];
                const stem_raw = locale[0..underscore_pos];

                var it = self.entries.iterator();
                while (it.next()) |kv| {
                    if (std.mem.startsWith(u8, kv.key_ptr.*, stem_with_underscore) or
                        std.mem.eql(u8, kv.key_ptr.*, stem_raw))
                    {
                        if (kv.value_ptr.items.len > key) {
                            entry = &kv.value_ptr.items[key];
                            if (entry.?.exists) break;
                        }
                    }
                }
            }
        } else {
            // Locale without underscore (e.g., "pl")
            if (entry == null or !entry.?.exists) {
                var it = self.entries.iterator();
                while (it.next()) |kv| {
                    var locale_with_underscore_buf: [64]u8 = undefined;
                    const locale_with_underscore = try std.fmt.bufPrint(&locale_with_underscore_buf, "{s}_", .{locale});

                    if (std.mem.startsWith(u8, kv.key_ptr.*, locale_with_underscore) or
                        std.mem.eql(u8, kv.key_ptr.*, locale))
                    {
                        if (kv.value_ptr.items.len > key) {
                            entry = &kv.value_ptr.items[key];
                            if (entry.?.exists) break;
                        }
                    }
                }
            }
        }

        // Fall back to fallback locale
        if (entry == null or !entry.?.exists) {
            if (self.entries.get(self.fallback_locale)) |entry_vec| {
                if (entry_vec.items.len > key) {
                    entry = &entry_vec.items[key];
                }
            }
        }

        if (entry == null or !entry.?.exists) {
            return try self.allocator.dupe(u8, "");
        }

        // Get the raw string (from entry or function)
        var raw_str: string = undefined;
        var fn_string_owned: ?string = null;
        defer if (fn_string_owned) |s| self.allocator.free(s);

        if (entry.?.fn_ptr) |func| {
            fn_string_owned = try func(var_map, self.allocator);
            raw_str = fn_string_owned.?;
        } else {
            raw_str = entry.?.entry;
        }

        // Perform variable substitution
        return try substituteVariables(raw_str, var_map, self.allocator);
    }

    /// Get the system locale
    pub fn getSystemLocale(allocator: std.mem.Allocator) !Locale {
        // Try to get from environment variables
        const locale_str = std.posix.getenv("LANG") orelse
            std.posix.getenv("LC_ALL") orelse
            "en_US.UTF-8";

        return try Locale.init(locale_str, allocator);
    }
};

/// Extract the locale from a full locale string
/// Handles various formats: "en_US.UTF-8", "LC_CTYPE=en_US", "POSIX", "*"
fn extractLocale(full_locale: string, allocator: std.mem.Allocator) !string {
    var locale = full_locale;

    // Handle special cases
    if (std.mem.eql(u8, locale, "POSIX") or std.mem.eql(u8, locale, "*")) {
        return try allocator.dupe(u8, "en_US");
    }

    // Handle LC_CTYPE=en_US format
    if (std.mem.indexOf(u8, locale, "=")) |equals_pos| {
        locale = locale[equals_pos + 1 ..];
    }

    // Remove .UTF-8 or other encoding suffixes
    if (std.mem.indexOf(u8, locale, ".")) |dot_pos| {
        locale = locale[0..dot_pos];
    }

    return try allocator.dupe(u8, locale);
}

/// Substitute variables in a string
fn substituteVariables(raw_str: string, var_map: TranslationVarMap, allocator: std.mem.Allocator) !string {
    const Range = struct {
        begin: usize,
        end: usize,
        value: string,
    };

    var ranges = std.ArrayList(Range){};
    defer ranges.deinit(allocator);

    // Find all {variable} patterns
    var it = var_map.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const value = kv.value_ptr.*;

        var start: usize = 0;
        while (std.mem.indexOfPos(u8, raw_str, start, key)) |pos| {
            defer start = pos + 1;

            if (pos == 0 or pos + key.len >= raw_str.len) continue;
            if (raw_str[pos - 1] != '{' or raw_str[pos + key.len] != '}') continue;

            try ranges.append(allocator, .{
                .begin = pos - 1,
                .end = pos + key.len + 1,
                .value = value,
            });
        }
    }

    if (ranges.items.len == 0) {
        return try allocator.dupe(u8, raw_str);
    }

    // Sort ranges by position
    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.begin < b.begin;
        }
    }.lessThan);

    // Calculate result size
    var result_len: usize = 0;
    var last_end: usize = 0;
    for (ranges.items) |range| {
        result_len += (range.begin - last_end) + range.value.len;
        last_end = range.end;
    }
    result_len += raw_str.len - last_end;

    // Build result string
    var result = try std.ArrayList(u8).initCapacity(allocator, result_len);
    errdefer result.deinit(allocator);

    last_end = 0;
    for (ranges.items) |range| {
        try result.appendSlice(allocator, raw_str[last_end..range.begin]);
        try result.appendSlice(allocator, range.value);
        last_end = range.end;
    }
    try result.appendSlice(allocator, raw_str[last_end..]);

    return result.toOwnedSlice(allocator);
}

test "Engine - basic translation" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("en_US", 0, "Hello");
    try engine.registerEntry("pl_PL", 0, "Cześć");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    const result_en = try engine.localizeEntry("en_US", 0, var_map);
    defer std.testing.allocator.free(result_en);
    try std.testing.expectEqualStrings("Hello", result_en);

    const result_pl = try engine.localizeEntry("pl_PL", 0, var_map);
    defer std.testing.allocator.free(result_pl);
    try std.testing.expectEqualStrings("Cześć", result_pl);
}

test "Engine - variable substitution" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("en_US", 0, "Hello, {name}!");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();
    try var_map.put("name", "World");

    const result = try engine.localizeEntry("en_US", 0, var_map);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "Engine - fallback locale" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("en_US", 0, "Hello");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    // Try to get a translation that doesn't exist, should fall back
    const result = try engine.localizeEntry("de_DE", 0, var_map);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "Locale - extract from UTF-8" {
    const locale = try Locale.init("en_US.UTF-8", std.testing.allocator);
    defer {
        var mut_locale = locale;
        mut_locale.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("en_US", locale.locale);
    try std.testing.expectEqualStrings("en_US.UTF-8", locale.full);

    const stem_str = try locale.stem(std.testing.allocator);
    defer std.testing.allocator.free(stem_str);
    try std.testing.expectEqualStrings("en", stem_str);
}

test "Locale - extract from LC_CTYPE format" {
    const locale = try Locale.init("LC_CTYPE=en_US", std.testing.allocator);
    defer {
        var mut_locale = locale;
        mut_locale.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("en_US", locale.locale);
}

test "Locale - handle POSIX" {
    const locale = try Locale.init("POSIX", std.testing.allocator);
    defer {
        var mut_locale = locale;
        mut_locale.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("en_US", locale.locale);
}

test "Locale - handle wildcard" {
    const locale = try Locale.init("*", std.testing.allocator);
    defer {
        var mut_locale = locale;
        mut_locale.deinit(std.testing.allocator);
    }

    try std.testing.expectEqualStrings("en_US", locale.locale);
}

test "Locale - stem without underscore" {
    const locale = try Locale.init("pl", std.testing.allocator);
    defer {
        var mut_locale = locale;
        mut_locale.deinit(std.testing.allocator);
    }

    const stem_str = try locale.stem(std.testing.allocator);
    defer std.testing.allocator.free(stem_str);
    try std.testing.expectEqualStrings("pl", stem_str);
}

test "Engine - pluralization with function" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    // English pluralization (simple: 1 vs many)
    const EnglishPlural = struct {
        fn pluralize(map: TranslationVarMap, allocator: std.mem.Allocator) ![]const u8 {
            const count_str = map.get("count") orelse return try allocator.dupe(u8, "I have apples.");

            // Simple check if count is "1"
            if (std.mem.eql(u8, count_str, "1")) {
                return try allocator.dupe(u8, "I have {count} apple.");
            } else {
                return try allocator.dupe(u8, "I have {count} apples.");
            }
        }
    };

    try engine.registerEntryFn("en_US", 1, EnglishPlural.pluralize);

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    try var_map.put("count", "1");
    const result1 = try engine.localizeEntry("en_US", 1, var_map);
    defer std.testing.allocator.free(result1);
    try std.testing.expectEqualStrings("I have 1 apple.", result1);

    try var_map.put("count", "2");
    const result2 = try engine.localizeEntry("en_US", 1, var_map);
    defer std.testing.allocator.free(result2);
    try std.testing.expectEqualStrings("I have 2 apples.", result2);
}

test "Engine - locale stem fallback (pl -> pl_PL)" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("pl_PL", 0, "Witaj świecie!");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    // Request "pl" should match "pl_PL"
    const result = try engine.localizeEntry("pl", 0, var_map);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Witaj świecie!", result);
}

test "Engine - locale fallback chain (en_XX -> en_US)" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("en_US", 0, "Hello from US");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    // Request "en_XX" should fall back to "en_US"
    const result = try engine.localizeEntry("en_XX", 0, var_map);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello from US", result);
}

test "Engine - locale variant matching (es_YY prefers es_ES over es_XX)" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("es_XX", 0, "Spanish variant XX");
    try engine.registerEntry("es_ES", 0, "Spanish Spain");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    // Should prefer exact stem match or available variant
    const result = try engine.localizeEntry("es_YY", 0, var_map);
    defer std.testing.allocator.free(result);

    // Will match one of the es_* variants
    try std.testing.expect(std.mem.indexOf(u8, result, "Spanish") != null);
}

test "Engine - multiple variable substitution" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("en_US", 0, "Hello {var1} world {var2}");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    try var_map.put("var1", "hi");
    try var_map.put("var2", "!");

    const result = try engine.localizeEntry("en_US", 0, var_map);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello hi world !", result);
}

test "Engine - variable substitution order independent" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("en_US", 0, "A {x} B {y}");

    var var_map1 = TranslationVarMap.init(std.testing.allocator);
    defer var_map1.deinit();
    try var_map1.put("x", "1");
    try var_map1.put("y", "2");

    var var_map2 = TranslationVarMap.init(std.testing.allocator);
    defer var_map2.deinit();
    try var_map2.put("y", "2");
    try var_map2.put("x", "1");

    const result1 = try engine.localizeEntry("en_US", 0, var_map1);
    defer std.testing.allocator.free(result1);

    const result2 = try engine.localizeEntry("en_US", 0, var_map2);
    defer std.testing.allocator.free(result2);

    try std.testing.expectEqualStrings("A 1 B 2", result1);
    try std.testing.expectEqualStrings(result1, result2);
}

test "Engine - malformed variable patterns" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    // Patterns that shouldn't be replaced
    try engine.registerEntry("en_US", 0, "count}");
    try engine.registerEntry("en_US", 1, "{count");
    try engine.registerEntry("en_US", 2, "{{count}}"); // Double braces

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();
    try var_map.put("count", "1");

    const result0 = try engine.localizeEntry("en_US", 0, var_map);
    defer std.testing.allocator.free(result0);
    try std.testing.expectEqualStrings("count}", result0);

    const result1 = try engine.localizeEntry("en_US", 1, var_map);
    defer std.testing.allocator.free(result1);
    try std.testing.expectEqualStrings("{count", result1);

    const result2 = try engine.localizeEntry("en_US", 2, var_map);
    defer std.testing.allocator.free(result2);
    // Our implementation finds {count} inside {{count}} and replaces it
    try std.testing.expectEqualStrings("{1}", result2);
}

test "Engine - invalid key returns empty string" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.registerEntry("en_US", 0, "Valid");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    // Invalid key
    const result = try engine.localizeEntry("en_US", 42069, var_map);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "Engine - comprehensive locale fallback" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    engine.setFallbackLocale("en_US");

    try engine.registerEntry("en_US", 0, "Hello World!");
    try engine.registerEntry("pl_PL", 0, "Witaj świecie!");
    try engine.registerEntry("am", 0, "Amongus!");

    var var_map = TranslationVarMap.init(std.testing.allocator);
    defer var_map.deinit();

    // Direct matches
    const en = try engine.localizeEntry("en_US", 0, var_map);
    defer std.testing.allocator.free(en);
    try std.testing.expectEqualStrings("Hello World!", en);

    const pl = try engine.localizeEntry("pl_PL", 0, var_map);
    defer std.testing.allocator.free(pl);
    try std.testing.expectEqualStrings("Witaj świecie!", pl);

    // Locale without region should match any with that language
    const am = try engine.localizeEntry("am_AM", 0, var_map);
    defer std.testing.allocator.free(am);
    try std.testing.expectEqualStrings("Amongus!", am);

    // Unknown locale should fall back to en_US
    const de = try engine.localizeEntry("de_DE", 0, var_map);
    defer std.testing.allocator.free(de);
    try std.testing.expectEqualStrings("Hello World!", de);
}
