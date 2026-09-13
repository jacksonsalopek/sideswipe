//! XDG paths for `$XDG_CONFIG_HOME/sideswipe` and reserved sibling files.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("../testing.zig");
const toml = @import("toml.zig");

pub const app_name = "sideswipe";

pub const files = struct {
    pub const main = "config.toml";
    pub const ring = "ring.toml";
    pub const toolbar = "toolbar.toml";
};

fn nonEmpty(value: ?string) ?string {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return text;
}

/// `$XDG_CONFIG_HOME/sideswipe` or `$HOME/.config/sideswipe`. Caller frees.
pub fn home(gpa: std.mem.Allocator, xdg_home: ?string, home_env: ?string) std.mem.Allocator.Error!?[]u8 {
    if (nonEmpty(xdg_home)) |base| {
        if (!std.Io.Dir.path.isAbsolute(base)) return null;
        return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, app_name });
    }
    if (nonEmpty(home_env)) |base| {
        if (!std.Io.Dir.path.isAbsolute(base)) return null;
        return try std.fmt.allocPrint(gpa, "{s}/.config/{s}", .{ base, app_name });
    }
    return null;
}

/// Full path to a file under the sideswipe config directory. Caller frees.
pub fn resolveFile(
    gpa: std.mem.Allocator,
    xdg_home: ?string,
    home_env: ?string,
    name: string,
) std.mem.Allocator.Error!?[]u8 {
    const base = (try home(gpa, xdg_home, home_env)) orelse return null;
    defer gpa.free(base);
    return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, name });
}

pub fn join(gpa: std.mem.Allocator, directory: string, name: string) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ directory, name });
}

/// Creates `directory` and empty `ring.toml` / `toolbar.toml` if they are missing.
pub fn ensure(gpa: std.mem.Allocator, io: std.Io, directory: string) !void {
    const ring_path = try join(gpa, directory, files.ring);
    defer gpa.free(ring_path);
    const toolbar_path = try join(gpa, directory, files.toolbar);
    defer gpa.free(toolbar_path);
    try writeIfAbsent(io, ring_path);
    try writeIfAbsent(io, toolbar_path);
}

fn writeIfAbsent(io: std.Io, path: string) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try toml.saveBytes(io, path, "");
            return;
        }
        return err;
    };
}

test "home prefers XDG_CONFIG_HOME" {
    const gpa = testing.allocator;
    const path = (try home(gpa, "/xdg", "/home/sideswipe")).?;
    defer gpa.free(path);
    try testing.expectEqualStrings("/xdg/sideswipe", path);
}

test "home falls back to HOME/.config" {
    const gpa = testing.allocator;
    const path = (try resolveFile(gpa, null, "/home/sideswipe", files.main)).?;
    defer gpa.free(path);
    try testing.expectEqualStrings("/home/sideswipe/.config/sideswipe/config.toml", path);
    try testing.expectEqual(@as(?[]u8, null), try home(gpa, "", ""));
}

test "ensure writes empty ring and toolbar placeholders" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const directory = path_buf[0..dir_len];

    try ensure(gpa, std.testing.io, directory);
    try tmp.dir.access(std.testing.io, files.ring, .{});
    try tmp.dir.access(std.testing.io, files.toolbar, .{});
}
