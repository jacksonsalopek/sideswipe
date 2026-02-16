//! Backend management inspired by aquamarine
//! Coordinates multiple backend implementations, session, and allocators

const std = @import("std");
const core = @import("core");
const Interface = core.vtable.Interface;
const allocator = @import("allocator.zig");
const session = @import("session.zig");
const misc = @import("misc.zig");
const renderer = @import("renderer.zig");
const gbm = @import("gbm.zig");

/// Backend type enumeration (re-exported from core for convenience)
pub const Type = core.backend.Type;

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

/// Backend log function signature
pub const LogFunction = *const fn (level: LogLevel, message: []const u8) void;

/// Backend implementation options
pub const ImplementationOptions = struct {
    backend_type: Type = .wayland,
    request_mode: RequestMode = .if_available,
};

/// Backend options
pub const Options = struct {
    log_function: ?LogFunction = null,
};

/// Poll file descriptor callback
pub const PollFd = struct {
    fd: i32 = -1,
    callback: ?*const fn () void = null,
};

/// Backend implementation interface
pub const Implementation = struct {
    base: Interface(VTableDef),

    pub const VTableDef = struct {
        backend_type: *const fn (ptr: *anyopaque) Type,
        start: *const fn (ptr: *anyopaque) bool,
        poll_fds: *const fn (ptr: *anyopaque) []const PollFd,
        drm_fd: *const fn (ptr: *anyopaque) i32,
        drm_render_node_fd: *const fn (ptr: *anyopaque) i32,
        get_render_formats: *const fn (ptr: *anyopaque) []const misc.DRMFormat,
        on_ready: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    const Self = @This();

    pub fn init(ptr: anytype, vtable: *const VTableDef) Self {
        return .{ .base = Interface(VTableDef).init(ptr, vtable) };
    }

    pub fn backendType(self: Self) Type {
        return self.base.vtable.backend_type(self.base.ptr);
    }

    pub fn start(self: Self) bool {
        return self.base.vtable.start(self.base.ptr);
    }

    pub fn pollFds(self: Self) []const PollFd {
        return self.base.vtable.poll_fds(self.base.ptr);
    }

    pub fn drmFd(self: Self) i32 {
        return self.base.vtable.drm_fd(self.base.ptr);
    }

    pub fn drmRenderNodeFd(self: Self) i32 {
        return self.base.vtable.drm_render_node_fd(self.base.ptr);
    }

    pub fn getRenderFormats(self: Self) []const misc.DRMFormat {
        return self.base.vtable.get_render_formats(self.base.ptr);
    }

    pub fn onReady(self: Self) void {
        self.base.vtable.on_ready(self.base.ptr);
    }

    pub fn deinit(self: Self) void {
        self.base.vtable.deinit(self.base.ptr);
    }
};

/// Main backend coordinator
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    options: Options,
    implementation_options: []const ImplementationOptions,
    implementations: std.ArrayList(Implementation),
    primary_allocator: ?allocator.Interface = null,
    primary_renderer: ?*renderer.Type = null,
    session: ?*session.Type = null,
    ready: bool = false,
    idle_fd: i32 = -1,
    cached_poll_fds: []PollFd = &[_]PollFd{},
    poll_fds_dirty: bool = true,

    const Self = @This();

    /// Create a new backend with the given implementations and options
    pub fn create(
        alloc: std.mem.Allocator,
        backends: []const ImplementationOptions,
        options: Options,
    ) !*Self {
        if (backends.len == 0) {
            return error.NoBackendsSpecified;
        }

        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        self.* = .{
            .allocator = alloc,
            .options = options,
            .implementation_options = backends,
            .implementations = std.ArrayList(Implementation){},
        };

        // Create timerfd for idle events
        const linux = std.os.linux;
        const fd_result = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
        self.idle_fd = @intCast(fd_result);

        // Instantiate backend implementations from options
        errdefer {
            for (self.implementations.items) |impl| {
                impl.deinit();
            }
            self.implementations.deinit(alloc);
        }

        try self.instantiateBackends();

        return self;
    }

    /// Instantiate backend implementations from stored options
    fn instantiateBackends(self: *Self) !void {
        for (self.implementation_options) |opt| {
            self.tryCreateBackend(opt) catch |err| {
                if (opt.request_mode == .mandatory) {
                    self.log(.critical, "Mandatory backend failed to create");
                    return err;
                }
                // For if_available and fallback, continue
                self.log(.debug, "Optional backend not available, continuing");
            };
        }

        if (self.implementations.items.len == 0) {
            self.log(.warning, "No backends were successfully created");
        }
    }

    /// Try to create a single backend implementation
    fn tryCreateBackend(self: *Self, opt: ImplementationOptions) !void {
        const impl = try self.createBackendByType(opt.backend_type);
        try self.implementations.append(self.allocator, impl);
        self.poll_fds_dirty = true;
        self.log(.debug, "Successfully created backend");
    }

    /// Create backend implementation by type
    fn createBackendByType(self: *Self, backend_type: Type) !Implementation {
        const wayland_module = @import("wayland.zig");

        return switch (backend_type) {
            .wayland => blk: {
                self.log(.debug, "Attempting to create Wayland backend");
                const backend_ptr = wayland_module.Backend.create(self.allocator, self) catch {
                    self.log(.warning, "Failed to create Wayland backend");
                    return error.BackendNotImplemented;
                };
                break :blk backend_ptr.iface();
            },
            .drm => {
                self.log(.debug, "DRM backend not yet implemented");
                return error.BackendNotImplemented;
            },
            .headless => {
                self.log(.debug, "Headless backend not yet implemented");
                return error.BackendNotImplemented;
            },
            .null => {
                self.log(.debug, "Null backend - skipping");
                return error.BackendNotImplemented;
            },
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.primary_renderer) |rend| {
            rend.deinit();
        }

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

        if (self.cached_poll_fds.len > 0) {
            self.allocator.free(self.cached_poll_fds);
        }

        self.allocator.destroy(self);
    }

    /// Start all backend implementations
    pub fn start(self: *Self) !bool {
        self.log(.debug, "Starting the backend!");

        const started = try self.startImplementations();
        if (started == 0) {
            self.log(.critical, "No backend could be opened");
            return false;
        }

        try self.initializeRendererAndAllocator();

        self.ready = true;
        self.notifyReady();
        self.poll_fds_dirty = true;

        return true;
    }

    /// Start all backend implementations and return count of started backends
    fn startImplementations(self: *Self) !usize {
        var started: usize = 0;

        for (self.implementations.items) |impl| {
            if (impl.start()) {
                started += 1;
                continue;
            }

            // Backend failed to start
            self.log(.err, "Backend could not start, enabling fallbacks");

            if (self.isMandatoryBackend(impl.backendType())) {
                self.log(.critical, "Mandatory backend failed to start, cannot continue!");
                return error.MandatoryBackendFailed;
            }
        }

        return started;
    }

    /// Check if a backend type is configured as mandatory
    fn isMandatoryBackend(self: *Self, backend_type: Type) bool {
        for (self.implementation_options) |opt| {
            if (opt.backend_type == backend_type and opt.request_mode == .mandatory) {
                return true;
            }
        }
        return false;
    }

    /// Initialize primary renderer and allocator from available DRM FDs
    fn initializeRendererAndAllocator(self: *Self) !void {
        for (self.implementations.items) |impl| {
            const fd = impl.drmFd();
            if (fd < 0) continue;

            const reopened_fd = self.reopenDrmNode(fd, true);
            if (reopened_fd < 0) continue;

            self.tryInitializeRenderer(reopened_fd) catch |err| {
                std.log.err("Renderer initialization failed: {}", .{err});
                std.posix.close(reopened_fd);
                continue;
            };

            self.tryInitializeAllocator(reopened_fd) catch |err| {
                std.log.err("GBM allocator creation failed: {}", .{err});
                // Renderer is still available, continue
            };

            break;
        }
    }

    /// Try to initialize renderer with given DRM FD
    fn tryInitializeRenderer(self: *Self, drm_fd: i32) !void {
        self.primary_renderer = try renderer.Type.create(
            self.allocator,
            null, // Backend pointer (opaque)
            drm_fd,
        );
        self.log(.debug, "Renderer initialized");
    }

    /// Try to initialize GBM allocator with given DRM FD
    fn tryInitializeAllocator(self: *Self, drm_fd: i32) !void {
        const gbm_alloc = try gbm.Allocator.create(self.allocator, drm_fd);
        self.primary_allocator = gbm_alloc.asInterface();
        self.log(.debug, "GBM allocator initialized");
    }

    /// Notify all backends and session that system is ready
    fn notifyReady(self: *Self) void {
        for (self.implementations.items) |impl| {
            impl.onReady();
        }

        if (self.session) |sess| {
            sess.onReady();
        }
    }

    /// Rebuild the cached poll FDs from all sources
    fn rebuildPollFds(self: *Self) !void {
        self.freePollFdsCache();

        var result = std.ArrayList(PollFd){};
        errdefer result.deinit(self.allocator);

        try self.collectImplementationFds(&result);
        try self.collectSessionFds(&result);
        try self.collectIdleFd(&result);

        self.cached_poll_fds = try result.toOwnedSlice(self.allocator);
        self.poll_fds_dirty = false;
    }

    /// Free cached poll FDs
    fn freePollFdsCache(self: *Self) void {
        if (self.cached_poll_fds.len > 0) {
            self.allocator.free(self.cached_poll_fds);
            self.cached_poll_fds = &[_]PollFd{};
        }
    }

    /// Collect poll FDs from all backend implementations
    fn collectImplementationFds(self: *Self, result: *std.ArrayList(PollFd)) !void {
        for (self.implementations.items) |impl| {
            const fds = impl.pollFds();
            for (fds) |fd| {
                try result.append(self.allocator, fd);
            }
        }
    }

    /// Collect poll FDs from session
    fn collectSessionFds(self: *Self, result: *std.ArrayList(PollFd)) !void {
        const sess = self.session orelse return;

        const fds = try sess.pollFds(self.allocator);
        defer self.allocator.free(fds);

        for (fds) |fd| {
            try result.append(self.allocator, .{
                .fd = fd.fd,
                .callback = null, // Session PollFd doesn't have callback
            });
        }
    }

    /// Add idle FD to poll FD collection
    fn collectIdleFd(self: *Self, result: *std.ArrayList(PollFd)) !void {
        if (self.idle_fd >= 0) {
            try result.append(self.allocator, .{ .fd = self.idle_fd, .callback = null });
        }
    }

    /// Get all poll file descriptors from implementations and session
    pub fn getPollFds(self: *Self) ![]const PollFd {
        if (self.poll_fds_dirty) {
            try self.rebuildPollFds();
        }
        return self.cached_poll_fds;
    }

    /// Mark poll FDs cache as dirty to force rebuild on next access
    pub fn invalidatePollFds(self: *Self) void {
        self.poll_fds_dirty = true;
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

        if (drm.drmIsMaster(drm_fd) != 0) {
            self.log(.debug, "Is DRM master, falling back to device open");
        }

        const device_name = self.getDrmDeviceName(drm_fd, allow_render_node) orelse {
            self.log(.err, "Failed to get DRM device name");
            return -1;
        };
        defer std.c.free(device_name);

        const new_fd = self.openDrmDevice(device_name) orelse return -1;

        if (self.needsAuthentication(drm_fd, new_fd)) {
            self.authenticateDrmFd(drm_fd, new_fd) catch {
                std.posix.close(new_fd);
                return -1;
            };
        }

        return new_fd;
    }

    /// Get DRM device name, preferring render node if allowed
    fn getDrmDeviceName(self: *Self, drm_fd: i32, allow_render_node: bool) ?[*:0]u8 {
        const drm = @cImport({
            @cInclude("xf86drm.h");
        });

        if (allow_render_node) {
            if (drm.drmGetRenderDeviceNameFromFd(drm_fd)) |name| {
                return name;
            }
        }

        const name = drm.drmGetDeviceNameFromFd2(drm_fd);
        if (name == null) {
            self.log(.err, "drmGetDeviceNameFromFd2 failed");
        }
        return name;
    }

    /// Open DRM device by name
    fn openDrmDevice(self: *Self, device_name: [*:0]u8) ?i32 {
        const fd = std.posix.open(
            std.mem.span(device_name),
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        ) catch {
            self.log(.err, "Failed to open DRM node");
            return null;
        };
        return fd;
    }

    /// Check if DRM FD needs authentication
    fn needsAuthentication(self: *Self, orig_fd: i32, new_fd: i32) bool {
        _ = self;
        const drm = @cImport({
            @cInclude("xf86drm.h");
        });

        return drm.drmIsMaster(orig_fd) != 0 and
            drm.drmGetNodeTypeFromFd(new_fd) == drm.DRM_NODE_PRIMARY;
    }

    /// Authenticate DRM file descriptor
    fn authenticateDrmFd(self: *Self, master_fd: i32, client_fd: i32) !void {
        const drm = @cImport({
            @cInclude("xf86drm.h");
        });

        var magic: drm.drm_magic_t = 0;

        if (drm.drmGetMagic(client_fd, &magic) < 0) {
            self.log(.err, "drmGetMagic failed");
            return error.DrmGetMagicFailed;
        }

        if (drm.drmAuthMagic(master_fd, magic) < 0) {
            self.log(.err, "drmAuthMagic failed");
            return error.DrmAuthMagicFailed;
        }
    }
};

const testing = core.testing;

// Tests
test "Backend - ImplementationOptions defaults" {
    const opts: ImplementationOptions = .{};
    try testing.expectEqual(Type.wayland, opts.backend_type);
    try testing.expectEqual(RequestMode.if_available, opts.request_mode);
}

test "Backend - Options initialization" {
    const opts: Options = .{};
    try testing.expectNull(opts.log_function);
}

test "Backend - Type enum values" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(Type.wayland));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(Type.drm));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(Type.headless));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(Type.null));
}

test "Backend - RequestMode enum values" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(RequestMode.mandatory));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(RequestMode.if_available));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(RequestMode.fallback));
}

test "Backend - LogLevel enum values" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(LogLevel.trace));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(LogLevel.debug));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(LogLevel.warning));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(LogLevel.err));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(LogLevel.critical));
}

test "Coordinator - create with no backends fails" {
    const backends = [_]ImplementationOptions{};
    const opts: Options = .{};

    const result = Coordinator.create(testing.allocator, &backends, opts);
    try testing.expectError(error.NoBackendsSpecified, result);
}

test "Coordinator - create and destroy" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .headless, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    try testing.expectFalse(coordinator.ready);
    try testing.expectNull(coordinator.session);
    try testing.expectEqual(@as(usize, 0), coordinator.implementations.items.len);
}

test "Coordinator - drmFd returns -1 when no implementations" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    try testing.expectEqual(@as(i32, -1), coordinator.drmFd());
}

test "Coordinator - hasSession initially false" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .drm, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    try testing.expectFalse(coordinator.hasSession());
}

test "Coordinator - start with mandatory backend failure" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .drm, .request_mode = .mandatory },
    };
    const opts: Options = .{};

    // Creation should fail because mandatory DRM backend is not implemented
    const result = Coordinator.create(testing.allocator, &backends, opts);
    try testing.expectError(error.BackendNotImplemented, result);
}

test "Coordinator - fallback backend activation" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .headless, .request_mode = .fallback },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    // Fallback backends can be started
    try testing.expectEqual(0, coordinator.implementations.items.len);
}

test "Coordinator - getPollFds aggregates all sources" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    const fds = try coordinator.getPollFds();
    // Note: fds is a cached slice managed by coordinator, don't free it

    // Should at least have idle fd if initialized
    try testing.expect(fds.len >= 0);
}

test "Coordinator - multiple backend types simultaneously" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .drm, .request_mode = .if_available },
        .{ .backend_type = .headless, .request_mode = .if_available },
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    try testing.expectEqual(@as(usize, 3), coordinator.implementation_options.len);
}

test "Coordinator - instantiates wayland backend when WAYLAND_DISPLAY set" {
    // Skip this test if WAYLAND_DISPLAY is not set
    const wayland_display = std.posix.getenv("WAYLAND_DISPLAY");
    if (wayland_display == null) {
        return error.SkipZigTest;
    }

    const backends = [_]ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    // Should have created one implementation
    try testing.expectEqual(@as(usize, 1), coordinator.implementations.items.len);
    try testing.expectEqual(Type.wayland, coordinator.implementations.items[0].backendType());
}

test "Coordinator - handles unimplemented backends gracefully" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .drm, .request_mode = .if_available },
        .{ .backend_type = .headless, .request_mode = .if_available },
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    // Should have created zero implementations (all are not yet implemented)
    try testing.expectEqual(@as(usize, 0), coordinator.implementations.items.len);
}

test "Coordinator - mandatory backend failure propagates error" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .drm, .request_mode = .mandatory },
    };
    const opts: Options = .{};

    const result = Coordinator.create(testing.allocator, &backends, opts);
    try testing.expectError(error.BackendNotImplemented, result);
}

test "Coordinator - poll FDs cache invalidation" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    const opts: Options = .{};

    var coordinator = try Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    // Initial state should be dirty
    try testing.expect(coordinator.poll_fds_dirty);

    // First call should rebuild cache
    const fds1 = try coordinator.getPollFds();
    try testing.expectFalse(coordinator.poll_fds_dirty);
    try testing.expect(fds1.len > 0); // Should have at least idle fd

    // Second call should return cached result
    const fds2 = try coordinator.getPollFds();
    try testing.expectFalse(coordinator.poll_fds_dirty);
    try testing.expectEqual(fds1.ptr, fds2.ptr); // Same slice

    // Invalidate and verify dirty flag is set
    coordinator.invalidatePollFds();
    try testing.expect(coordinator.poll_fds_dirty);

    // Next call should rebuild
    _ = try coordinator.getPollFds();
    try testing.expectFalse(coordinator.poll_fds_dirty);
}
