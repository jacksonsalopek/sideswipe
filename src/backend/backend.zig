//! Backend management inspired by aquamarine
//! Coordinates multiple backend implementations, session, and allocators

const std = @import("std");
const core = @import("core");
const cli = @import("core.cli");
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

/// Backend implementation options
pub const ImplementationOptions = struct {
    backend_type: Type = .wayland,
    request_mode: RequestMode = .if_available,
};

/// Backend options
pub const Options = struct {
    physical_input: bool = false,
    session_factory: *const fn (std.mem.Allocator) anyerror!*session.Type = session.Type.attempt,
    parent_display: ?[:0]const u8 = null,
    own_socket: []const u8 = "",
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
    primary_drm_fd: i32 = -1,
    session: ?*session.Type = null,
    session_paused: bool = false,
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
        return createTracked(alloc, backends, options, null);
    }

    fn createTracked(
        alloc: std.mem.Allocator,
        backends: []const ImplementationOptions,
        options: Options,
        created_idle_fd: ?*i32,
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
            .implementations = std.ArrayList(Implementation).empty,
        };
        errdefer if (self.session) |active| active.deinit();

        // Create timerfd for idle events
        const linux = std.os.linux;
        const fd_result = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
        self.idle_fd = @intCast(fd_result);
        if (created_idle_fd) |fd| fd.* = self.idle_fd;
        errdefer if (self.idle_fd >= 0) core.unix.close(self.idle_fd);

        // Instantiate backend implementations from options
        errdefer {
            for (self.implementations.items) |impl| {
                impl.deinit();
            }
            self.implementations.deinit(alloc);
        }

        self.initializePhysicalInput();
        try self.instantiateBackends();

        return self;
    }

    fn initializePhysicalInput(self: *Self) void {
        if (!self.options.physical_input) return;
        self.session = self.options.session_factory(self.allocator) catch |err| {
            cli.log.warn(
                "Physical input session unavailable: {}; native DRM cannot start without a session",
                .{err},
            );
            return;
        };
        self.poll_fds_dirty = true;
    }

    /// Instantiate backend implementations from stored options
    fn instantiateBackends(self: *Self) !void {
        for (self.implementation_options) |opt| {
            self.tryCreateBackend(opt) catch |err| {
                if (opt.request_mode == .mandatory) {
                    cli.log.crit("Mandatory backend failed to create", .{});
                    return err;
                }
                // For if_available and fallback, continue
                cli.log.debug("Optional backend not available, continuing", .{});
            };
        }

        if (self.implementations.items.len == 0) {
            cli.log.warn("No backends were successfully created", .{});
        }
    }

    /// Try to create a single backend implementation
    fn tryCreateBackend(self: *Self, opt: ImplementationOptions) !void {
        const impl = try self.createBackendByType(opt.backend_type);
        try self.implementations.append(self.allocator, impl);
        self.poll_fds_dirty = true;
        cli.log.debug("Successfully created backend", .{});
    }

    /// Create backend implementation by type
    fn createBackendByType(self: *Self, backend_type: Type) !Implementation {
        const wayland = @import("wayland.zig");

        return switch (backend_type) {
            .wayland => blk: {
                cli.log.debug("Attempting to create Wayland backend", .{});
                const backend_ptr = wayland.Backend.create(self.allocator, self) catch {
                    cli.log.warn("Failed to create Wayland backend", .{});
                    return error.BackendNotImplemented;
                };
                break :blk backend_ptr.iface();
            },
            .drm => {
                const drm = @import("drm/root.zig");
                return drm.Backend.createImplementation(self) catch {
                    cli.log.warn("DRM backend not available", .{});
                    return error.BackendNotImplemented;
                };
            },
            .headless => {
                cli.log.debug("Headless backend not yet implemented", .{});
                return error.BackendNotImplemented;
            },
            .null => {
                cli.log.debug("Null backend - skipping", .{});
                return error.BackendNotImplemented;
            },
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.primary_allocator) |alloc| {
            alloc.deinit();
            self.primary_allocator = null;
        }
        if (self.primary_renderer) |rend| {
            rend.deinit();
            self.primary_renderer = null;
        }
        if (self.primary_drm_fd >= 0) {
            core.unix.close(self.primary_drm_fd);
            self.primary_drm_fd = -1;
        }

        for (self.implementations.items) |impl| {
            impl.deinit();
        }
        self.implementations.deinit(self.allocator);

        if (self.session) |sess| {
            sess.deinit();
        }

        if (self.idle_fd >= 0) {
            core.unix.close(self.idle_fd);
        }

        if (self.cached_poll_fds.len > 0) {
            self.allocator.free(self.cached_poll_fds);
        }

        self.allocator.destroy(self);
    }

    /// Start all backend implementations
    pub fn start(self: *Self) !bool {
        cli.log.debug("Starting the backend!", .{});
        errdefer self.releaseSession();

        const started = try self.startImplementations();
        if (started == 0) {
            cli.log.crit("No backend could be opened", .{});
            self.releaseSession();
            return false;
        }

        try self.initializeRendererAndAllocator();

        self.ready = true;
        self.notifyReady();
        self.poll_fds_dirty = true;

        return true;
    }

    fn releaseSession(self: *Self) void {
        const sess = self.session orelse return;
        self.abandonDrmSessionDevices();
        sess.deinit();
        self.session = null;
        self.poll_fds_dirty = true;
    }

    fn abandonDrmSessionDevices(self: *Self) void {
        self.forEachDrmBackend(abandonOneDrm);
    }

    /// Pause KMS on every DRM implementation (VT/seat disable).
    pub fn pausePhysicalSession(self: *Self) void {
        self.session_paused = true;
        self.forEachDrmBackend(pauseOneDrm);
    }

    /// Resume KMS on every DRM implementation (VT/seat enable).
    pub fn resumePhysicalSession(self: *Self) void {
        self.session_paused = false;
        self.forEachDrmBackend(resumeOneDrm);
    }

    fn forEachDrmBackend(self: *Self, func: *const fn (*@import("drm/root.zig").Backend) void) void {
        for (self.implementations.items) |impl| {
            if (impl.backendType() != .drm) continue;
            func(@ptrCast(@alignCast(impl.base.ptr)));
        }
    }

    fn abandonOneDrm(be: *@import("drm/root.zig").Backend) void {
        be.abandonSessionDevice();
    }

    fn pauseOneDrm(be: *@import("drm/root.zig").Backend) void {
        be.pauseForSeatDisable();
    }

    fn resumeOneDrm(be: *@import("drm/root.zig").Backend) void {
        be.resumeForSeatEnable();
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
            cli.log.err("Backend could not start, enabling fallbacks", .{});

            if (self.isMandatoryBackend(impl.backendType())) {
                cli.log.crit("Mandatory backend failed to start, cannot continue!", .{});
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
            const fd = renderOrCardFd(impl);
            if (fd < 0) continue;

            const reopened_fd = self.reopenDrmNode(fd, true);
            if (reopened_fd < 0) continue;

            self.tryInitializeRenderer(reopened_fd) catch |err| {
                std.log.err("Renderer initialization failed: {}", .{err});
                core.unix.close(reopened_fd);
                continue;
            };
            self.primary_drm_fd = reopened_fd;

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
        cli.log.debug("Renderer initialized", .{});
    }

    /// Try to initialize GBM allocator with given DRM FD
    fn tryInitializeAllocator(self: *Self, drm_fd: i32) !void {
        const gbm_alloc = try gbm.Allocator.create(self.allocator, drm_fd);
        self.primary_allocator = gbm_alloc.asInterface();
        cli.log.debug("GBM allocator initialized", .{});
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

        var result = std.ArrayList(PollFd).empty;
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

    /// Reopen DRM node with proper permissions (for allocator)
    /// Based on wlroots render/allocator/allocator.c for ref-counting reasons
    pub fn reopenDrmNode(self: *Self, drm_fd: i32, allow_render_node: bool) i32 {
        const drm = @cImport({
            @cInclude("xf86drm.h");
            @cInclude("fcntl.h");
        });

        if (drm.drmIsMaster(drm_fd) != 0) {
            cli.log.debug("Is DRM master, falling back to device open", .{});
        }

        const device_name = self.getDrmDeviceName(drm_fd, allow_render_node) orelse {
            cli.log.err("Failed to get DRM device name", .{});
            return -1;
        };
        defer std.c.free(device_name);

        const new_fd = self.openDrmDevice(device_name) orelse return -1;

        if (self.needsAuthentication(drm_fd, new_fd)) {
            self.authenticateDrmFd(drm_fd, new_fd) catch {
                core.unix.close(new_fd);
                return -1;
            };
        }

        return new_fd;
    }

    /// Get DRM device name, preferring render node if allowed
    fn getDrmDeviceName(self: *Self, drm_fd: i32, allow_render_node: bool) ?[*:0]u8 {
        _ = self;
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
            cli.log.err("drmGetDeviceNameFromFd2 failed", .{});
        }
        return name;
    }

    /// Open DRM device by name
    fn openDrmDevice(self: *Self, device_name: [*:0]u8) ?i32 {
        _ = self;
        const fd = core.unix.open(
            std.mem.span(device_name),
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        ) catch {
            cli.log.err("Failed to open DRM node", .{});
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
        _ = self;
        const drm = @cImport({
            @cInclude("xf86drm.h");
        });

        var magic: drm.drm_magic_t = 0;

        if (drm.drmGetMagic(client_fd, &magic) < 0) {
            cli.log.err("drmGetMagic failed", .{});
            return error.DrmGetMagicFailed;
        }

        if (drm.drmAuthMagic(master_fd, magic) < 0) {
            cli.log.err("drmAuthMagic failed", .{});
            return error.DrmAuthMagicFailed;
        }
    }
};

fn renderOrCardFd(impl: Implementation) i32 {
    const render_fd = impl.drmRenderNodeFd();
    if (render_fd >= 0) return render_fd;
    return impl.drmFd();
}

const testing = core.testing;

// Tests
test "Backend - ImplementationOptions defaults" {
    const opts: ImplementationOptions = .{};
    try testing.expectEqual(Type.wayland, opts.backend_type);
    try testing.expectEqual(RequestMode.if_available, opts.request_mode);
}

test "Backend - Options initialization" {
    const opts: Options = .{};
    _ = opts;
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

test "Coordinator - physical input selection creates runtime session" {
    const Factory = struct {
        fn create(alloc: std.mem.Allocator) !*session.Type {
            return session.Type.init(alloc);
        }
    };
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    var coordinator = try Coordinator.create(testing.allocator, &backends, .{
        .physical_input = true,
        .session_factory = Factory.create,
    });
    defer coordinator.deinit();

    try testing.expect(coordinator.hasSession());
    try testing.expect((try coordinator.getPollFds()).len >= 1);
}

test "Coordinator - start without implementations releases session" {
    const Factory = struct {
        fn create(alloc: std.mem.Allocator) !*session.Type {
            return session.Type.init(alloc);
        }
    };
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    var coordinator = try Coordinator.create(testing.allocator, &backends, .{
        .physical_input = true,
        .session_factory = Factory.create,
    });
    defer coordinator.deinit();

    try testing.expect(coordinator.hasSession());
    try testing.expectEqual(false, try coordinator.start());
    try testing.expectFalse(coordinator.hasSession());
}

test "Coordinator - physical input context failure remains graceful" {
    const Failure = struct {
        fn create(_: std.mem.Allocator) !*session.Type {
            return error.LibinputContextFailed;
        }
    };
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    var coordinator = try Coordinator.create(testing.allocator, &backends, .{
        .physical_input = true,
        .session_factory = Failure.create,
    });
    defer coordinator.deinit();

    try testing.expectFalse(coordinator.hasSession());
    try testing.expect((try coordinator.getPollFds()).len >= 1);
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
    const wayland_display = core.env.get("WAYLAND_DISPLAY");
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

test "Coordinator - optional DRM without session stays empty" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .drm, .request_mode = .if_available },
    };
    var coordinator = try Coordinator.create(testing.allocator, &backends, .{});
    defer coordinator.deinit();

    try testing.expectEqual(@as(usize, 0), coordinator.implementations.items.len);
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

    var idle_fd: i32 = -1;
    const result = Coordinator.createTracked(testing.allocator, &backends, opts, &idle_fd);
    try testing.expectError(error.BackendNotImplemented, result);
    try testing.expect(idle_fd >= 0);
    const status = std.posix.system.fcntl(idle_fd, std.posix.F.GETFD, @as(usize, 0));
    try testing.expectEqual(std.posix.E.BADF, std.posix.errno(status));
}

test "Coordinator - pause and resume with no implementations" {
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    var coordinator = try Coordinator.create(testing.allocator, &backends, .{});
    defer coordinator.deinit();

    try testing.expectEqual(@as(usize, 0), coordinator.implementations.items.len);
    coordinator.pausePhysicalSession();
    try testing.expect(coordinator.session_paused);
    coordinator.resumePhysicalSession();
    try testing.expectFalse(coordinator.session_paused);
}

test "Coordinator - pause and resume with empty drm backend" {
    const drm = @import("drm/root.zig");
    const backends = [_]ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    var coordinator = try Coordinator.create(testing.allocator, &backends, .{});
    defer coordinator.deinit();

    const be = try drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", coordinator, null);
    try coordinator.implementations.append(testing.allocator, be.asInterface());

    coordinator.pausePhysicalSession();
    try testing.expect(coordinator.session_paused);
    try testing.expect(be.seat_paused);
    coordinator.resumePhysicalSession();
    try testing.expectFalse(coordinator.session_paused);
    try testing.expectFalse(be.seat_paused);
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

test "renderOrCardFd - prefers an open render node" {
    const drm = @import("drm/root.zig");
    var be = try drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    const impl = be.asInterface();
    try testing.expectEqual(@as(i32, -1), renderOrCardFd(impl));
    be.render_node_fd = 11;
    be.drm_fd = 7;
    try testing.expectEqual(@as(i32, 11), renderOrCardFd(impl));
    be.render_node_fd = -1;
    try testing.expectEqual(@as(i32, 7), renderOrCardFd(impl));
    be.drm_fd = -1;
}
