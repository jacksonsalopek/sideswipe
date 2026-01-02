const std = @import("std");
const Display = @import("display.zig").Display;
const EventLoop = @import("event_loop.zig").EventLoop;
const c = @import("c.zig").c;

/// High-level Wayland server abstraction.
/// Manages display, event loop, and provides a convenient interface
/// for compositor implementations.
pub const Server = struct {
    allocator: std.mem.Allocator,
    display: Display,
    event_loop: EventLoop,
    socket_name: ?[]const u8,

    pub const Error = error{
        InitFailed,
        OutOfMemory,
    } || Display.Error;

    /// Creates a new Wayland server.
    /// If socket_name is null, automatically generates one.
    /// Caller must call deinit() when done.
    pub fn init(allocator: std.mem.Allocator, socket_name: ?[]const u8) Error!Server {
        var display = try Display.create();
        errdefer display.deinit();

        // Get event loop from display
        const loop_handle = try display.getEventLoop();
        const event_loop = EventLoop.wrap(loop_handle);

        // Add socket
        const actual_socket_name = if (socket_name) |name| blk: {
            try display.addSocket(name);
            break :blk try allocator.dupe(u8, name);
        } else blk: {
            break :blk try display.addSocketAuto(allocator);
        };
        errdefer allocator.free(actual_socket_name);

        // Initialize shared memory support
        try display.initShm();
        display.addShmFormat(@import("display.zig").WL_SHM_FORMAT_ARGB8888);
        display.addShmFormat(@import("display.zig").WL_SHM_FORMAT_XRGB8888);

        return Server{
            .allocator = allocator,
            .display = display,
            .event_loop = event_loop,
            .socket_name = actual_socket_name,
        };
    }

    /// Destroys the server and frees all resources.
    pub fn deinit(self: *Server) void {
        if (self.socket_name) |name| {
            self.allocator.free(name);
        }
        self.display.deinit();
    }

    /// Gets the socket name for client connections.
    pub fn getSocketName(self: *Server) []const u8 {
        return self.socket_name orelse "";
    }

    /// Runs the server event loop until terminate() is called.
    pub fn run(self: *Server) void {
        self.display.run();
    }

    /// Terminates the server event loop.
    pub fn terminate(self: *Server) void {
        self.display.terminate();
    }

    /// Dispatches events with a timeout.
    /// Use this for custom event loop integration.
    pub fn dispatch(self: *Server, timeout_ms: i32) !i32 {
        return self.event_loop.dispatch(timeout_ms);
    }

    /// Gets the underlying display handle for advanced usage.
    pub fn getDisplay(self: *Server) *c.wl_display {
        return self.display.handle;
    }

    /// Gets the underlying event loop for adding custom event sources.
    pub fn getEventLoop(self: *Server) *EventLoop {
        return &self.event_loop;
    }
};

const testing = @import("core").testing;

test "Server: init with auto socket" {
    const allocator = testing.allocator;

    var server = try Server.init(allocator, null);
    defer server.deinit();

    const socket_name = server.getSocketName();
    try testing.expect(socket_name.len > 0);
}

test "Server: init with custom socket" {
    const allocator = testing.allocator;

    // Use a unique socket name to avoid conflicts
    const socket_name = "test-socket-12345";
    var server = try Server.init(allocator, socket_name);
    defer server.deinit();

    const actual_name = server.getSocketName();
    try testing.expectEqualStrings(socket_name, actual_name);
}

test "Server: dispatch with timeout" {
    const allocator = testing.allocator;

    var server = try Server.init(allocator, null);
    defer server.deinit();

    // Non-blocking dispatch should work
    const result = try server.dispatch(0);
    try testing.expectEqual(@as(i32, 0), result);
}
