//! XCursor theme selection and scale-aware image sizing.

const std = @import("std");
const string = @import("core.string").string;
const core = @import("core");
const testing = core.testing;

pub const default_name = "default";
pub const default_size: u32 = 24;

pub const Spec = struct {
    name: string = default_name,
    size: u32 = default_size,

    pub fn fromParts(name: ?string, size_text: ?string) Spec {
        return .{
            .name = nameOrDefault(name),
            .size = parseSize(size_text) orelse default_size,
        };
    }

    pub fn fromEnv() Spec {
        return fromParts(core.env.get("XCURSOR_THEME"), core.env.get("XCURSOR_SIZE"));
    }

    pub fn usesDefaultTheme(self: Spec) bool {
        return self.name.len == 0 or std.mem.eql(u8, self.name, default_name);
    }
};

pub const Image = enum {
    arrow,
    pointer,
    text,
    wait,

    pub fn xcursorName(self: Image) [:0]const u8 {
        return switch (self) {
            .arrow => "left_ptr",
            .pointer => "pointer",
            .text => "xterm",
            .wait => "watch",
        };
    }
};

const snapped_sizes = [_]u32{ 16, 24, 32, 48, 64, 96, 128 };

/// Returns the theme pixel size for a logical cursor at `scale`.
pub fn pixelSize(logical: u32, scale: f32) u32 {
    if (!std.math.isFinite(scale) or scale <= 0) return snap(logical);
    const scaled = @round(@as(f32, @floatFromInt(@max(logical, 1))) * scale);
    if (!std.math.isFinite(scaled) or scaled < 1) return snap(logical);
    return snap(@intFromFloat(scaled));
}

/// Converts a physical image extent into logical surface coordinates.
pub fn logicalExtent(physical: u32, scale: f32) i32 {
    const safe_scale = if (std.math.isFinite(scale) and scale >= 0.5) scale else 1;
    const logical = @round(@as(f32, @floatFromInt(physical)) / safe_scale);
    return @intFromFloat(@max(logical, 1));
}

fn nameOrDefault(name: ?string) string {
    const value = name orelse return default_name;
    if (value.len == 0) return default_name;
    return value;
}

fn parseSize(text: ?string) ?u32 {
    const value = text orelse return null;
    const parsed = std.fmt.parseInt(u32, value, 10) catch return null;
    if (parsed == 0 or parsed > 256) return null;
    return parsed;
}

fn snap(size: u32) u32 {
    var best = snapped_sizes[0];
    var best_distance = distance(size, best);
    for (snapped_sizes[1..]) |candidate| {
        const candidate_distance = distance(size, candidate);
        if (candidate_distance >= best_distance) continue;
        best = candidate;
        best_distance = candidate_distance;
    }
    return best;
}

fn distance(left: u32, right: u32) u32 {
    return if (left > right) left - right else right - left;
}

test "Spec - env parts fall back to default theme and size" {
    try testing.expectEqualStrings(default_name, Spec.fromParts(null, null).name);
    try testing.expectEqual(default_size, Spec.fromParts(null, null).size);
    try testing.expectEqualStrings("Bibata-Modern-Ice", Spec.fromParts("Bibata-Modern-Ice", "48").name);
    try testing.expectEqual(@as(u32, 48), Spec.fromParts("Bibata-Modern-Ice", "48").size);
    try testing.expectEqual(default_size, Spec.fromParts("", "0").size);
    try testing.expectEqual(default_name, Spec.fromParts("", "24").name);
}

test "Spec - default theme lets libwayland-cursor search XDG" {
    try testing.expect(Spec.fromParts("default", null).usesDefaultTheme());
    try testing.expect(Spec.fromParts("", null).usesDefaultTheme());
    try testing.expect(!Spec.fromParts("Bibata-Modern-Ice", null).usesDefaultTheme());
}

test "pixelSize snaps scaled logical sizes to common XCursor bins" {
    try testing.expectEqual(@as(u32, 24), pixelSize(24, 1));
    try testing.expectEqual(@as(u32, 48), pixelSize(24, 2));
    try testing.expectEqual(@as(u32, 32), pixelSize(24, 1.5));
    try testing.expectEqual(@as(u32, 24), pixelSize(24, 0));
}

test "logicalExtent converts physical theme pixels back to surface space" {
    try testing.expectEqual(@as(i32, 24), logicalExtent(24, 1));
    try testing.expectEqual(@as(i32, 24), logicalExtent(48, 2));
    try testing.expectEqual(@as(i32, 24), logicalExtent(36, 1.5));
}

test "Image maps to XCursor names" {
    try testing.expectEqualStrings("left_ptr", Image.arrow.xcursorName());
    try testing.expectEqualStrings("xterm", Image.text.xcursorName());
}
