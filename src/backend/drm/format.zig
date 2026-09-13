//! DRM fourcc helpers and IN_FORMATS blob parsing.

const std = @import("std");
const core = @import("core");

pub const MOD_LINEAR: u64 = 0;
pub const MOD_INVALID: u64 = 0x00ffffffffffffff;
pub const FORMAT_BLOB_CURRENT: u32 = 1;

pub const XRGB8888: u32 = 0x34325258;
pub const ARGB8888: u32 = 0x34325241;
pub const XBGR8888: u32 = 0x34324258;
pub const ABGR8888: u32 = 0x34324241;

pub const ModifierBlob = extern struct {
    version: u32,
    flags: u32,
    count_formats: u32,
    formats_offset: u32,
    count_modifiers: u32,
    modifiers_offset: u32,
};

pub const FormatModifier = extern struct {
    formats: u64,
    offset: u32,
    pad: u32,
    modifier: u64,
};

const FormatBpc = struct { fourcc: u32, bpc: u8 };

const format_bpc_table = [_]FormatBpc{
    .{ .fourcc = XRGB8888, .bpc = 8 },
    .{ .fourcc = XBGR8888, .bpc = 8 },
    .{ .fourcc = ARGB8888, .bpc = 8 },
    .{ .fourcc = ABGR8888, .bpc = 8 },
    .{ .fourcc = 0x30335258, .bpc = 10 }, // XRGB2101010
    .{ .fourcc = 0x30334258, .bpc = 10 }, // XBGR2101010
    .{ .fourcc = 0x30335241, .bpc = 10 }, // ARGB2101010
    .{ .fourcc = 0x30334241, .bpc = 10 }, // ABGR2101010
    .{ .fourcc = 0x38345258, .bpc = 16 }, // XRGB16161616
    .{ .fourcc = 0x38344258, .bpc = 16 }, // XBGR16161616
    .{ .fourcc = 0x38345241, .bpc = 16 }, // ARGB16161616
    .{ .fourcc = 0x38344241, .bpc = 16 }, // ABGR16161616
};

/// Get maximum bits-per-channel for a DRM format.
pub fn getMaxBpc(fourcc: u32) u8 {
    inline for (format_bpc_table) |entry| {
        if (entry.fourcc == fourcc) return entry.bpc;
    }
    return 8;
}

/// True when the modifier must be passed to `drmModeAddFB2WithModifiers`.
pub fn needsModifierFlag(modifier: u64) bool {
    return modifier != 0 and modifier != MOD_INVALID;
}

/// Append every modifier that advertises `format` in an IN_FORMATS blob.
pub fn appendModifiers(
    blob: []const u8,
    format: u32,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u64),
) !void {
    const header = headerFrom(blob) orelse return error.InvalidBlob;
    const index = formatIndex(blob, header, format) orelse return;
    try forEachModifier(blob, header, index, gpa, out);
}

fn headerFrom(blob: []const u8) ?ModifierBlob {
    if (blob.len < @sizeOf(ModifierBlob)) return null;
    const header = std.mem.bytesToValue(ModifierBlob, blob[0..@sizeOf(ModifierBlob)]);
    if (header.version != FORMAT_BLOB_CURRENT) return null;
    return header;
}

fn formatIndex(blob: []const u8, header: ModifierBlob, format: u32) ?u32 {
    const start: usize = header.formats_offset;
    var index: u32 = 0;
    while (index < header.count_formats) : (index += 1) {
        const off = start + @as(usize, index) * @sizeOf(u32);
        if (off + @sizeOf(u32) > blob.len) return null;
        const entry = std.mem.readInt(u32, blob[off..][0..4], .little);
        if (entry == format) return index;
    }
    return null;
}

fn forEachModifier(
    blob: []const u8,
    header: ModifierBlob,
    index: u32,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u64),
) !void {
    const start: usize = header.modifiers_offset;
    var modifier_index: u32 = 0;
    while (modifier_index < header.count_modifiers) : (modifier_index += 1) {
        const off = start + @as(usize, modifier_index) * @sizeOf(FormatModifier);
        if (off + @sizeOf(FormatModifier) > blob.len) return error.InvalidBlob;
        var entry: FormatModifier = undefined;
        @memcpy(std.mem.asBytes(&entry), blob[off..][0..@sizeOf(FormatModifier)]);
        if (!entryCovers(entry, index)) continue;
        try out.append(gpa, entry.modifier);
    }
}

fn entryCovers(entry: FormatModifier, index: u32) bool {
    if (index < entry.offset) return false;
    const bit = index - entry.offset;
    if (bit >= 64) return false;
    return (entry.formats & (@as(u64, 1) << @intCast(bit))) != 0;
}

const testing = core.testing;

test "getMaxBpc - 8-bit formats" {
    try testing.expectEqual(@as(u8, 8), getMaxBpc(XRGB8888));
    try testing.expectEqual(@as(u8, 8), getMaxBpc(ARGB8888));
}

test "getMaxBpc - 10-bit formats" {
    try testing.expectEqual(@as(u8, 10), getMaxBpc(0x30335258));
    try testing.expectEqual(@as(u8, 10), getMaxBpc(0x30335241));
}

test "getMaxBpc - 16-bit formats" {
    try testing.expectEqual(@as(u8, 16), getMaxBpc(0x38345258));
    try testing.expectEqual(@as(u8, 16), getMaxBpc(0x38345241));
}

test "getMaxBpc - unknown format defaults to 8" {
    try testing.expectEqual(@as(u8, 8), getMaxBpc(0xDEADBEEF));
    try testing.expectEqual(@as(u8, 8), getMaxBpc(0));
}

test "needsModifierFlag - linear and invalid stay on AddFB2" {
    try testing.expect(!needsModifierFlag(MOD_LINEAR));
    try testing.expect(!needsModifierFlag(MOD_INVALID));
    try testing.expect(needsModifierFlag(0x0100000000000001));
}

test "appendModifiers - rejects a truncated blob" {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.InvalidBlob, appendModifiers(&.{1, 2, 3}, XRGB8888, testing.allocator, &out));
}

test "appendModifiers - reads LINEAR for both advertised formats" {
    const blob = testInFormatsBlob();
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try appendModifiers(&blob, XRGB8888, testing.allocator, &out);
    try appendModifiers(&blob, ARGB8888, testing.allocator, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(MOD_LINEAR, out.items[0]);
    try testing.expectEqual(MOD_LINEAR, out.items[1]);
}

test "appendModifiers - skips formats absent from the blob" {
    const blob = testInFormatsBlob();
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try appendModifiers(&blob, 0x30335258, testing.allocator, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

fn testInFormatsBlob() [56]u8 {
    var blob: [56]u8 = undefined;
    @memset(&blob, 0);
    const header = ModifierBlob{
        .version = FORMAT_BLOB_CURRENT,
        .flags = 0,
        .count_formats = 2,
        .formats_offset = @sizeOf(ModifierBlob),
        .count_modifiers = 1,
        .modifiers_offset = @sizeOf(ModifierBlob) + 8,
    };
    @memcpy(blob[0..@sizeOf(ModifierBlob)], std.mem.asBytes(&header));
    const formats = [_]u32{ XRGB8888, ARGB8888 };
    @memcpy(blob[@sizeOf(ModifierBlob)..][0..8], std.mem.sliceAsBytes(&formats));
    const modifier = FormatModifier{
        .formats = 0b11,
        .offset = 0,
        .pad = 0,
        .modifier = MOD_LINEAR,
    };
    @memcpy(blob[header.modifiers_offset..][0..@sizeOf(FormatModifier)], std.mem.asBytes(&modifier));
    return blob;
}
