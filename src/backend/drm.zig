//! DRM backend implementation with atomic modesetting
//! Avoids circular dependencies by using opaque pointers

const std = @import("std");
const math = @import("core.math");
const Vector2D = math.Vector2D;
const backend_mod = @import("backend.zig");
const session_mod = @import("session.zig");
const allocator_mod = @import("allocator.zig");
const misc = @import("misc.zig");

const drm = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

/// DRM backend implementation
pub const Backend = struct {
    allocator: std.mem.Allocator,
    drm_fd: i32 = -1,
    render_node_fd: i32 = -1,
    gpu_name: []const u8,
    atomic_modesetting: bool = false,
    backend_ptr: ?*anyopaque = null, // Opaque pointer to avoid circular dependency
    session_device: ?*session_mod.Device = null,

    const Self = @This();

    /// Attempt to create DRM backends for all available GPUs
    pub fn attempt(allocator: std.mem.Allocator, backend: ?*anyopaque) !std.ArrayList(*Self) {
        _ = backend; // Will be used when implementing device enumeration

        var backends = std.ArrayList(*Self){};
        errdefer {
            for (backends.items) |b| {
                b.deinit();
            }
            backends.deinit(allocator);
        }

        // TODO: Enumerate DRM devices via udev/session
        // For now, return empty list
        return backends;
    }

    /// Create DRM backend from a specific GPU path
    pub fn fromGpu(
        allocator: std.mem.Allocator,
        path: []const u8,
        backend: ?*anyopaque,
        primary: ?*Self,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .gpu_name = try allocator.dupe(u8, path),
            .backend_ptr = backend,
        };

        _ = primary; // For multi-GPU support later

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.drm_fd >= 0) {
            std.posix.close(self.drm_fd);
        }
        if (self.render_node_fd >= 0) {
            std.posix.close(self.render_node_fd);
        }
        self.allocator.free(self.gpu_name);
        self.allocator.destroy(self);
    }

    /// Get VTable to use as IBackendImplementation
    pub fn asInterface(self: *Self) backend_mod.IBackendImplementation {
        const vtable = comptime backend_mod.IBackendImplementation.VTable{
            .backend_type = backendTypeImpl,
            .start = startImpl,
            .poll_fds = pollFdsImpl,
            .drm_fd = drmFdImpl,
            .drm_render_node_fd = drmRenderNodeFdImpl,
            .get_render_formats = getRenderFormatsImpl,
            .on_ready = onReadyImpl,
            .deinit = deinitImpl,
        };

        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn backendTypeImpl(ptr: *anyopaque) backend_mod.Type {
        _ = ptr;
        return .drm;
    }

    fn startImpl(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        // TODO: Initialize DRM resources, scan for outputs
        return false;
    }

    fn pollFdsImpl(ptr: *anyopaque) []const backend_mod.PollFd {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        // TODO: Return DRM FD for polling
        return &[_]backend_mod.PollFd{};
    }

    fn drmFdImpl(ptr: *anyopaque) i32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.drm_fd;
    }

    fn drmRenderNodeFdImpl(ptr: *anyopaque) i32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.render_node_fd;
    }

    fn getRenderFormatsImpl(ptr: *anyopaque) []const misc.DRMFormat {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        // TODO: Query DRM plane formats
        return &[_]misc.DRMFormat{};
    }

    fn onReadyImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        // TODO: Initialize renderer, scan outputs
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Atomic commit request builder
pub const AtomicRequest = struct {
    allocator: std.mem.Allocator,
    backend: ?*anyopaque = null, // Opaque pointer to DRMBackend to avoid circular dependency
    request: ?*drm.drmModeAtomicReq = null,
    failed: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, backend: ?*anyopaque) Self {
        const req = drm.drmModeAtomicAlloc();
        return .{
            .allocator = allocator,
            .backend = backend,
            .request = req,
            .failed = (req == null),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.request) |req| {
            drm.drmModeAtomicFree(req);
        }
    }

    /// Add a property to the atomic request
    pub fn add(self: *Self, object_id: u32, property_id: u32, value: u64) void {
        if (self.failed) return;
        if (object_id == 0 or property_id == 0) return;

        if (self.request) |req| {
            const result = drm.drmModeAtomicAddProperty(req, object_id, property_id, value);
            if (result < 0) {
                self.failed = true;
            }
        }
    }

    /// Set plane properties
    pub fn setPlaneProps(
        self: *Self,
        plane_id: u32,
        fb_id: u32,
        crtc_id: u32,
        pos: Vector2D,
        size: Vector2D,
    ) void {
        if (self.failed) return;

        if (fb_id == 0 or crtc_id == 0) {
            // Disable the plane
            self.add(plane_id, 0, 0); // TODO: Use actual property IDs
            return;
        }

        // src_ coordinates are 16.16 fixed point
        const src_w: u64 = @intFromFloat(size.getX() * 65536.0);
        const src_h: u64 = @intFromFloat(size.getY() * 65536.0);

        // TODO: Set all plane properties using actual property IDs from DRM
        _ = src_w;
        _ = src_h;
        _ = pos;
    }

    /// Commit the atomic request
    pub fn commit(self: *Self, flags: u32, drm_fd: i32) bool {
        if (self.failed) return false;

        if (self.request) |req| {
            const result = drm.drmModeAtomicCommit(drm_fd, req, flags, null);
            return result == 0;
        }
        return false;
    }
};

/// Get maximum bits-per-channel for a DRM format
pub fn getMaxBpc(drm_format: u32) u8 {
    // DRM format constants from drm_fourcc.h
    const DRM_FORMAT_XRGB8888: u32 = 0x34325258;
    const DRM_FORMAT_XBGR8888: u32 = 0x34324258;
    const DRM_FORMAT_ARGB8888: u32 = 0x34325241;
    const DRM_FORMAT_ABGR8888: u32 = 0x34324241;
    const DRM_FORMAT_XRGB2101010: u32 = 0x30335258;
    const DRM_FORMAT_XBGR2101010: u32 = 0x30334258;
    const DRM_FORMAT_ARGB2101010: u32 = 0x30335241;
    const DRM_FORMAT_ABGR2101010: u32 = 0x30334241;
    const DRM_FORMAT_XRGB16161616: u32 = 0x38345258;
    const DRM_FORMAT_XBGR16161616: u32 = 0x38344258;
    const DRM_FORMAT_ARGB16161616: u32 = 0x38345241;
    const DRM_FORMAT_ABGR16161616: u32 = 0x38344241;

    return switch (drm_format) {
        DRM_FORMAT_XRGB8888,
        DRM_FORMAT_XBGR8888,
        DRM_FORMAT_ARGB8888,
        DRM_FORMAT_ABGR8888,
        => 8,

        DRM_FORMAT_XRGB2101010,
        DRM_FORMAT_XBGR2101010,
        DRM_FORMAT_ARGB2101010,
        DRM_FORMAT_ABGR2101010,
        => 10,

        DRM_FORMAT_XRGB16161616,
        DRM_FORMAT_XBGR16161616,
        DRM_FORMAT_ARGB16161616,
        DRM_FORMAT_ABGR16161616,
        => 16,

        else => 8,
    };
}

// Tests
test "DRMBackend - fromGpu creates backend" {
    const testing = std.testing;

    var backend = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer backend.deinit();

    try testing.expectEqualStrings("/dev/dri/card0", backend.gpu_name);
    try testing.expectEqual(@as(i32, -1), backend.drm_fd);
}

test "DRMBackend - asInterface returns correct type" {
    const testing = std.testing;

    var backend = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer backend.deinit();

    const interface = backend.asInterface();
    try testing.expectEqual(backend_mod.Type.drm, interface.backendType());
}

test "AtomicRequest - initialization" {
    const testing = std.testing;

    var request = AtomicRequest.init(testing.allocator, null);
    defer request.deinit();

    try testing.expect(!request.failed);
}

test "AtomicRequest - add does nothing when failed" {
    const testing = std.testing;

    var request = AtomicRequest.init(testing.allocator, null);
    defer request.deinit();

    request.failed = true;
    request.add(1, 2, 3); // Should not crash

    try testing.expect(request.failed);
}

test "getMaxBpc - 8-bit formats" {
    const testing = std.testing;

    const DRM_FORMAT_XRGB8888: u32 = 0x34325258;
    const DRM_FORMAT_ARGB8888: u32 = 0x34325241;

    try testing.expectEqual(@as(u8, 8), getMaxBpc(DRM_FORMAT_XRGB8888));
    try testing.expectEqual(@as(u8, 8), getMaxBpc(DRM_FORMAT_ARGB8888));
}

test "getMaxBpc - 10-bit formats" {
    const testing = std.testing;

    const DRM_FORMAT_XRGB2101010: u32 = 0x30335258;
    const DRM_FORMAT_ARGB2101010: u32 = 0x30335241;

    try testing.expectEqual(@as(u8, 10), getMaxBpc(DRM_FORMAT_XRGB2101010));
    try testing.expectEqual(@as(u8, 10), getMaxBpc(DRM_FORMAT_ARGB2101010));
}

test "getMaxBpc - 16-bit formats" {
    const testing = std.testing;

    const DRM_FORMAT_XRGB16161616: u32 = 0x38345258;
    const DRM_FORMAT_ARGB16161616: u32 = 0x38345241;

    try testing.expectEqual(@as(u8, 16), getMaxBpc(DRM_FORMAT_XRGB16161616));
    try testing.expectEqual(@as(u8, 16), getMaxBpc(DRM_FORMAT_ARGB16161616));
}

test "getMaxBpc - unknown format defaults to 8" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 8), getMaxBpc(0xDEADBEEF));
    try testing.expectEqual(@as(u8, 8), getMaxBpc(0));
}
