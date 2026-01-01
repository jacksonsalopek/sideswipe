//! Backend management inspired by aquamarine
//! Coordinates multiple backend implementations, session, and allocators

const std = @import("std");
const allocator_mod = @import("allocator.zig");
const session_mod = @import("session.zig");
const misc = @import("misc.zig");

/// Backend type enumeration
pub const Type = enum(u32) {
    wayland = 0,
    drm = 1,
    headless = 2,
    null = 3,
};

/// Backend request mode
pub const RequestMode = enum(u32) {
    /// Backend must be available or error out
    mandatory = 0,
    /// Start backend if available
    if_available = 1,
    /// Use as fallback if IF_AVAILABLE backends fail
    fallback = 2,
};

/// Log level for backend messages
pub const LogLevel = enum(u32) {
    trace = 0,
    debug = 1,
    warning = 2,
    err = 3,
    critical = 4,
};

/// Backend implementation options
pub const ImplementationOptions = struct {
    backend_type: Type = .wayland,
    request_mode: RequestMode = .if_available,
};

/// Backend options
pub const Options = struct {
    log_function: ?*const fn (level: LogLevel, message: []const u8) void = null,
};

/// Poll file descriptor callback
pub const PollFd = struct {
    fd: i32 = -1,
    callback: ?*const fn () void = null,
};

/// Backend implementation interface
pub const IBackendImplementation = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        backend_type: *const fn (ptr: *anyopaque) Type,
        start: *const fn (ptr: *anyopaque) bool,
        poll_fds: *const fn (ptr: *anyopaque) []const PollFd,
        drm_fd: *const fn (ptr: *anyopaque) i32,
        drm_render_node_fd: *const fn (ptr: *anyopaque) i32,
        get_render_formats: *const fn (ptr: *anyopaque) []const misc.DRMFormat,
        on_ready: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn backendType(self: IBackendImplementation) Type {
        return self.vtable.backend_type(self.ptr);
    }

    pub fn start(self: IBackendImplementation) bool {
        return self.vtable.start(self.ptr);
    }

    pub fn pollFds(self: IBackendImplementation) []const PollFd {
        return self.vtable.poll_fds(self.ptr);
    }

    pub fn drmFd(self: IBackendImplementation) i32 {
        return self.vtable.drm_fd(self.ptr);
    }

    pub fn drmRenderNodeFd(self: IBackendImplementation) i32 {
        return self.vtable.drm_render_node_fd(self.ptr);
    }

    pub fn getRenderFormats(self: IBackendImplementation) []const misc.DRMFormat {
        return self.vtable.get_render_formats(self.ptr);
    }

    pub fn onReady(self: IBackendImplementation) void {
        self.vtable.on_ready(self.ptr);
    }

    pub fn deinit(self: IBackendImplementation) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Main backend coordinator
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    options: Options,
    implementation_options: []const ImplementationOptions,
    implementations: std.ArrayList(IBackendImplementation),
    primary_allocator: ?allocator_mod.IAllocator = null,
    session: ?*session_mod.Session = null,
    ready: bool = false,
    idle_fd: i32 = -1,

    const Self = @This();

    /// Create a new backend with the given implementations and options
    pub fn create(
        allocator: std.mem.Allocator,
        backends: []const ImplementationOptions,
        options: Options,
    ) !*Self {
        if (backends.len == 0) {
            return error.NoBackendsSpecified;
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .options = options,
            .implementation_options = backends,
            .implementations = std.ArrayList(IBackendImplementation){},
        };

        // Create timerfd for idle events
        const linux = std.os.linux;
        const fd_result = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
        self.idle_fd = @intCast(fd_result);

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.implementations.items) |impl| {
            impl.deinit();
        }
        self.implementations.deinit(self.allocator);

        if (self.session) |sess| {
            sess.deinit();
        }

        if (self.idle_fd >= 0) {
            std.posix.close(self.idle_fd);
        }

        self.allocator.destroy(self);
    }

    /// Start all backend implementations
    pub fn start(self: *Self) !bool {
        self.log(.debug, "Starting the backend!");

        var started: usize = 0;

        for (self.implementations.items) |impl| {
            const ok = impl.start();

            if (!ok) {
                self.log(.err, "Backend could not start, enabling fallbacks");

                // Check if this backend is mandatory
                const backend_type = impl.backendType();
                for (self.implementation_options) |opt| {
                    if (opt.backend_type == backend_type and opt.request_mode == .mandatory) {
                        self.log(.critical, "Mandatory backend failed to start, cannot continue!");
                        return false;
                    }
                }
            } else {
                started += 1;
            }
        }

        if (self.implementations.items.len == 0 or started == 0) {
            self.log(.critical, "No backend could be opened");
            return false;
        }

        // Create primary allocator from DRM FD
        for (self.implementations.items) |impl| {
            const fd = impl.drmFd();
            if (fd >= 0) {
                const reopened_fd = self.reopenDrmNode(fd, true);
                if (reopened_fd >= 0) {
                    // TODO: Create GBM allocator with reopened_fd
                    // For now, just close it
                    std.posix.close(reopened_fd);
                    break;
                }
            }
        }

        self.ready = true;

        // Call onReady for all implementations
        for (self.implementations.items) |impl| {
            impl.onReady();
        }

        if (self.session) |sess| {
            sess.onReady();
        }

        return true;
    }

    /// Get all poll file descriptors from implementations and session
    pub fn getPollFds(self: *Self) ![]PollFd {
        var result = std.ArrayList(PollFd).init(self.allocator);
        errdefer result.deinit(self.allocator);

        // Get poll FDs from all implementations
        for (self.implementations.items) |impl| {
            const fds = impl.pollFds();
            for (fds) |fd| {
                try result.append(self.allocator, fd);
            }
        }

        // Get poll FDs from session
        if (self.session) |sess| {
            const fds = try sess.pollFds();
            for (fds) |fd| {
                try result.append(self.allocator, fd);
            }
        }

        // Add idle FD if available
        if (self.idle_fd >= 0) {
            try result.append(self.allocator, .{ .fd = self.idle_fd, .callback = null });
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Get the primary DRM file descriptor
    pub fn drmFd(self: *Self) i32 {
        for (self.implementations.items) |impl| {
            const fd = impl.drmFd();
            if (fd >= 0) {
                return fd;
            }
        }
        return -1;
    }

    /// Get the primary DRM render node file descriptor
    pub fn drmRenderNodeFd(self: *Self) i32 {
        for (self.implementations.items) |impl| {
            const fd = impl.drmRenderNodeFd();
            if (fd >= 0) {
                return fd;
            }
        }
        return -1;
    }

    /// Check if backend has a session
    pub fn hasSession(self: *Self) bool {
        return self.session != null;
    }

    /// Get primary render formats
    pub fn getPrimaryRenderFormats(self: *Self) []const misc.DRMFormat {
        // Prefer DRM and Wayland backends
        for (self.implementations.items) |impl| {
            const backend_type = impl.backendType();
            if (backend_type == .drm or backend_type == .wayland) {
                return impl.getRenderFormats();
            }
        }

        // Fallback to first implementation
        if (self.implementations.items.len > 0) {
            return self.implementations.items[0].getRenderFormats();
        }

        return &[_]misc.DRMFormat{};
    }

    /// Log a message
    pub fn log(self: *Self, level: LogLevel, message: []const u8) void {
        if (self.options.log_function) |log_fn| {
            log_fn(level, message);
        }
    }

    /// Reopen DRM node with proper permissions (for allocator)
    /// Based on wlroots render/allocator/allocator.c for ref-counting reasons
    pub fn reopenDrmNode(self: *Self, drm_fd: i32, allow_render_node: bool) i32 {
        const drm = @cImport({
            @cInclude("xf86drm.h");
            @cInclude("fcntl.h");
        });

        // Check if we're the DRM master
        if (drm.drmIsMaster(drm_fd) != 0) {
            // Try to create an empty lease (only recent kernels support this)
            var lessee_id: u32 = 0;
            const lease_fd = drm.drmModeCreateLease(drm_fd, null, 0, drm.O_CLOEXEC, &lessee_id);

            if (lease_fd >= 0) {
                return lease_fd;
            } else if (lease_fd != -@as(c_int, @intCast(@intFromError(error.INVAL))) and
                lease_fd != -@as(c_int, @intCast(@intFromError(error.OPNOTSUPP))))
            {
                self.log(.err, "drmModeCreateLease failed");
                return -1;
            }
            self.log(.debug, "drmModeCreateLease failed, falling back to open");
        }

        // Get device name
        var name: ?[*:0]u8 = null;
        if (allow_render_node) {
            name = drm.drmGetRenderDeviceNameFromFd(drm_fd);
        }

        if (name == null) {
            // Get primary node name
            name = drm.drmGetDeviceNameFromFd2(drm_fd);
            if (name == null) {
                self.log(.err, "drmGetDeviceNameFromFd2 failed");
                return -1;
            }
        }
        defer std.c.free(name);

        // Open the device
        const new_fd = std.posix.open(
            std.mem.span(name.?),
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        ) catch |err| {
            self.log(.err, "Failed to open DRM node");
            _ = err;
            return -1;
        };

        // Authenticate if using DRM primary node and we're master
        if (drm.drmIsMaster(drm_fd) != 0 and
            drm.drmGetNodeTypeFromFd(new_fd) == drm.DRM_NODE_PRIMARY)
        {
            var magic: drm.drm_magic_t = 0;

            const get_result = drm.drmGetMagic(new_fd, &magic);
            if (get_result < 0) {
                self.log(.err, "drmGetMagic failed");
                std.posix.close(new_fd);
                return -1;
            }

            const auth_result = drm.drmAuthMagic(drm_fd, magic);
            if (auth_result < 0) {
                self.log(.err, "drmAuthMagic failed");
                std.posix.close(new_fd);
                return -1;
            }
        }

        return new_fd;
    }
};

// Tests
test "Backend - ImplementationOptions defaults" {
    const testing = std.testing;

    const opts: ImplementationOptions = .{};
    try testing.expectEqual(Type.wayland, opts.backend_type);
    try testing.expectEqual(RequestMode.if_available, opts.request_mode);
}

test "Backend - Options initialization" {
    const testing = std.testing;

    const opts: Options = .{};
    try testing.expect(opts.log_function == null);
}

test "Backend - Type enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 0), @intFromEnum(Type.wayland));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(Type.drm));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(Type.headless));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(Type.null));
}

test "Backend - RequestMode enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 0), @intFromEnum(RequestMode.mandatory));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(RequestMode.if_available));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(RequestMode.fallback));
}

test "Backend - LogLevel enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 0), @intFromEnum(LogLevel.trace));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(LogLevel.debug));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(LogLevel.warning));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(LogLevel.err));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(LogLevel.critical));
}

test "Coordinator - create with no backends fails" {
    const testing = std.testing;

    const backends = [_]ImplementationOptions{};
    const opts: Options = .{};

    const result = Coordinator.create(testing.allocator, &backends, opts);
    try testing.expectError(error.NoBackendsSpecified, result);
}

test "Coordinator - create and destroy" {
    const testing = std.testing;

    const backends = [_]ImplementationOptions{
        .{ .backend_type = .headless, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    try testing.expect(!coordinator.ready);
    try testing.expect(coordinator.session == null);
    try testing.expectEqual(@as(usize, 0), coordinator.implementations.items.len);
}

test "Coordinator - drmFd returns -1 when no implementations" {
    const testing = std.testing;

    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    try testing.expectEqual(@as(i32, -1), coordinator.drmFd());
}

test "Coordinator - hasSession initially false" {
    const testing = std.testing;

    const backends = [_]ImplementationOptions{
        .{ .backend_type = .drm, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    try testing.expect(!coordinator.hasSession());
}
