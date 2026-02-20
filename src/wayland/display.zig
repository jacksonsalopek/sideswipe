const std = @import("std");
const c = @import("c.zig").c;

pub const Display = struct {
    handle: *c.wl_display,

    pub const Error = error{
        CreateFailed,
        AddSocketFailed,
        InitShmFailed,
        OutOfMemory,
    };

    /// Creates a new Wayland display.
    /// Caller must call deinit() when done.
    pub fn create() Error!Display {
        const handle = c.wl_display_create() orelse return error.CreateFailed;
        return Display{ .handle = handle };
    }

    /// Destroys the display and frees all resources.
    pub fn deinit(self: *Display) void {
        c.wl_display_destroy(self.handle);
    }

    /// Gets the event loop associated with this display.
    pub fn getEventLoop(self: *Display) !*c.wl_event_loop {
        return c.wl_display_get_event_loop(self.handle) orelse error.CreateFailed;
    }

    /// Adds a socket with the given name.
    /// If name is null, uses "wayland-0" by default.
    /// Returns error if socket creation fails (e.g., already in use).
    pub fn addSocket(self: *Display, name: ?[]const u8) Error!void {
        const c_name: ?[*:0]const u8 = if (name) |n| blk: {
            // Allocate null-terminated string for C
            const buf = std.heap.c_allocator.allocSentinel(u8, n.len, 0) catch return error.OutOfMemory;
            @memcpy(buf, n);
            break :blk buf.ptr;
        } else null;
        defer if (c_name) |ptr| std.heap.c_allocator.free(std.mem.span(ptr));

        if (c.wl_display_add_socket(self.handle, c_name) != 0) {
            return error.AddSocketFailed;
        }
    }

    /// Adds a socket with an automatically generated name.
    /// Returns the socket name allocated by wayland-server.
    /// Caller must free the returned slice.
    pub fn addSocketAuto(self: *Display, allocator: std.mem.Allocator) Error![]const u8 {
        const name_ptr = c.wl_display_add_socket_auto(self.handle) orelse return error.AddSocketFailed;
        const name = std.mem.span(name_ptr);
        return allocator.dupe(u8, name) catch return error.OutOfMemory;
    }

    /// Adds a socket using an existing file descriptor.
    pub fn addSocketFd(self: *Display, fd: i32) Error!void {
        if (c.wl_display_add_socket_fd(self.handle, fd) != 0) {
            return error.AddSocketFailed;
        }
    }

    /// Terminates the display event loop.
    /// After calling this, the next call to run() or dispatch will return.
    pub fn terminate(self: *Display) void {
        c.wl_display_terminate(self.handle);
    }

    /// Runs the display event loop until terminate() is called.
    /// This is a blocking call.
    pub fn run(self: *Display) void {
        c.wl_display_run(self.handle);
    }

    /// Flushes pending events to all clients.
    pub fn flushClients(self: *Display) void {
        c.wl_display_flush_clients(self.handle);
    }

    /// Gets the current serial number.
    pub fn getSerial(self: *Display) u32 {
        return c.wl_display_get_serial(self.handle);
    }

    /// Gets the next serial number and increments the counter.
    pub fn nextSerial(self: *Display) u32 {
        return c.wl_display_next_serial(self.handle);
    }

    /// Initializes shared memory support.
    /// Must be called before clients can use wl_shm.
    pub fn initShm(self: *Display) Error!void {
        if (c.wl_display_init_shm(self.handle) != 0) {
            return error.InitShmFailed;
        }
    }

    /// Adds a supported shared memory format.
    /// Common formats: WL_SHM_FORMAT_ARGB8888, WL_SHM_FORMAT_XRGB8888
    pub fn addShmFormat(self: *Display, format: u32) void {
        _ = c.wl_display_add_shm_format(self.handle, format);
    }
};

// Common shared memory formats
pub const WL_SHM_FORMAT_ARGB8888: u32 = 0;
pub const WL_SHM_FORMAT_XRGB8888: u32 = 1;

const testing = @import("core").testing;

test "Display: create and destroy" {
    const display = try Display.create();
    var d = display;
    defer d.deinit();
}

test "Display: add socket auto" {
    const allocator = testing.allocator;
    const test_setup = @import("test_setup.zig");

    var runtime = try test_setup.RuntimeDir.setup(allocator);
    defer runtime.cleanup();

    const display = try Display.create();
    var d = display;
    defer d.deinit();

    const socket_name = try d.addSocketAuto(allocator);
    defer allocator.free(socket_name);

    try testing.expect(socket_name.len > 0);
}

test "Display: serial numbers" {
    const display = try Display.create();
    var d = display;
    defer d.deinit();

    const serial1 = d.nextSerial();
    const serial2 = d.nextSerial();
    const serial3 = d.getSerial();

    try testing.expect(serial2 == serial1 + 1);
    try testing.expect(serial3 == serial2);
}

test "Display: init shm" {
    const display = try Display.create();
    var d = display;
    defer d.deinit();

    try d.initShm();
    d.addShmFormat(WL_SHM_FORMAT_ARGB8888);
    d.addShmFormat(WL_SHM_FORMAT_XRGB8888);
}
