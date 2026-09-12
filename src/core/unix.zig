const std = @import("std");
const posix = std.posix;

pub fn close(fd: posix.fd_t) void {
    std.Io.Threaded.closeFd(fd);
}

pub fn pipe() ![2]posix.fd_t {
    return std.Io.Threaded.pipe2(.{});
}

pub fn read(fd: posix.fd_t, buffer: []u8) !usize {
    while (true) {
        const result = posix.system.read(fd, buffer.ptr, buffer.len);
        switch (posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn write(fd: posix.fd_t, buffer: []const u8) !usize {
    while (true) {
        const result = posix.system.write(fd, buffer.ptr, buffer.len);
        switch (posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn open(path: []const u8, flags: posix.O, mode: posix.mode_t) !posix.fd_t {
    const path_z = try posix.toPosixPath(path);
    const result = posix.system.open(&path_z, flags, mode);
    return switch (posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn ftruncate(fd: posix.fd_t, length: u64) !void {
    const file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    return file.setLength(std.Options.debug_io, length);
}

pub fn fcntl(fd: posix.fd_t, command: c_int, arg: usize) !usize {
    const result = posix.system.fcntl(fd, command, arg);
    return switch (posix.errno(result)) {
        .SUCCESS => result,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) !posix.fd_t {
    const result = posix.system.socket(domain, socket_type, protocol);
    return switch (posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .NFILE => error.SystemFdQuotaExceeded,
        .MFILE => error.ProcessFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn bind(fd: posix.fd_t, address: *const posix.sockaddr, length: posix.socklen_t) !void {
    const result = posix.system.bind(fd, address, length);
    return switch (posix.errno(result)) {
        .SUCCESS => {},
        .ADDRINUSE => error.AddressInUse,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn listen(fd: posix.fd_t, backlog: u31) !void {
    const result = posix.system.listen(fd, backlog);
    return switch (posix.errno(result)) {
        .SUCCESS => {},
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn accept(fd: posix.fd_t, address: ?*posix.sockaddr, length: ?*posix.socklen_t, flags: u32) !posix.fd_t {
    const result = posix.system.accept4(fd, address, length, flags);
    return switch (posix.errno(result)) {
        .SUCCESS => @intCast(result),
        .AGAIN => error.WouldBlock,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn connect(fd: posix.fd_t, address: *const posix.sockaddr, length: posix.socklen_t) !void {
    const result = posix.system.connect(fd, address, length);
    return switch (posix.errno(result)) {
        .SUCCESS => {},
        .CONNREFUSED => error.ConnectionRefused,
        else => |err| posix.unexpectedErrno(err),
    };
}

test "pipe transfers bytes" {
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);

    try std.testing.expectEqual(@as(usize, 1), try write(fds[1], "x"));
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try read(fds[0], &buffer));
    try std.testing.expectEqual(@as(u8, 'x'), buffer[0]);
}
