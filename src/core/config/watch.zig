//! Directory watch via inotify, with mtime polling when inotify is unavailable.

const std = @import("std");
const string = @import("core.string").string;
const linux = std.os.linux;
const testing = @import("../testing.zig");
const toml = @import("toml.zig");

const IN_MODIFY: u32 = 0x00000002;
const IN_ATTRIB: u32 = 0x00000004;
const IN_CLOSE_WRITE: u32 = 0x00000008;
const IN_MOVED_TO: u32 = 0x00000080;
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_MASK: u32 = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE;

/// Watches a single file. `poll` is true only for writes this process did not mark.
pub const Watch = struct {
    gpa: std.mem.Allocator,
    path: string,
    basename: string,
    fd: std.posix.fd_t = -1,
    wd: i32 = -1,
    last_mtime: i96 = 0,
    ignore_mtime: ?i96 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: string) !Watch {
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        var self = Watch{
            .gpa = gpa,
            .path = owned,
            .basename = std.fs.path.basename(owned),
            .last_mtime = statMtime(io, owned),
        };
        self.attach();
        return self;
    }

    pub fn deinit(self: *Watch) void {
        self.detach();
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// Call after this process writes `path` so the matching event is ignored.
    pub fn noteWrite(self: *Watch, io: std.Io) void {
        _ = self.drain();
        self.ignore_mtime = statMtime(io, self.path);
        self.last_mtime = self.ignore_mtime.?;
    }

    /// Returns true when an external modification is observed.
    pub fn poll(self: *Watch, io: std.Io) bool {
        _ = self.drain();
        const mtime = statMtime(io, self.path);
        if (self.ignore_mtime) |ignored| {
            if (mtime == ignored) return false;
            self.ignore_mtime = null;
        }
        if (mtime == self.last_mtime) return false;
        self.last_mtime = mtime;
        return true;
    }

    fn attach(self: *Watch) void {
        const dir_path = std.fs.path.dirname(self.path) orelse ".";
        const flags: u32 = @bitCast(linux.O{ .CLOEXEC = true, .NONBLOCK = true });
        const fd_usize = linux.inotify_init1(flags);
        const fd: isize = @bitCast(fd_usize);
        if (fd < 0) return;
        self.fd = @intCast(fd);
        const dir_z = std.posix.toPosixPath(dir_path) catch {
            self.detach();
            return;
        };
        const wd_usize = linux.inotify_add_watch(self.fd, &dir_z, IN_MASK);
        const wd: isize = @bitCast(wd_usize);
        if (wd < 0) {
            self.detach();
            return;
        }
        self.wd = @intCast(wd);
    }

    fn detach(self: *Watch) void {
        if (self.fd >= 0) {
            std.Io.Threaded.closeFd(self.fd);
            self.fd = -1;
            self.wd = -1;
        }
    }

    fn drain(self: *Watch) bool {
        if (self.fd < 0) return false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var hit = false;
        while (true) {
            const n = std.posix.read(self.fd, &buf) catch break;
            if (n == 0) break;
            if (self.matches(buf[0..n])) hit = true;
        }
        return hit;
    }

    fn matches(self: *const Watch, bytes: []const u8) bool {
        var offset: usize = 0;
        while (offset + @sizeOf(linux.inotify_event) <= bytes.len) {
            var event: linux.inotify_event = undefined;
            @memcpy(std.mem.asBytes(&event), bytes[offset..][0..@sizeOf(linux.inotify_event)]);
            const size = @sizeOf(linux.inotify_event) + event.len;
            if (offset + size > bytes.len) break;
            if (nameEquals(&event, bytes[offset..], self.basename)) return true;
            offset += size;
        }
        return false;
    }
};

fn nameEquals(event: *const linux.inotify_event, bytes: []const u8, basename: string) bool {
    if (event.len == 0) return true;
    const start = @sizeOf(linux.inotify_event);
    if (bytes.len < start + event.len) return false;
    const name = std.mem.sliceTo(bytes[start .. start + event.len], 0);
    return std.mem.eql(u8, name, basename);
}

fn statMtime(io: std.Io, path: string) i96 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

test "watch fires on external write and ignores own save" {
    const gpa = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile(std.testing.io, "config.toml", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "a = 1\n");
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "config.toml", &path_buf);
    const path = path_buf[0..path_len];

    var watch = try Watch.init(gpa, std.testing.io, path);
    defer watch.deinit();
    try testing.expect(!watch.poll(std.testing.io));

    {
        const file = try tmp.dir.createFile(std.testing.io, "config.toml", .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "a = 2\n");
    }
    try testing.expect(watch.poll(std.testing.io));

    try toml.saveBytes(std.testing.io, path, "a = 3\n");
    watch.noteWrite(std.testing.io);
    try testing.expect(!watch.poll(std.testing.io));
}
