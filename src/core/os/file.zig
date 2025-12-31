const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const string = @import("core.string").string;

// F_DUPFD_CLOEXEC constant (not always available in std.posix.F)
const F_DUPFD_CLOEXEC: i32 = 1030;

/// Errors that can occur when reading files
pub const FileError = error{
    FileNotFound,
    AccessDenied,
    IsDirectory,
    OutOfMemory,
    SystemError,
};

/// RAII wrapper for Unix file descriptors
/// Inspired by hyprutils CFileDescriptor
pub const FileDescriptor = struct {
    fd: posix.fd_t = -1,

    const Self = @This();

    /// Create a FileDescriptor from a raw file descriptor
    pub fn init(fd: posix.fd_t) Self {
        return .{ .fd = fd };
    }

    /// Create an invalid FileDescriptor
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
        if (!self.isValid()) return error.InvalidFileDescriptor;
        return posix.fcntl(self.fd, posix.F.GETFD, 0);
    }

    /// Set file descriptor flags
    pub fn setFlags(self: Self, flags: i32) !void {
        if (!self.isValid()) return error.InvalidFileDescriptor;
        _ = try posix.fcntl(self.fd, posix.F.SETFD, flags);
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
pub fn readFileAsString(allocator: std.mem.Allocator, path: string) (FileError || std.fs.File.OpenError || std.fs.File.ReadError)![]u8 {
    // Check if file exists and is accessible
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => FileError.FileNotFound,
            error.AccessDenied => FileError.AccessDenied,
            error.IsDir => FileError.IsDirectory,
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
pub fn readFileAsStringWithLimit(allocator: std.mem.Allocator, path: string, max_size: usize) (FileError || std.fs.File.OpenError || std.fs.File.ReadError)![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => FileError.FileNotFound,
            error.AccessDenied => FileError.AccessDenied,
            error.IsDir => FileError.IsDirectory,
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
    try std.testing.expectError(FileError.FileNotFound, result);
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

test "FileDescriptor - basic operations" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    defer test_file.close();

    const raw_fd = test_file.handle;
    var fd = FileDescriptor.init(raw_fd);

    try std.testing.expect(fd.isValid());
    try std.testing.expectEqual(raw_fd, fd.get());

    // Don't call deinit() since test_file will close it
    const taken = fd.take();
    _ = taken;
}

test "FileDescriptor - invalid descriptor" {
    var fd = FileDescriptor.initInvalid();
    defer fd.deinit();

    try std.testing.expect(!fd.isValid());
    try std.testing.expectEqual(@as(posix.fd_t, -1), fd.get());
}

test "FileDescriptor - take ownership" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = FileDescriptor.init(raw_fd);
    try std.testing.expect(fd.isValid());

    const taken_fd = fd.take();
    try std.testing.expectEqual(raw_fd, taken_fd);
    try std.testing.expect(!fd.isValid());

    // Close the fd we took
    posix.close(taken_fd);
}

test "FileDescriptor - reset" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{});
    const raw_fd = test_file.handle;

    var fd = FileDescriptor.init(raw_fd);
    try std.testing.expect(fd.isValid());

    // Don't close via test_file since fd now owns it
    _ = test_file.handle;

    fd.reset();
    try std.testing.expect(!fd.isValid());
}

test "FileDescriptor - duplicate" {
    var test_dir = std.testing.tmpDir(.{});
    defer test_dir.cleanup();

    const test_file = try test_dir.dir.createFile("test.txt", .{ .read = true });
    defer test_file.close();

    const raw_fd = test_file.handle;
    const fd1 = FileDescriptor.init(raw_fd);

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

test "FileDescriptor - isReadable" {
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

    var fd = FileDescriptor.init(test_file.handle);

    // File should be readable (has content)
    try std.testing.expect(fd.isReadable());

    // Don't call deinit since test_file owns it
    const taken = fd.take();
    _ = taken;
}
