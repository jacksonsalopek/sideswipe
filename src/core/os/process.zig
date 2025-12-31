const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const string = @import("core.string").string;

// Import setenv from C
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const Process = struct {
    binary: string,
    args: std.ArrayList(string),
    env: std.ArrayList(EnvVar),
    allocator: std.mem.Allocator,

    // State populated after running
    stdout_data: std.ArrayList(u8),
    stderr_data: std.ArrayList(u8),
    child_pid: ?posix.pid_t = null,
    exit_code: i32 = 0,

    // Optional FDs for async mode
    stdin_fd: ?posix.fd_t = null,
    stdout_fd: ?posix.fd_t = null,
    stderr_fd: ?posix.fd_t = null,

    const Self = @This();

    pub const EnvVar = struct {
        name: string,
        value: string,
    };

    /// Create a new process object (doesn't run yet)
    pub fn init(allocator: std.mem.Allocator, binary: string, args: []const string) !Self {
        var args_list = std.ArrayList(string){};
        try args_list.appendSlice(allocator, args);

        return .{
            .binary = binary,
            .args = args_list,
            .env = std.ArrayList(EnvVar){},
            .allocator = allocator,
            .stdout_data = std.ArrayList(u8){},
            .stderr_data = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.args.deinit(self.allocator);
        self.env.deinit(self.allocator);
        self.stdout_data.deinit(self.allocator);
        self.stderr_data.deinit(self.allocator);
    }

    /// Add an environment variable
    pub fn addEnv(self: *Self, name: string, value: string) !void {
        try self.env.append(self.allocator, .{ .name = name, .value = value });
    }

    /// Set stdin file descriptor (only for async mode)
    pub fn setStdinFd(self: *Self, fd: posix.fd_t) void {
        self.stdin_fd = fd;
    }

    /// Set stdout file descriptor (only for async mode)
    pub fn setStdoutFd(self: *Self, fd: posix.fd_t) void {
        self.stdout_fd = fd;
    }

    /// Set stderr file descriptor (only for async mode)
    pub fn setStderrFd(self: *Self, fd: posix.fd_t) void {
        self.stderr_fd = fd;
    }

    /// Run the process synchronously, capturing stdout and stderr
    pub fn runSync(self: *Self) !void {
        // Create pipes for stdout and stderr
        const stdout_pipe = try posix.pipe();
        errdefer {
            posix.close(stdout_pipe[0]);
            posix.close(stdout_pipe[1]);
        }

        const stderr_pipe = try posix.pipe();
        errdefer {
            posix.close(stderr_pipe[0]);
            posix.close(stderr_pipe[1]);
        }

        const pid = try posix.fork();

        if (pid == 0) {
            // Child process
            posix.close(stdout_pipe[0]);
            posix.close(stderr_pipe[0]);

            // Redirect stdout and stderr
            _ = posix.dup2(stdout_pipe[1], posix.STDOUT_FILENO) catch posix.exit(1);
            _ = posix.dup2(stderr_pipe[1], posix.STDERR_FILENO) catch posix.exit(1);

            // Set environment variables
            for (self.env.items) |env_var| {
                const name_z = self.allocator.dupeZ(u8, env_var.name) catch posix.exit(1);
                defer self.allocator.free(name_z);
                const value_z = self.allocator.dupeZ(u8, env_var.value) catch posix.exit(1);
                defer self.allocator.free(value_z);
                _ = setenv(name_z.ptr, value_z.ptr, 1);
            }

            // Build argv
            var argv = self.allocator.alloc(?[*:0]const u8, self.args.items.len + 2) catch posix.exit(1);
            defer self.allocator.free(argv);

            const binary_z = self.allocator.dupeZ(u8, self.binary) catch posix.exit(1);
            argv[0] = binary_z.ptr;

            for (self.args.items, 1..) |arg, i| {
                const arg_z = self.allocator.dupeZ(u8, arg) catch posix.exit(1);
                argv[i] = arg_z.ptr;
            }
            argv[self.args.items.len + 1] = null;

            // Execute
            const argv_sentinel: [*:null]?[*:0]const u8 = @ptrCast(argv.ptr);
            const result = posix.execvpeZ(binary_z.ptr, argv_sentinel, @ptrCast(std.c.environ));
            _ = result catch posix.exit(1);
            posix.exit(1);
        } else {
            // Parent process
            posix.close(stdout_pipe[1]);
            posix.close(stderr_pipe[1]);

            self.child_pid = pid;

            // Set pipes to non-blocking
            const stdout_flags = try posix.fcntl(stdout_pipe[0], posix.F.GETFL, 0);
            _ = try posix.fcntl(stdout_pipe[0], posix.F.SETFL, stdout_flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));

            const stderr_flags = try posix.fcntl(stderr_pipe[0], posix.F.GETFL, 0);
            _ = try posix.fcntl(stderr_pipe[0], posix.F.SETFL, stderr_flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));

            // Poll for output
            var pollfds = [_]posix.pollfd{
                .{ .fd = stdout_pipe[0], .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = stderr_pipe[0], .events = posix.POLL.IN, .revents = 0 },
            };

            var buffer: [1024]u8 = undefined;

            while (true) {
                const poll_result = posix.poll(&pollfds, 5000) catch |err| {
                    if (err == error.Unexpected) continue;
                    return err;
                };

                // Check for hangup
                var hupped = false;
                for (pollfds) |pfd| {
                    if ((pfd.revents & posix.POLL.HUP) != 0) {
                        hupped = true;
                        break;
                    }
                }

                if (hupped) break;
                if (poll_result == 0) continue; // Timeout

                // Read stdout
                if ((pollfds[0].revents & posix.POLL.IN) != 0) {
                    while (true) {
                        const bytes_read = posix.read(stdout_pipe[0], &buffer) catch |err| {
                            if (err == error.WouldBlock) break;
                            return err;
                        };
                        if (bytes_read == 0) break;
                        try self.stdout_data.appendSlice(self.allocator, buffer[0..bytes_read]);
                    }
                }

                // Read stderr
                if ((pollfds[1].revents & posix.POLL.IN) != 0) {
                    while (true) {
                        const bytes_read = posix.read(stderr_pipe[0], &buffer) catch |err| {
                            if (err == error.WouldBlock) break;
                            return err;
                        };
                        if (bytes_read == 0) break;
                        try self.stderr_data.appendSlice(self.allocator, buffer[0..bytes_read]);
                    }
                }
            }

            // Final reads (non-blocking, so it's ok)
            while (true) {
                const bytes_read = posix.read(stdout_pipe[0], &buffer) catch break;
                if (bytes_read == 0) break;
                try self.stdout_data.appendSlice(self.allocator, buffer[0..bytes_read]);
            }

            while (true) {
                const bytes_read = posix.read(stderr_pipe[0], &buffer) catch break;
                if (bytes_read == 0) break;
                try self.stderr_data.appendSlice(self.allocator, buffer[0..bytes_read]);
            }

            posix.close(stdout_pipe[0]);
            posix.close(stderr_pipe[0]);

            // Wait for child and get exit code
            const wait_result = posix.waitpid(pid, 0);
            self.exit_code = @intCast(wait_result.status);
        }
    }

    /// Run the process asynchronously (detached, reparented to init)
    pub fn runAsync(self: *Self) !void {
        // Create a pipe for communication
        const socket = try posix.pipe();
        errdefer {
            posix.close(socket[0]);
            posix.close(socket[1]);
        }

        const child = try posix.fork();

        if (child == 0) {
            // Child process
            const grandchild = try posix.fork();

            if (grandchild == 0) {
                // Grandchild process
                posix.close(socket[0]);
                posix.close(socket[1]);

                // Build argv
                var argv = self.allocator.alloc(?[*:0]const u8, self.args.items.len + 2) catch posix.exit(1);
                defer self.allocator.free(argv);

                const binary_z = self.allocator.dupeZ(u8, self.binary) catch posix.exit(1);
                argv[0] = binary_z.ptr;

                for (self.args.items, 1..) |arg, i| {
                    const arg_z = self.allocator.dupeZ(u8, arg) catch posix.exit(1);
                    argv[i] = arg_z.ptr;
                }
                argv[self.args.items.len + 1] = null;

                // Set environment variables
                for (self.env.items) |env_var| {
                    const name_z = self.allocator.dupeZ(u8, env_var.name) catch posix.exit(1);
                    defer self.allocator.free(name_z);
                    const value_z = self.allocator.dupeZ(u8, env_var.value) catch posix.exit(1);
                    defer self.allocator.free(value_z);
                    _ = setenv(name_z.ptr, value_z.ptr, 1);
                }

                // Redirect file descriptors if specified
                if (self.stdin_fd) |fd| {
                    _ = posix.dup2(fd, posix.STDIN_FILENO) catch {};
                    posix.close(fd);
                }
                if (self.stdout_fd) |fd| {
                    _ = posix.dup2(fd, posix.STDOUT_FILENO) catch {};
                    posix.close(fd);
                }
                if (self.stderr_fd) |fd| {
                    _ = posix.dup2(fd, posix.STDERR_FILENO) catch {};
                    posix.close(fd);
                }

                // Execute
                const argv_sentinel: [*:null]?[*:0]const u8 = @ptrCast(argv.ptr);
                const result = posix.execvpeZ(binary_z.ptr, argv_sentinel, @ptrCast(std.c.environ));
                _ = result catch posix.exit(0);
                posix.exit(0);
            }

            // Child (not grandchild) - send grandchild PID to parent
            posix.close(socket[0]);
            const grandchild_bytes = std.mem.asBytes(&grandchild);
            _ = posix.write(socket[1], grandchild_bytes) catch {
                posix.close(socket[1]);
                posix.exit(1);
            };
            posix.close(socket[1]);
            posix.exit(0);
        }

        // Parent process
        posix.close(socket[1]);

        var grandchild_pid: posix.pid_t = undefined;
        const grandchild_bytes = std.mem.asBytes(&grandchild_pid);
        const bytes_read = try posix.read(socket[0], grandchild_bytes);
        posix.close(socket[0]);

        if (bytes_read != @sizeOf(posix.pid_t)) {
            _ = posix.waitpid(child, 0);
            return error.AsyncSpawnFailed;
        }

        // Reap child (grandchild is now reparented to init)
        _ = posix.waitpid(child, 0);

        self.child_pid = grandchild_pid;
    }

    /// Get stdout (only populated after runSync)
    pub fn getStdout(self: Self) string {
        return self.stdout_data.items;
    }

    /// Get stderr (only populated after runSync)
    pub fn getStderr(self: Self) string {
        return self.stderr_data.items;
    }

    /// Get the process ID
    pub fn getPid(self: Self) ?posix.pid_t {
        return self.child_pid;
    }

    /// Get exit code (only for sync processes)
    pub fn getExitCode(self: Self) i32 {
        return self.exit_code;
    }
};

test "Process - basic init" {
    const allocator = std.testing.allocator;

    const args = [_]string{"-c"};
    var process = try Process.init(allocator, "/bin/sh", &args);
    defer process.deinit();

    try std.testing.expectEqualStrings("/bin/sh", process.binary);
    try std.testing.expectEqual(@as(usize, 1), process.args.items.len);
}

test "Process - add environment variable" {
    const allocator = std.testing.allocator;

    const args = [_]string{};
    var process = try Process.init(allocator, "/bin/echo", &args);
    defer process.deinit();

    try process.addEnv("TEST_VAR", "test_value");

    try std.testing.expectEqual(@as(usize, 1), process.env.items.len);
    try std.testing.expectEqualStrings("TEST_VAR", process.env.items[0].name);
    try std.testing.expectEqualStrings("test_value", process.env.items[0].value);
}

test "Process - multiple args with spaces" {
    const allocator = std.testing.allocator;

    const args = [_]string{ "-c", "echo", "arg with spaces", "another arg" };
    var process = try Process.init(allocator, "/bin/sh", &args);
    defer process.deinit();

    try std.testing.expectEqual(@as(usize, 4), process.args.items.len);
    try std.testing.expectEqualStrings("arg with spaces", process.args.items[2]);
}

test "Process - getExitCode before run" {
    const allocator = std.testing.allocator;

    const args = [_]string{};
    var process = try Process.init(allocator, "/bin/echo", &args);
    defer process.deinit();

    // Exit code should be 0 before run
    try std.testing.expectEqual(@as(i32, 0), process.getExitCode());
}

test "Process - buffer capacity for large output" {
    const allocator = std.testing.allocator;

    const args = [_]string{};
    var process = try Process.init(allocator, "/bin/echo", &args);
    defer process.deinit();

    // Verify buffers can be allocated
    try std.testing.expectEqual(@as(usize, 0), process.stdout_data.items.len);
    try std.testing.expectEqual(@as(usize, 0), process.stderr_data.items.len);

    // Simulate large append
    try process.stdout_data.ensureTotalCapacity(allocator, 1024 * 1024); // 1MB
    try std.testing.expect(process.stdout_data.capacity >= 1024 * 1024);
}
