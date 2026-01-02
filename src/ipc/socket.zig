//! Unix socket handling for IPC

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const core = @import("core");
const os = @import("core.os");
const FileDescriptor = os.file.Descriptor;
const protocol = @import("protocol.zig");
const message = @import("message.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
});

// Constants from sys/socket.h
const SOL_SOCKET = c.SOL_SOCKET;
const SCM_RIGHTS = c.SCM_RIGHTS;

/// CMSG utilities for control message handling (implementing standard CMSG macros)
const CMSG = struct {
    /// Align value to cmsghdr alignment
    fn align_size(len: usize) usize {
        const alignment: usize = @alignOf(c.cmsghdr);
        return (len + alignment - 1) & ~@as(usize, alignment - 1);
    }

    /// Calculate space needed for control message data
    fn SPACE(len: usize) usize {
        return align_size(@sizeOf(c.cmsghdr)) + align_size(len);
    }

    /// Calculate control message length
    fn LEN(len: usize) usize {
        return align_size(@sizeOf(c.cmsghdr)) + len;
    }

    /// Get first control message header
    fn FIRSTHDR(msg: *const linux.msghdr) ?*c.cmsghdr {
        if (msg.controllen < @sizeOf(c.cmsghdr)) return null;
        return @ptrCast(@alignCast(msg.control));
    }

    /// Get first control message header (const version)
    fn FIRSTHDR_CONST(msg: *const linux.msghdr_const) ?*c.cmsghdr {
        if (msg.controllen < @sizeOf(c.cmsghdr)) return null;
        return @ptrCast(@alignCast(msg.control));
    }

    /// Get data pointer from control message
    fn DATA(cmsg: *c.cmsghdr) [*]u8 {
        const base: [*]u8 = @ptrCast(cmsg);
        return base + align_size(@sizeOf(c.cmsghdr));
    }
};

/// Raw parsed message from socket
pub const RawParsedMessage = struct {
    data: std.ArrayList(u8),
    fds: std.ArrayList(posix.fd_t),
    bad: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RawParsedMessage {
        return .{
            .data = std.ArrayList(u8){},
            .fds = std.ArrayList(posix.fd_t){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RawParsedMessage) void {
        self.data.deinit(self.allocator);
        self.fds.deinit(self.allocator);
    }

    /// Close all file descriptors in this message
    pub fn closeFds(self: *RawParsedMessage) void {
        for (self.fds.items) |fd| {
            posix.close(fd);
        }
        self.fds.clearRetainingCapacity();
    }
};

/// Parse message from file descriptor
/// Reads data in chunks until all available data is consumed
pub fn parseFromFd(fd_wrapper: FileDescriptor, allocator: std.mem.Allocator) !RawParsedMessage {
    const BUFFER_SIZE = 8192;
    const MAX_FDS_PER_MSG = 255;

    if (!fd_wrapper.isValid()) {
        var msg_result = RawParsedMessage.init(allocator);
        msg_result.bad = true;
        return msg_result;
    }

    const fd = fd_wrapper.get();

    var msg_result = RawParsedMessage.init(allocator);
    errdefer msg_result.deinit();

    var buffer: [BUFFER_SIZE]u8 = undefined;
    var size_read: usize = 0;

    // Read in chunks - use MSG_DONTWAIT after first read to avoid blocking
    var first_read = true;
    while (true) {
        var iov = [_]posix.iovec{
            .{
                .base = &buffer,
                .len = BUFFER_SIZE,
            },
        };

        // Allocate control message buffer for FD passing (use comptime max)
        const cmsg_space = comptime CMSG.SPACE(@sizeOf(i32) * MAX_FDS_PER_MSG);
        var cmsg_buf: [cmsg_space]u8 align(@alignOf(c.cmsghdr)) = undefined;

        var msg = linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_space,
            .flags = 0,
        };

        // Use MSG_DONTWAIT for non-blocking after first read
        const flags: u32 = if (first_read) 0 else linux.MSG.DONTWAIT;
        const recv_result = linux.recvmsg(fd, &msg, flags);

        if (@as(isize, @bitCast(recv_result)) < 0) {
            // EAGAIN means no more data available (expected with MSG_DONTWAIT)
            const err_val: usize = @bitCast(-@as(isize, @bitCast(recv_result)));
            if (!first_read and err_val == @intFromEnum(posix.E.AGAIN)) {
                break; // No more data, done reading
            }
            msg_result.bad = true;
            return msg_result;
        }
        size_read = recv_result;
        first_read = false;

        if (size_read == 0) break; // Connection closed

        // Append data to result
        try msg_result.data.appendSlice(allocator, buffer[0..size_read]);

        // Check for control messages (file descriptors)
        if (CMSG.FIRSTHDR(&msg)) |cmsg| {
            if (cmsg.cmsg_level == SOL_SOCKET and cmsg.cmsg_type == SCM_RIGHTS) {
                const fd_data = CMSG.DATA(cmsg);
                const payload_size = cmsg.cmsg_len - CMSG.LEN(0);
                const num_fds = payload_size / @sizeOf(i32);

                const received_fds = std.mem.bytesAsSlice(i32, fd_data[0..payload_size]);

                for (received_fds[0..num_fds]) |received_fd| {
                    try msg_result.fds.append(allocator, received_fd);
                }
            } else if (cmsg.cmsg_level == SOL_SOCKET) {
                // Invalid control message type
                std.debug.print("protocol error on fd {}: invalid control message type {}\n", .{ fd, cmsg.cmsg_type });
                msg_result.bad = true;
                return msg_result;
            }
        }

        // If we read less than BUFFER_SIZE, we're done (no more data available)
        if (size_read < BUFFER_SIZE) break;
    }

    return msg_result;
}

/// Parse message from raw file descriptor (convenience wrapper)
pub fn parseFromRawFd(fd: posix.fd_t, allocator: std.mem.Allocator) !RawParsedMessage {
    return parseFromFd(FileDescriptor.init(fd), allocator);
}

/// Connection for IPC
pub const Connection = struct {
    fd: FileDescriptor,
    allocator: std.mem.Allocator,

    pub fn init(fd: FileDescriptor, allocator: std.mem.Allocator) Connection {
        return .{
            .fd = fd,
            .allocator = allocator,
        };
    }

    /// Create from raw file descriptor
    pub fn initRaw(raw_fd: posix.fd_t, allocator: std.mem.Allocator) Connection {
        return init(FileDescriptor.init(raw_fd), allocator);
    }

    pub fn deinit(self: *Connection) void {
        self.fd.deinit();
    }

    /// Send message bytes
    pub fn send(self: *Connection, data: []const u8) !usize {
        return try posix.write(self.fd.get(), data);
    }

    /// Send message with file descriptors
    pub fn sendWithFds(self: *Connection, data: []const u8, fds: []const posix.fd_t) !usize {
        var iov = [_]posix.iovec_const{
            .{
                .base = data.ptr,
                .len = data.len,
            },
        };

        // Prepare control message for FD passing
        const cmsg_space = CMSG.SPACE(@sizeOf(posix.fd_t) * fds.len);
        var cmsg_buf: [cmsg_space]u8 align(@alignOf(c.cmsghdr)) = undefined;

        var msg = linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_space,
            .flags = 0,
        };

        // Set control message header
        const cmsg = CMSG.FIRSTHDR_CONST(&msg).?;
        cmsg.cmsg_level = SOL_SOCKET;
        cmsg.cmsg_type = SCM_RIGHTS;
        cmsg.cmsg_len = CMSG.LEN(@sizeOf(posix.fd_t) * fds.len);

        // Copy file descriptors
        const fd_data = CMSG.DATA(cmsg);
        @memcpy(fd_data[0 .. @sizeOf(posix.fd_t) * fds.len], std.mem.sliceAsBytes(fds));

        return try linux.sendmsg(self.fd.get(), &msg, 0);
    }

    /// Receive message
    pub fn receive(self: *Connection, buffer: []u8) !usize {
        return try posix.read(self.fd.get(), buffer);
    }

    /// Parse message from this socket
    pub fn parseMessage(self: *Connection) !RawParsedMessage {
        return try parseFromFd(self.fd, self.allocator);
    }

    /// Receive message with file descriptors
    pub fn receiveWithFds(self: *Connection, buffer: []u8, fds: []posix.fd_t) !struct { data_len: usize, fd_count: usize } {
        var iov = [_]posix.iovec{
            .{
                .base = buffer.ptr,
                .len = buffer.len,
            },
        };

        const cmsg_space = CMSG.SPACE(@sizeOf(posix.fd_t) * fds.len);
        var cmsg_buf: [cmsg_space]u8 align(@alignOf(c.cmsghdr)) = undefined;

        var msg = linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_space,
            .flags = 0,
        };

        const recv_len = try linux.recvmsg(self.fd.get(), &msg, 0);

        var fd_count: usize = 0;
        if (CMSG.FIRSTHDR(&msg)) |cmsg| {
            if (cmsg.cmsg_level == SOL_SOCKET and cmsg.cmsg_type == SCM_RIGHTS) {
                const fd_data = CMSG.DATA(cmsg);
                const fd_bytes_len = cmsg.cmsg_len - CMSG.LEN(0);
                const received_fds = std.mem.bytesAsSlice(posix.fd_t, fd_data[0..fd_bytes_len]);

                fd_count = @min(received_fds.len, fds.len);
                @memcpy(fds[0..fd_count], received_fds[0..fd_count]);
            }
        }

        return .{
            .data_len = recv_len,
            .fd_count = fd_count,
        };
    }
};

/// Unix socket server for IPC
pub const Server = struct {
    socket_path: []const u8,
    listen_fd: posix.fd_t,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !Server {
        // Create Unix domain socket
        const fd = try posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        // Remove existing socket file if present
        std.fs.cwd().deleteFile(socket_path) catch {};

        // Bind to socket path
        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return error.ConnectionPathTooLong;
        }

        @memcpy(addr.path[0..socket_path.len], socket_path);
        addr.path[socket_path.len] = 0;

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        // Listen for connections
        try posix.listen(fd, 128);

        return .{
            .socket_path = socket_path,
            .listen_fd = fd,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.listen_fd);
        // Clean up socket file
        std.fs.cwd().deleteFile(self.socket_path) catch {};
    }

    /// Accept a new client connection
    pub fn accept(self: *Server) !Connection {
        const client_fd = try posix.accept(
            self.listen_fd,
            null,
            null,
            posix.SOCK.CLOEXEC,
        );

        return Connection.init(FileDescriptor.init(client_fd), self.allocator);
    }
};

/// Unix socket client for IPC
pub const Client = struct {
    socket: Connection,

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8) !Client {
        const fd = try posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        var addr = posix.sockaddr.un{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return error.ConnectionPathTooLong;
        }

        @memcpy(addr.path[0..socket_path.len], socket_path);
        addr.path[socket_path.len] = 0;

        try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        return .{
            .socket = Connection.init(FileDescriptor.init(fd), allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.socket.deinit();
    }

    pub fn send(self: *Client, data: []const u8) !usize {
        return self.socket.send(data);
    }

    pub fn receive(self: *Client, buffer: []u8) !usize {
        return self.socket.receive(buffer);
    }
};

const testing = core.testing;

// Tests
test "Connection - basic send/receive" {
    // Create a socketpair for testing using syscall
    var fds: [2]i32 = undefined;
    const result = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM,
        0,
        &fds,
    );
    if (result != 0) return error.ConnectionpairFailed;

    var sock1 = Connection.initRaw(fds[0], testing.allocator);
    defer sock1.deinit();
    var sock2 = Connection.initRaw(fds[1], testing.allocator);
    defer sock2.deinit();

    // Send message
    const test_msg = "Hello, IPC!";
    const sent = try sock1.send(test_msg);
    try testing.expectEqual(test_msg.len, sent);

    // Receive message
    var buffer: [1024]u8 = undefined;
    const received = try sock2.receive(&buffer);
    try testing.expectEqual(test_msg.len, received);
    try testing.expectEqualStrings(test_msg, buffer[0..received]);
}

test "Server - init and deinit" {
    const socket_path = "/tmp/sideswipe_test.sock";

    var server = try Server.init(testing.allocator, socket_path);
    defer server.deinit();

    try testing.expectEqualStrings(socket_path, server.socket_path);
}

test "RawParsedMessage - init and deinit" {
    var msg = RawParsedMessage.init(testing.allocator);
    defer msg.deinit();

    try testing.expectEqual(0, msg.data.items.len);
    try testing.expectEqual(0, msg.fds.items.len);
    try testing.expectFalse(msg.bad);
}

test "RawParsedMessage - append data" {
    var msg = RawParsedMessage.init(testing.allocator);
    defer msg.deinit();

    const test_data = "Hello, IPC!";
    try msg.data.appendSlice(testing.allocator, test_data);

    try testing.expectEqual(test_data.len, msg.data.items.len);
    try testing.expectEqualStrings(test_data, msg.data.items);
}

test "parseFromFd - basic data" {
    // Create a socketpair for testing
    var fds: [2]i32 = undefined;
    const result = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM,
        0,
        &fds,
    );
    if (result != 0) return error.ConnectionpairFailed;

    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    // Send test data
    const test_msg = "Test message for parseFromFd";
    const sent = try posix.write(fds[0], test_msg);
    try testing.expectEqual(test_msg.len, sent);

    // Parse from receiving end using FileDescriptor wrapper
    var parsed = try parseFromFd(FileDescriptor.init(fds[1]), testing.allocator);
    defer parsed.deinit();

    try testing.expectFalse(parsed.bad);
    try testing.expectEqual(test_msg.len, parsed.data.items.len);
    try testing.expectEqualStrings(test_msg, parsed.data.items);
    try testing.expectEqual(@as(usize, 0), parsed.fds.items.len);
}

test "parseFromFd - large data in chunks" {
    var fds: [2]i32 = undefined;
    const result = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM,
        0,
        &fds,
    );
    if (result != 0) return error.ConnectionpairFailed;

    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    // Send large message (bigger than BUFFER_SIZE)
    const large_size = 16384; // 2x BUFFER_SIZE
    const large_data = try testing.allocator.alloc(u8, large_size);
    defer testing.allocator.free(large_data);

    // Fill with pattern
    for (large_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const sent = try posix.write(fds[0], large_data);
    try testing.expectEqual(large_size, sent);

    // Parse from receiving end using FileDescriptor wrapper
    var parsed = try parseFromFd(FileDescriptor.init(fds[1]), testing.allocator);
    defer parsed.deinit();

    try testing.expectFalse(parsed.bad);
    try testing.expectEqual(large_size, parsed.data.items.len);
    try testing.expectEqualSlices(u8, large_data, parsed.data.items);
}

test "Connection - parseMessage integration" {
    var fds: [2]i32 = undefined;
    const result = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM,
        0,
        &fds,
    );
    if (result != 0) return error.ConnectionpairFailed;

    defer posix.close(fds[0]);

    var sock = Connection.initRaw(fds[1], testing.allocator);
    defer sock.deinit();

    // Send test data
    const test_msg = "Connection parseMessage test";
    _ = try posix.write(fds[0], test_msg);

    // Parse using Connection method
    var parsed = try sock.parseMessage();
    defer parsed.deinit();

    try testing.expectFalse(parsed.bad);
    try testing.expectEqualStrings(test_msg, parsed.data.items);
}

test "FileDescriptor - integration with parseFromFd" {
    var fds: [2]i32 = undefined;
    const result = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM,
        0,
        &fds,
    );
    if (result != 0) return error.ConnectionpairFailed;

    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    // Send test data
    const test_msg = "FileDescriptor test";
    _ = try posix.write(fds[0], test_msg);

    // Use FileDescriptor wrapper
    const fd_wrapper = FileDescriptor.init(fds[1]);
    try testing.expect(fd_wrapper.isValid());
    try testing.expectEqual(fds[1], fd_wrapper.get());

    // Parse using FileDescriptor
    var parsed = try parseFromFd(fd_wrapper, testing.allocator);
    defer parsed.deinit();

    try testing.expectFalse(parsed.bad);
    try testing.expectEqualStrings(test_msg, parsed.data.items);
}

test "RawParsedMessage - closeFds" {
    var msg = RawParsedMessage.init(testing.allocator);
    defer msg.deinit();

    // Create some dummy FDs (pipes)
    const pipe_fds = try posix.pipe();

    try msg.fds.append(testing.allocator, pipe_fds[0]);
    try msg.fds.append(testing.allocator, pipe_fds[1]);

    try testing.expectEqual(@as(usize, 2), msg.fds.items.len);

    // Close all FDs
    msg.closeFds();
    try testing.expectEqual(@as(usize, 0), msg.fds.items.len);
}
