//! Shared TOML configuration store.
//!
//! Untyped documents (`Document`, `parse`, `load`, `save`) handle any file.
//! `Config` is the typed sideswipe `config.toml` schema. `Watch` reloads on
//! external edits and ignores writes this process marked with `noteWrite`.

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("testing.zig");

pub const value = @import("config/value.zig");
const parse_mod = @import("config/parse.zig");
const encode_mod = @import("config/encode.zig");
pub const toml = @import("config/toml.zig");
pub const bind = @import("config/bind.zig");
pub const schema = @import("config/schema.zig");
pub const dir = @import("config/dir.zig");
const watch = @import("config/watch.zig");

pub const Document = value.Document;
pub const Table = value.Table;
pub const Array = value.Array;
pub const Value = value.Value;
pub const Diagnostics = parse_mod.Diagnostics;
pub const Config = schema.Config;
pub const Watch = watch.Watch;

pub const parse = parse_mod.parse;
pub const encode = encode_mod.encode;
pub const load = toml.load;
pub const save = toml.save;
pub const saveBytes = toml.saveBytes;

/// Directory of TOML files (`config.toml`, `ring.toml`, `toolbar.toml`, …).
pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: string,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, directory: string) !Store {
        const owned = try gpa.dupe(u8, directory);
        errdefer gpa.free(owned);
        try dir.ensure(gpa, io, owned);
        return .{ .gpa = gpa, .io = io, .directory = owned };
    }

    pub fn deinit(self: *Store) void {
        self.gpa.free(self.directory);
        self.* = undefined;
    }

    pub fn path(self: Store, name: string) ![]u8 {
        return dir.join(self.gpa, self.directory, name);
    }

    pub fn loadFile(self: Store, name: string, diag: *Diagnostics) !Document {
        const file_path = try self.path(name);
        defer self.gpa.free(file_path);
        return toml.load(self.gpa, self.io, file_path, diag);
    }

    pub fn saveFile(self: Store, name: string, document: Document) !void {
        const file_path = try self.path(name);
        defer self.gpa.free(file_path);
        try toml.save(self.gpa, self.io, file_path, document);
    }

    pub fn loadConfig(self: Store) !Config {
        const file_path = try self.path(dir.files.main);
        defer self.gpa.free(file_path);
        return Config.load(self.gpa, self.io, file_path);
    }

    pub fn saveConfig(self: Store, cfg: Config) !void {
        const file_path = try self.path(dir.files.main);
        defer self.gpa.free(file_path);
        try cfg.save(self.gpa, self.io, file_path);
    }

    pub fn watchFile(self: Store, name: string) !Watch {
        const file_path = try self.path(name);
        defer self.gpa.free(file_path);
        return Watch.init(self.gpa, self.io, file_path);
    }
};

test {
    _ = value;
    _ = parse_mod;
    _ = encode_mod;
    _ = toml;
    _ = bind;
    _ = schema;
    _ = @import("config/fraction.zig");
    _ = dir;
    _ = watch;
}

test "store reads and writes arbitrary toml files" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var store = try Store.open(gpa, std.testing.io, path_buf[0..dir_len]);
    defer store.deinit();

    var doc = Document.init(gpa);
    defer doc.deinit();
    try doc.setString(&.{ "ring", "label" }, "Launch");
    try store.saveFile("custom.toml", doc);

    var diag = Diagnostics{};
    var loaded = try store.loadFile("custom.toml", &diag);
    defer loaded.deinit();
    try testing.expectEqualStrings("Launch", loaded.getString(&.{ "ring", "label" }).?);
}

test "store loadConfig saveConfig and watchFile" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var store = try Store.open(gpa, std.testing.io, path_buf[0..dir_len]);
    defer store.deinit();

    var cfg = try Config.parse(gpa,
        \\[theme]
        \\appearance = "dark"
    );
    defer cfg.deinit();
    try store.saveConfig(cfg);

    var loaded = try store.loadConfig();
    defer loaded.deinit();
    try testing.expectEqual(schema.Appearance.dark, loaded.theme.appearance);

    var watched = try store.watchFile(dir.files.main);
    defer watched.deinit();
    try testing.expect(!watched.poll(std.testing.io));
    try store.saveConfig(loaded);
    watched.noteWrite(std.testing.io);
    try testing.expect(!watched.poll(std.testing.io));
}
