const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const string = @import("core.string").string;

// F_DUPFD_CLOEXEC constant (not always available in std.posix.F)
const F_DUPFD_CLOEXEC: i32 = 1030;

/// Errors that can occur when reading files
pub const Error = error{
    FileNotFound,
    AccessDenied,
    IsDirectory,
    OutOfMemory,
    SystemError,
};

/// RAII wrapper for Unix file descriptors
/// Inspired by hyprutils CDescriptor
pub const Descriptor = struct {
    fd: posix.fd_t = -1,

    const Self = @This();

    /// Create a Descriptor from a raw file descriptor
    pub fn init(fd: posix.fd_t) Self {
        return .{ .fd = fd };
    }

    /// Create an invalid Descriptor
    pub fn initInvalid() Self {
        return .{ .fd = -1 };
    }

    /// Clean up the file descriptor
    pub fn deinit(self: *Self) void {
        self.reset();
    }

    /// Check if the file descriptor is valid
    pub fn isValid(self: Self) bool {
        return self.fd != -1;
    }

    /// Get the raw file descriptor value
    pub fn get(self: Self) posix.fd_t {
        return self.fd;
    }

    /// Get file descriptor flags
    pub fn getFlags(self: Self) !i32 {
        if (!self.isValid()) return error.InvalidDescriptor;
        const result = try posix.fcntl(self.fd, posix.F.GETFD, 0);
        return @intCast(result);
    }

    /// Set file descriptor flags
    pub fn setFlags(self: Self, flags: i32) !void {
        if (!self.isValid()) return error.InvalidDescriptor;
        _ = try posix.fcntl(self.fd, posix.F.SETFD, @as(u32, @intCast(flags)));
    }

    /// Take ownership of the file descriptor, leaving this object invalid
    pub fn take(self: *Self) posix.fd_t {
        const fd = self.fd;
        self.fd = -1;
        return fd;
    }

    /// Reset/close the file descriptor
    pub fn reset(self: *Self) void {
        if (self.fd != -1) {
            posix.close(self.fd);
            self.fd = -1;
        }
    }

    /// Duplicate the file descriptor
    pub fn duplicate(self: Self, flags: i32) !Self {
        if (!self.isValid()) return Self.initInvalid();

        const new_fd = try posix.fcntl(self.fd, flags, 0);
        return Self.init(@intCast(new_fd));
    }

    /// Check if the file descriptor is closed
    pub fn isClosed(self: Self) bool {
        if (!self.isValid()) return true;
        return isClosedFd(self.fd);
    }

    /// Check if the file descriptor is readable
    pub fn isReadable(self: Self) bool {
        return isReadableFd(self.fd);
    }

    /// Check if a raw file descriptor is closed
    pub fn isClosedFd(fd: posix.fd_t) bool {
        var pfd = [_]posix.pollfd{
            .{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const result = posix.poll(&pfd, 0) catch return true;
        if (result < 0) return true;

        return (pfd[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0;
    }

    /// Check if a raw file descriptor is readable
    pub fn isReadableFd(fd: posix.fd_t) bool {
        var pfd = [_]posix.pollfd{
            .{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const result = posix.poll(&pfd, 0) catch return false;
        return result > 0 and (pfd[0].revents & posix.POLL.IN) != 0;
    }
};

/// Read entire file contents as a string
/// Caller owns the returned memory and must free it
pub fn readFileAsString(allocator: std.mem.Allocator, path: string) (Error || std.fs.File.OpenError || std.fs.File.ReadError)![]u8 {
    // Check if file exists and is accessible
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => Error.FileNotFound,
            error.AccessDenied => Error.AccessDenied,
            error.IsDir => Error.IsDirectory,
            else => err,
        };
    };
    defer file.close();

    // Get file size
    const stat = try file.stat();
    const file_size = stat.size;

    // Read entire file
    const contents = try file.readToEndAlloc(allocator, file_size);
    return contents;
}

/// Read entire file contents as a string with a maximum size limit
/// Caller owns the returned memory and must free it
pub fn readFileAsStringWithLimit(allocator: std.mem.Allocator, path: string, max_size: usize) (Error || std.fs.File.OpenError || std.fs.File.ReadError)![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => Error.FileNotFound,
            error.AccessDenied => Error.AccessDenied,
            error.IsDir => Error.IsDirectory,
            else => err,
        };
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, max_size);
    return contents;
}

test "readFileAsString - basic read" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_content = "Hello, World!\nThis is a test file.";

    {
        const test_file = try test_dir.dir.createFile("test.txt", .{});
        defer test_file.close();
        try test_file.writeAll(test_content);
    }

    // Read the file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try test_dir.dir.realpath("test.txt", &path_buf);

    const contents = try readFileAsString(allocator, test_path);
    defer allocator.free(contents);

    try std.testing.expectEqualStrings(test_content, contents);
}

test "readFileAsString - file not found" {
    const allocator = std.testing.allocator;

    const result = readFileAsString(allocator, "/nonexistent/file/path/does/not/exist.txt");
    try std.testing.expectError(Error.FileNotFound, result);
}

test "readFileAsStringWithLimit - respect size limit" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_content = "Hello, World! This is a longer test content.";

    {
        const test_file = try test_dir.dir.createFile("test_limit.txt", .{});
        defer test_file.close();
        try test_file.writeAll(test_content);
    }

    // Read with limit
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try test_dir.dir.realpath("test_limit.txt", &path_buf);

    const contents = try readFileAsStringWithLimit(allocator, test_path, 1024);
    defer allocator.free(contents);

    try std.testing.expectEqualStrings(test_content, contents);
}

test "readFileAsString - empty file" {
    const allocator = std.testing.allocator;

    // Create a temporary empty file
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    {
        const test_file = try test_dir.dir.createFile("empty.txt", .{});
        test_file.close();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try test_dir.dir.realpath("empty.txt", &path_buf);

    const contents = try readFileAsString(allocator, test_path);
    defer allocator.free(contents);

    try std.testing.expectEqual(@as(usize, 0), contents.len);
}

test "Descriptor - basic operations" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    defer test_file.close();

    const raw_fd = test_file.handle;
    var fd = Descriptor.init(raw_fd);

    try std.testing.expect(fd.isValid());
    try std.testing.expectEqual(raw_fd, fd.get());

    // Don't call deinit() since test_file will close it
    const taken = fd.take();
    _ = taken;
}

test "Descriptor - invalid descriptor" {
    var fd = Descriptor.initInvalid();
    defer fd.deinit();

    try std.testing.expect(!fd.isValid());
    try std.testing.expectEqual(@as(posix.fd_t, -1), fd.get());
}

test "Descriptor - take ownership" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = Descriptor.init(raw_fd);
    try std.testing.expect(fd.isValid());

    const taken_fd = fd.take();
    try std.testing.expectEqual(raw_fd, taken_fd);
    try std.testing.expect(!fd.isValid());

    // Close the fd we took
    posix.close(taken_fd);
}

test "Descriptor - reset" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = Descriptor.init(raw_fd);
    try std.testing.expect(fd.isValid());

    // Don't close via test_file since fd now owns it
    _ = test_file.handle;

    fd.reset();
    try std.testing.expect(!fd.isValid());
}

test "Descriptor - duplicate" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{ .read = true });
    defer test_file.close();

    const raw_fd = test_file.handle;
    const fd1 = Descriptor.init(raw_fd);

    // Duplicate with CLOEXEC flag
    var fd2 = try fd1.duplicate(F_DUPFD_CLOEXEC);
    defer fd2.deinit();

    try std.testing.expect(fd2.isValid());
    try std.testing.expect(fd1.get() != fd2.get());

    // Don't call deinit on fd1 since test_file owns it
    var fd1_mut = fd1;
    const taken = fd1_mut.take();
    _ = taken;
}

test "Descriptor - isReadable" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    // Create a file with some content
    {
        const test_file = try test_dir.dir.createFile("test.txt", .{});
        defer test_file.close();
        try test_file.writeAll("test content");
    }

    // Open for reading
    const test_file = try test_dir.dir.openFile("test.txt", .{});
    defer test_file.close();

    var fd = Descriptor.init(test_file.handle);

    // File should be readable (has content)
    try std.testing.expect(fd.isReadable());

    // Don't call deinit since test_file owns it
    const taken = fd.take();
    _ = taken;
}

test "Descriptor - getFlags and setFlags" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    defer test_file.close();

    var fd = Descriptor.init(test_file.handle);
    defer {
        const taken = fd.take();
        _ = taken;
    }

    // Get current flags
    const initial_flags = try fd.getFlags();
    try std.testing.expect(initial_flags >= 0);

    // Try setting flags (FD_CLOEXEC)
    try fd.setFlags(posix.FD_CLOEXEC);
    const new_flags = try fd.getFlags();
    try std.testing.expectEqual(@as(i32, posix.FD_CLOEXEC), new_flags);
}

test "Descriptor - comprehensive duplicate test" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{ .read = true });
    const raw_fd = test_file.handle;

    // fd1 wraps raw_fd but doesn't own it (test_file owns it)
    var fd1 = Descriptor.init(raw_fd);

    // Both should be valid and readable initially
    try std.testing.expect(fd1.isValid());
    try std.testing.expect(fd1.isReadable());

    // Duplicate creates a NEW fd owned by fd2
    var fd2 = try fd1.duplicate(F_DUPFD_CLOEXEC);

    // Both original and duplicate should be valid (different fds)
    try std.testing.expect(fd1.isValid());
    try std.testing.expect(fd1.isReadable());
    try std.testing.expect(fd2.isValid());
    try std.testing.expect(fd2.isReadable());
    try std.testing.expect(fd1.get() != fd2.get());

    // Take ownership from fd2 to fd3 (ownership transfer)
    const fd3_raw = fd2.take();
    var fd3 = Descriptor.init(fd3_raw);

    // fd2 is now invalid (ownership transferred)
    try std.testing.expect(fd1.isValid());
    try std.testing.expect(!fd2.isValid());
    try std.testing.expect(!fd2.isReadable());
    try std.testing.expect(fd3.isValid());
    try std.testing.expect(fd3.isReadable());

    // Check duplicate has FD_CLOEXEC by default
    const fd3_flags = try fd3.getFlags();
    try std.testing.expectEqual(@as(i32, posix.FD_CLOEXEC), fd3_flags);

    // Clean up:
    // - fd3 owns a duplicate fd, will be closed by its deinit
    fd3.deinit();

    // - fd2 was already taken, deinit is a no-op (safe)
    fd2.deinit();

    // - fd1 doesn't own raw_fd, just invalidate without closing
    _ = fd1.take();

    // - test_file closes raw_fd
    test_file.close();
}

test "Descriptor - reset makes non-readable" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = Descriptor.init(raw_fd);
    try std.testing.expect(fd.isValid());

    // Reset should close and make it non-readable
    fd.reset();
    try std.testing.expect(!fd.isValid());
    try std.testing.expect(!fd.isReadable());

    // test_file shouldn't close since fd already did
    _ = test_file.handle;
}

test "Descriptor - isClosed after close" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = Descriptor.init(raw_fd);
    try std.testing.expect(!fd.isClosed());

    fd.reset();
    try std.testing.expect(fd.isClosed());

    _ = test_file.handle;
}

test "Descriptor - double take is safe" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    defer test_file.close();
    const raw_fd = test_file.handle;

    var fd = Descriptor.init(raw_fd);

    // First take
    const taken1 = fd.take();
    try std.testing.expectEqual(raw_fd, taken1);
    try std.testing.expect(!fd.isValid());

    // Second take should return -1
    const taken2 = fd.take();
    try std.testing.expectEqual(@as(posix.fd_t, -1), taken2);
    try std.testing.expect(!fd.isValid());
}

test "Descriptor - deinit after take is safe" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = Descriptor.init(raw_fd);

    // Take ownership
    const taken = fd.take();
    try std.testing.expect(!fd.isValid());

    // Deinit after take should be no-op
    fd.deinit();
    try std.testing.expect(!fd.isValid());

    // Close the taken fd ourselves
    posix.close(taken);

    // test_file shouldn't close since we already did
    _ = test_file.handle;
}

test "Descriptor - multiple duplicates from same source" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    defer test_file.close();
    const raw_fd = test_file.handle;

    var fd1 = Descriptor.init(raw_fd);

    // Create multiple duplicates
    var fd2 = try fd1.duplicate(F_DUPFD_CLOEXEC);
    defer fd2.deinit();

    var fd3 = try fd1.duplicate(F_DUPFD_CLOEXEC);
    defer fd3.deinit();

    var fd4 = try fd1.duplicate(F_DUPFD_CLOEXEC);
    defer fd4.deinit();

    // All should be valid and different
    try std.testing.expect(fd2.isValid());
    try std.testing.expect(fd3.isValid());
    try std.testing.expect(fd4.isValid());

    try std.testing.expect(fd2.get() != fd3.get());
    try std.testing.expect(fd2.get() != fd4.get());
    try std.testing.expect(fd3.get() != fd4.get());

    // Don't deinit fd1 since test_file owns it
    _ = fd1.take();
}

test "Descriptor - reset multiple times is safe" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = Descriptor.init(raw_fd);

    // First reset
    fd.reset();
    try std.testing.expect(!fd.isValid());

    // Second reset should be no-op
    fd.reset();
    try std.testing.expect(!fd.isValid());

    // Third reset
    fd.reset();
    try std.testing.expect(!fd.isValid());

    _ = test_file.handle;
}

test "Descriptor - operations on invalid fd" {
    var fd = Descriptor.initInvalid();

    // All operations should handle invalid fd gracefully
    try std.testing.expect(!fd.isValid());
    try std.testing.expect(!fd.isReadable());
    try std.testing.expect(fd.isClosed());

    // getFlags on invalid should error
    const flags_result = fd.getFlags();
    try std.testing.expectError(error.InvalidDescriptor, flags_result);

    // setFlags on invalid should error
    const set_result = fd.setFlags(posix.FD_CLOEXEC);
    try std.testing.expectError(error.InvalidDescriptor, set_result);

    // duplicate on invalid should return invalid
    const dup = try fd.duplicate(F_DUPFD_CLOEXEC);
    try std.testing.expect(!dup.isValid());

    // reset on invalid is safe
    fd.reset();
    try std.testing.expect(!fd.isValid());

    // deinit on invalid is safe
    fd.deinit();
    try std.testing.expect(!fd.isValid());
}
