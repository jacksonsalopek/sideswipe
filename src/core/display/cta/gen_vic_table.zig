//! Generate VIC timing table from libdisplay-info C source
//!
//! This parses cta-vic-table.c and generates a Zig lookup table.

const std = @import("std");
const logger_mod = @import("logger");
const Logger = logger_mod.Logger;

const VicEntry = struct {
    code: u8,
    h_active: u16,
    v_active: u16,
    interlaced: bool,
    pixel_clock_hz: u64,
    h_front: u16,
    h_sync: u16,
    h_back: u16,
    v_front: u16,
    v_sync: u16,
    v_back: u16,
    aspect_ratio: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var log = Logger.init(allocator);
    defer log.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        log.err("Usage: {s} <cta-vic-table.c> <output.zig>", .{args[0]});
        return error.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];

    // Read C file
    const c_data = try std.fs.cwd().readFileAlloc(allocator, input_path, 10 * 1024 * 1024);
    defer allocator.free(c_data);

    // Parse VIC entries (simple line-by-line parsing)
    var vics = std.AutoHashMap(u8, VicEntry).init(allocator);
    defer vics.deinit();

    var lines = std.mem.tokenizeScalar(u8, c_data, '\n');
    var current_vic: ?u8 = null;
    var current_entry = VicEntry{
        .code = 0,
        .h_active = 0,
        .v_active = 0,
        .interlaced = false,
        .pixel_clock_hz = 0,
        .h_front = 0,
        .h_sync = 0,
        .h_back = 0,
        .v_front = 0,
        .v_sync = 0,
        .v_back = 0,
        .aspect_ratio = "16:9",
    };

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        
        // Start of new entry: [XX] = {
        if (std.mem.startsWith(u8, trimmed, "[") and std.mem.containsAtLeast(u8, trimmed, 1, "] = {")) {
            // Extract VIC code
            var iter = std.mem.tokenizeAny(u8, trimmed, "[]");
            if (iter.next()) |vic_str| {
                current_vic = std.fmt.parseInt(u8, vic_str, 10) catch null;
                if (current_vic) |vic| {
                    current_entry.code = vic;
                }
            }
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".code =")) {
            // .vic = { .code = XX }
            var iter = std.mem.tokenizeAny(u8, trimmed, " =,");
            while (iter.next()) |token| {
                const vic = std.fmt.parseInt(u8, token, 10) catch continue;
                current_entry.code = vic;
                break;
            }
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".h_active =")) {
            current_entry.h_active = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".v_active =")) {
            current_entry.v_active = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".interlaced =")) {
            current_entry.interlaced = std.mem.containsAtLeast(u8, trimmed, 1, "true");
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".pixel_clock_hz =")) {
            current_entry.pixel_clock_hz = parseValue(u64, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".h_front =")) {
            current_entry.h_front = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".h_sync =")) {
            current_entry.h_sync = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".h_back =")) {
            current_entry.h_back = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".v_front =")) {
            current_entry.v_front = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".v_sync =")) {
            current_entry.v_sync = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, ".v_back =")) {
            current_entry.v_back = parseValue(u16, trimmed);
        } else if (std.mem.containsAtLeast(u8, trimmed, 1, "picture_aspect_ratio")) {
            if (std.mem.containsAtLeast(u8, trimmed, 1, "4_3")) {
                current_entry.aspect_ratio = "4:3";
            } else if (std.mem.containsAtLeast(u8, trimmed, 1, "64_27")) {
                current_entry.aspect_ratio = "64:27";
            } else if (std.mem.containsAtLeast(u8, trimmed, 1, "256_135")) {
                current_entry.aspect_ratio = "256:135";
            } else {
                current_entry.aspect_ratio = "16:9";
            }
        } else if (std.mem.startsWith(u8, trimmed, "},")) {
            // End of entry
            if (current_vic) |vic| {
                try vics.put(vic, current_entry);
                current_vic = null;
            }
        }
    }

    // Generate Zig file
    var output_buf = std.ArrayList(u8){};
    defer output_buf.deinit(allocator);

    const writer = output_buf.writer(allocator);

    try writer.writeAll(
        \\//! CTA-861 VIC timing database
        \\//! Auto-generated from libdisplay-info cta-vic-table.c
        \\
        \\const std = @import("std");
        \\
        \\pub const AspectRatio = enum {
        \\    @"4:3",
        \\    @"16:9",
        \\    @"64:27",
        \\    @"256:135",
        \\};
        \\
        \\pub const Timing = struct {
        \\    vic: u8,
        \\    h_active: u16,
        \\    v_active: u16,
        \\    interlaced: bool,
        \\    pixel_clock_hz: u64,
        \\    h_front: u16,
        \\    h_sync: u16,
        \\    h_back: u16,
        \\    v_front: u16,
        \\    v_sync: u16,
        \\    v_back: u16,
        \\    aspect_ratio: AspectRatio,
        \\};
        \\
        \\const entries = [_]Timing{
        \\
    );

    // Write all VIC entries (sorted by VIC code)
    var vic_codes = std.ArrayList(u8){};
    defer vic_codes.deinit(allocator);

    var iter = vics.keyIterator();
    while (iter.next()) |vic| {
        try vic_codes.append(allocator, vic.*);
    }

    std.mem.sort(u8, vic_codes.items, {}, std.sort.asc(u8));

    for (vic_codes.items) |vic| {
        const entry = vics.get(vic).?;
        try writer.print(
            \\    // VIC {d}: {d}x{d}{s}
            \\    .{{ .vic = {d}, .h_active = {d}, .v_active = {d}, .interlaced = {}, .pixel_clock_hz = {d}, .h_front = {d}, .h_sync = {d}, .h_back = {d}, .v_front = {d}, .v_sync = {d}, .v_back = {d}, .aspect_ratio = .@"{s}" }},
            \\
        , .{
            vic,
            entry.h_active,
            entry.v_active,
            if (entry.interlaced) "i" else "p",
            vic,
            entry.h_active,
            entry.v_active,
            entry.interlaced,
            entry.pixel_clock_hz,
            entry.h_front,
            entry.h_sync,
            entry.h_back,
            entry.v_front,
            entry.v_sync,
            entry.v_back,
            entry.aspect_ratio,
        });
    }

    try writer.writeAll(
        \\};
        \\
        \\/// Lookup VIC timing by code (O(log n) binary search)
        \\pub fn lookup(vic: u8) ?Timing {
        \\    if (vic == 0) return null;
        \\    
        \\    // Binary search
        \\    var left: usize = 0;
        \\    var right: usize = entries.len;
        \\    
        \\    while (left < right) {
        \\        const mid = left + (right - left) / 2;
        \\        const entry_vic = entries[mid].vic;
        \\        
        \\        if (entry_vic == vic) {
        \\            return entries[mid];
        \\        } else if (entry_vic < vic) {
        \\            left = mid + 1;
        \\        } else {
        \\            right = mid;
        \\        }
        \\    }
        \\    
        \\    return null;
        \\}
        \\
        \\/// Get common VIC name
        \\pub fn getCommonName(vic: u8) ?[]const u8 {
        \\    return switch (vic) {
        \\        1 => "640x480p60",
        \\        4 => "1280x720p60",
        \\        16 => "1920x1080p60",
        \\        31 => "1920x1080p50",
        \\        93 => "3840x2160p24",
        \\        95 => "3840x2160p30",
        \\        97 => "3840x2160p60",
        \\        else => null,
        \\    };
        \\}
        \\
    );

    // Write to file
    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = output_buf.items });

    log.info("Generated {d} VIC entries to {s}", .{ vics.count(), output_path });
}

fn parseValue(comptime T: type, line: []const u8) T {
    var iter = std.mem.tokenizeAny(u8, line, " =,");
    while (iter.next()) |token| {
        if (std.fmt.parseInt(T, token, 10)) |val| {
            return val;
        } else |_| {
            continue;
        }
    }
    return 0;
}
