//! Generate PNP ID table from hwdata pnp.ids file
//!
//! This build-time utility parses /usr/share/hwdata/pnp.ids and generates
//! a Zig source file with manufacturer name mappings.

const std = @import("std");
const cli = @import("core.cli");
const Logger = cli.Logger;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var log = Logger.init(allocator);
    defer log.deinit();

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    var arg_iterator = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_iterator.deinit();
    while (arg_iterator.next()) |arg| try args.append(allocator, arg);

    if (args.items.len != 3) {
        log.err("Usage: {s} <pnp.ids> <output.zig>", .{args.items[0]});
        return error.InvalidArgs;
    }

    const pnp_ids_path = args.items[1];
    const output_path = args.items[2];

    // Read pnp.ids
    const pnp_data = try std.Io.Dir.cwd().readFileAlloc(init.io, pnp_ids_path, allocator, .limited(1024 * 1024));
    defer allocator.free(pnp_data);

    // Parse entries
    const Entry = struct { id: [3]u8, name: []const u8 };
    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, pnp_data, '\n');
    while (lines.next()) |line| {
        // Skip comments and empty lines
        if (line.len == 0 or line[0] == '#') continue;

        // Format: "ABC<TAB>Manufacturer Name"
        if (line.len < 4 or line[3] != '\t') continue;

        const id = line[0..3].*;
        const name_start = 4;
        const name = std.mem.trim(u8, line[name_start..], " \t\r");

        try entries.append(allocator, .{ .id = id, .name = name });
    }

    // Sort entries by ID for binary search
    const lessThan = struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, &a.id, &b.id) == .lt;
        }
    }.lt;
    std.mem.sort(Entry, entries.items, {}, lessThan);

    // Generate Zig source as a string
    var output_buf: std.Io.Writer.Allocating = .init(allocator);
    defer output_buf.deinit();

    const writer = &output_buf.writer;

    try writer.writeAll(
        \\//! PNP ID to manufacturer name mapping
        \\//! Auto-generated from hwdata pnp.ids
        \\
        \\const std = @import("std");
        \\
        \\pub const Entry = struct {
        \\    id: [3]u8,
        \\    name: []const u8,
        \\};
        \\
        \\pub const entries = [_]Entry{
        \\
    );

    for (entries.items) |entry| {
        try writer.print("    .{{ .id = .{{ '{c}', '{c}', '{c}' }}, .name = \"{s}\" }},\n", .{ entry.id[0], entry.id[1], entry.id[2], entry.name });
    }

    try writer.writeAll(
        \\};
        \\
        \\/// Lookup manufacturer name by PNP ID using binary search (O(log n))
        \\/// Returns null if not found
        \\///
        \\/// The entries array is sorted at build time for fast binary search.
        \\/// With 2557 entries, worst case is log2(2557) ≈ 11 comparisons.
        \\pub fn lookup(id: [3]u8) ?[]const u8 {
        \\    var left: usize = 0;
        \\    var right: usize = entries.len;
        \\
        \\    while (left < right) {
        \\        const mid = left + (right - left) / 2;
        \\        const cmp = std.mem.order(u8, &entries[mid].id, &id);
        \\
        \\        switch (cmp) {
        \\            .eq => return entries[mid].name,
        \\            .lt => left = mid + 1,
        \\            .gt => right = mid,
        \\        }
        \\    }
        \\
        \\    return null;
        \\}
        \\
    );

    // Write to file
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = writer.buffered() });

    log.info("Generated {d} PNP ID entries to {s}", .{ entries.items.len, output_path });
}
