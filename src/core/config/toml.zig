//! File load and atomic save for untyped TOML documents.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");
const parse = @import("parse.zig");
const encode = @import("encode.zig");
const value = @import("value.zig");

pub const Document = value.Document;
pub const Diagnostics = parse.Diagnostics;

pub const max_bytes: usize = 1024 * 1024;

/// Reads `path` and parses it. Missing or unreadable files return an empty
/// document so callers can fall back to compiled defaults.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: string, diag: *Diagnostics) std.mem.Allocator.Error!Document {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return Document.init(gpa);
    };
    defer gpa.free(contents);
    return parse.parse(gpa, contents, diag);
}

/// Encodes `document` and writes it atomically (temp file + rename).
pub fn save(gpa: std.mem.Allocator, io: std.Io, path: string, document: Document) !void {
    const bytes = try encode.encode(gpa, document.root);
    defer gpa.free(bytes);
    try saveBytes(io, path, bytes);
}

/// Atomically replaces `path` with `bytes`, creating parent directories.
pub fn saveBytes(io: std.Io, path: string, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.replace(io);
}

test "load missing file is an empty document" {
    const gpa = testing.allocator;
    var diag = Diagnostics{};
    var doc = try load(gpa, std.testing.io, "/this/path/does/not/exist.toml", &diag);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.root.map.count());
}

test "save then load round-trips" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const file_path = try std.fmt.allocPrint(gpa, "{s}/config.toml", .{path_buf[0..dir_len]});
    defer gpa.free(file_path);

    var doc = Document.init(gpa);
    defer doc.deinit();
    try doc.setString(&.{ "theme", "appearance" }, "light");
    try doc.setFloat(&.{ "output", "DP-1", "scale" }, 1.5);
    try save(gpa, std.testing.io, file_path, doc);

    var diag = Diagnostics{};
    var loaded = try load(gpa, std.testing.io, file_path, &diag);
    defer loaded.deinit();
    try testing.expectEqualStrings("light", loaded.getString(&.{ "theme", "appearance" }).?);
    try testing.expectEqual(@as(?f64, 1.5), loaded.getFloat(&.{ "output", "DP-1", "scale" }));
}
