//! DRM be implementation with atomic modesetting
//! Avoids circular dependencies by using opaque pointers

const std = @import("std");
const core = @import("core");
const cli = @import("core.cli");
const cvt = @import("core.display").cvt;
const math = @import("core.math");
const Vector2D = math.Vec2;
const backend = @import("backend.zig");
const session = @import("session.zig");
const allocator = @import("allocator.zig");
const misc = @import("misc.zig");
const output = @import("output.zig");
const Buffer = @import("buffer.zig").Interface;

const c = @cImport({
    @cInclude("drm.h");
    @cInclude("drm_mode.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
    @cInclude("libudev.h");
});

// DRM capability constants (from drm.h)
const CAP_ATOMIC: u64 = 0x5;
const CAP_ADDFB2_MODIFIERS: u64 = 0x10;
const CLIENT_CAP_ATOMIC: u64 = 3;
const CLIENT_CAP_UNIVERSAL_PLANES: u64 = 2;

/// DRM property information
pub const Property = struct {
    id: u32 = 0,
    name: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, fd: i32, prop_id: u32) !Property {
        const prop = c.drmModeGetProperty(fd, prop_id) orelse return error.PropertyNotFound;
        defer c.drmModeFreeProperty(prop);

        return .{
            .id = prop_id,
            .name = try alloc.dupe(u8, std.mem.sliceTo(&prop.*.name, 0)),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Property) void {
        if (self.name.len > 0) {
            self.allocator.free(self.name);
        }
    }
};

/// DRM plane information
pub const Plane = struct {
    id: u32,
    type: PlaneType,
    initial_fb_id: u32,
    possible_crtcs: u32,
    formats: std.ArrayList(u32),
    props: PlaneProps = .{},
    allocator: std.mem.Allocator,

    pub const PlaneType = enum(u32) {
        primary = 1,
        cursor = 2,
        overlay = 0,
    };

    pub const PlaneProps = struct {
        fb_id: u32 = 0,
        crtc_id: u32 = 0,
        crtc_x: u32 = 0,
        crtc_y: u32 = 0,
        crtc_w: u32 = 0,
        crtc_h: u32 = 0,
        src_x: u32 = 0,
        src_y: u32 = 0,
        src_w: u32 = 0,
        src_h: u32 = 0,
        type_prop: u32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator, fd: i32, plane_id: u32) !*Plane {
        const self = try alloc.create(Plane);
        errdefer alloc.destroy(self);

        const plane_ptr = c.drmModeGetPlane(fd, plane_id) orelse return error.PlaneNotFound;
        defer c.drmModeFreePlane(plane_ptr);

        self.* = .{
            .id = plane_id,
            .type = .overlay,
            .initial_fb_id = plane_ptr.*.fb_id,
            .possible_crtcs = plane_ptr.*.possible_crtcs,
            .formats = std.ArrayList(u32){},
            .allocator = alloc,
        };

        // Read formats
        var i: u32 = 0;
        while (i < plane_ptr.*.count_formats) : (i += 1) {
            try self.formats.append(alloc, plane_ptr.*.formats[i]);
        }

        // Load plane properties
        self.loadProperties(fd);

        return self;
    }

    fn loadProperties(self: *Plane, fd: i32) void {
        const props = c.drmModeObjectGetProperties(fd, self.id, c.DRM_MODE_OBJECT_PLANE) orelse return;
        defer c.drmModeFreeObjectProperties(props);

        var j: u32 = 0;
        while (j < props.*.count_props) : (j += 1) {
            const prop = c.drmModeGetProperty(fd, props.*.props[j]) orelse continue;
            defer c.drmModeFreeProperty(prop);

            const prop_name = std.mem.sliceTo(&prop.*.name, 0);
            const prop_id = props.*.props[j];
            const prop_value = props.*.prop_values[j];

            self.parsePlaneProperty(prop_name, prop_id, prop_value);
        }
    }

    fn parsePlaneProperty(self: *Plane, name: []const u8, prop_id: u32, value: u64) void {
        if (std.mem.eql(u8, name, "type")) {
            if (value == c.DRM_PLANE_TYPE_PRIMARY) {
                self.type = .primary;
            } else if (value == c.DRM_PLANE_TYPE_CURSOR) {
                self.type = .cursor;
            }
            self.props.type_prop = prop_id;
        } else if (std.mem.eql(u8, name, "FB_ID")) {
            self.props.fb_id = prop_id;
        } else if (std.mem.eql(u8, name, "CRTC_ID")) {
            self.props.crtc_id = prop_id;
        } else if (std.mem.eql(u8, name, "CRTC_X")) {
            self.props.crtc_x = prop_id;
        } else if (std.mem.eql(u8, name, "CRTC_Y")) {
            self.props.crtc_y = prop_id;
        } else if (std.mem.eql(u8, name, "CRTC_W")) {
            self.props.crtc_w = prop_id;
        } else if (std.mem.eql(u8, name, "CRTC_H")) {
            self.props.crtc_h = prop_id;
        } else if (std.mem.eql(u8, name, "SRC_X")) {
            self.props.src_x = prop_id;
        } else if (std.mem.eql(u8, name, "SRC_Y")) {
            self.props.src_y = prop_id;
        } else if (std.mem.eql(u8, name, "SRC_W")) {
            self.props.src_w = prop_id;
        } else if (std.mem.eql(u8, name, "SRC_H")) {
            self.props.src_h = prop_id;
        }
    }

    pub fn deinit(self: *Plane) void {
        self.formats.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// DRM CRTC information
pub const CRTC = struct {
    id: u32,
    legacy_crtc_idx: u32,
    primary: ?*Plane = null,
    cursor: ?*Plane = null,
    props: CRTCProps = .{},
    allocator: std.mem.Allocator,

    pub const CRTCProps = struct {
        mode_id: u32 = 0,
        active: u32 = 0,
        gamma_lut: u32 = 0,
        gamma_lut_size: u32 = 0,
        degamma_lut: u32 = 0,
        degamma_lut_size: u32 = 0,
        ctm: u32 = 0,
        vrr_enabled: u32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator, fd: i32, crtc_id: u32, idx: u32) !*CRTC {
        const self = try alloc.create(CRTC);
        errdefer alloc.destroy(self);

        self.* = .{
            .id = crtc_id,
            .legacy_crtc_idx = idx,
            .allocator = alloc,
        };

        // Load CRTC properties
        const props = c.drmModeObjectGetProperties(fd, crtc_id, c.DRM_MODE_OBJECT_CRTC);
        if (props) |p| {
            defer c.drmModeFreeObjectProperties(p);

            var i: u32 = 0;
            while (i < p.*.count_props) : (i += 1) {
                const prop = c.drmModeGetProperty(fd, p.*.props[i]) orelse continue;
                defer c.drmModeFreeProperty(prop);

                const prop_name = std.mem.sliceTo(&prop.*.name, 0);
                if (std.mem.eql(u8, prop_name, "MODE_ID")) {
                    self.props.mode_id = p.*.props[i];
                } else if (std.mem.eql(u8, prop_name, "ACTIVE")) {
                    self.props.active = p.*.props[i];
                } else if (std.mem.eql(u8, prop_name, "GAMMA_LUT")) {
                    self.props.gamma_lut = p.*.props[i];
                } else if (std.mem.eql(u8, prop_name, "GAMMA_LUT_SIZE")) {
                    self.props.gamma_lut_size = @intCast(p.*.prop_values[i]);
                } else if (std.mem.eql(u8, prop_name, "DEGAMMA_LUT")) {
                    self.props.degamma_lut = p.*.props[i];
                } else if (std.mem.eql(u8, prop_name, "DEGAMMA_LUT_SIZE")) {
                    self.props.degamma_lut_size = @intCast(p.*.prop_values[i]);
                } else if (std.mem.eql(u8, prop_name, "CTM")) {
                    self.props.ctm = p.*.props[i];
                } else if (std.mem.eql(u8, prop_name, "VRR_ENABLED")) {
                    self.props.vrr_enabled = p.*.props[i];
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *CRTC) void {
        if (self.primary) |p| p.deinit();
        if (self.cursor) |p| p.deinit();
        self.allocator.destroy(self);
    }
};

/// DRM connector information
pub const Connector = struct {
    id: u32,
    name: []const u8,
    connector_type: u32,
    connector_type_id: u32,
    status: Status,
    modes: std.ArrayList(output.Mode),
    crtc: ?*CRTC = null,
    props: ConnectorProps = .{},
    allocator: std.mem.Allocator,
    be: *Backend,

    pub const Status = enum(u32) {
        connected = 1,
        disconnected = 2,
        unknown = 3,
    };

    pub const ConnectorProps = struct {
        crtc_id: u32 = 0,
        dpms: u32 = 0,
        edid: u32 = 0,
        link_status: u32 = 0,
        path: u32 = 0,
        vrr_capable: u32 = 0,
        subconnector: u32 = 0,
        non_desktop: u32 = 0,
        panel_orientation: u32 = 0,
        content_type: u32 = 0,
        max_bpc: u32 = 0,
        hdr_output_metadata: u32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator, be: *Backend, connector_id: u32) !*Connector {
        const self = try alloc.create(Connector);
        errdefer alloc.destroy(self);

        const conn = c.drmModeGetConnector(be.drm_fd, connector_id) orelse return error.ConnectorNotFound;
        defer c.drmModeFreeConnector(conn);

        // Build connector name
        const type_name = getConnectorTypeName(conn.*.connector_type);
        const name = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ type_name, conn.*.connector_type_id });

        self.* = .{
            .id = connector_id,
            .name = name,
            .connector_type = conn.*.connector_type,
            .connector_type_id = conn.*.connector_type_id,
            .status = switch (conn.*.connection) {
                c.DRM_MODE_CONNECTED => .connected,
                c.DRM_MODE_DISCONNECTED => .disconnected,
                else => .unknown,
            },
            .modes = std.ArrayList(output.Mode){},
            .allocator = alloc,
            .be = be,
        };

        // Read modes
        var i: usize = 0;
        while (i < conn.*.count_modes) : (i += 1) {
            const mode = &conn.*.modes[i];
            const refresh = @as(u32, mode.*.vrefresh) * 1000; // Convert to mHz
            try self.modes.append(alloc, .{
                .pixel_size = Vector2D.init(@floatFromInt(mode.*.hdisplay), @floatFromInt(mode.*.vdisplay)),
                .refresh_rate = refresh,
                .preferred = (mode.*.type & c.DRM_MODE_TYPE_PREFERRED) != 0,
                .drm_mode_info = null, // Could store pointer if needed
            });
        }

        // Load connector properties
        const props = c.drmModeObjectGetProperties(be.drm_fd, connector_id, c.DRM_MODE_OBJECT_CONNECTOR);
        if (props) |p| {
            defer c.drmModeFreeObjectProperties(p);

            var j: u32 = 0;
            while (j < p.*.count_props) : (j += 1) {
                const prop = c.drmModeGetProperty(be.drm_fd, p.*.props[j]) orelse continue;
                defer c.drmModeFreeProperty(prop);

                const prop_name = std.mem.sliceTo(&prop.*.name, 0);
                if (std.mem.eql(u8, prop_name, "CRTC_ID")) {
                    self.props.crtc_id = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "DPMS")) {
                    self.props.dpms = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "EDID")) {
                    self.props.edid = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "link-status")) {
                    self.props.link_status = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "PATH")) {
                    self.props.path = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "vrr_capable")) {
                    self.props.vrr_capable = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "subconnector")) {
                    self.props.subconnector = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "non-desktop")) {
                    self.props.non_desktop = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "panel orientation")) {
                    self.props.panel_orientation = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "content type")) {
                    self.props.content_type = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "max bpc")) {
                    self.props.max_bpc = p.*.props[j];
                } else if (std.mem.eql(u8, prop_name, "HDR_OUTPUT_METADATA")) {
                    self.props.hdr_output_metadata = p.*.props[j];
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *Connector) void {
        self.modes.deinit(self.allocator);
        if (self.crtc) |crtc| crtc.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Get connector type name as string
    fn getConnectorTypeName(connector_type: u32) []const u8 {
        return switch (connector_type) {
            c.DRM_MODE_CONNECTOR_Unknown => "Unknown",
            c.DRM_MODE_CONNECTOR_VGA => "VGA",
            c.DRM_MODE_CONNECTOR_DVII => "DVI-I",
            c.DRM_MODE_CONNECTOR_DVID => "DVI-D",
            c.DRM_MODE_CONNECTOR_DVIA => "DVI-A",
            c.DRM_MODE_CONNECTOR_Composite => "Composite",
            c.DRM_MODE_CONNECTOR_SVIDEO => "S-Video",
            c.DRM_MODE_CONNECTOR_LVDS => "LVDS",
            c.DRM_MODE_CONNECTOR_Component => "Component",
            c.DRM_MODE_CONNECTOR_9PinDIN => "9-pin DIN",
            c.DRM_MODE_CONNECTOR_DisplayPort => "DP",
            c.DRM_MODE_CONNECTOR_HDMIA => "HDMI-A",
            c.DRM_MODE_CONNECTOR_HDMIB => "HDMI-B",
            c.DRM_MODE_CONNECTOR_TV => "TV",
            c.DRM_MODE_CONNECTOR_eDP => "eDP",
            c.DRM_MODE_CONNECTOR_VIRTUAL => "Virtual",
            c.DRM_MODE_CONNECTOR_DSI => "DSI",
            c.DRM_MODE_CONNECTOR_DPI => "DPI",
            else => "Unknown",
        };
    }
};

/// DRM framebuffer wrapper
pub const Framebuffer = struct {
    id: u32 = 0,
    buffer: ?Buffer = null,
    be: *Backend,
    bo_handles: [4]u32 = .{ 0, 0, 0, 0 },
    dropped: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, be: *Backend, buffer: Buffer) !*Framebuffer {
        const self = try alloc.create(Framebuffer);
        errdefer alloc.destroy(self);

        self.* = .{
            .buffer = buffer,
            .be = be,
            .allocator = alloc,
        };

        // Import DMA-BUF handles to create framebuffer
        const dmabuf_attrs = buffer.dmabuf();
        if (!dmabuf_attrs.success) {
            return error.NoDMABufAttributes;
        }

        const width: u32 = @intFromFloat(dmabuf_attrs.size.getX());
        const height: u32 = @intFromFloat(dmabuf_attrs.size.getY());
        const num_planes: usize = @intCast(dmabuf_attrs.planes);

        // Collect DRM gem handles from file descriptors
        self.importDmaBufHandles(be.drm_fd, &dmabuf_attrs, num_planes) catch {
            self.cleanupBoHandles(be.drm_fd);
            return error.DMABufImportFailed;
        };
        errdefer self.cleanupBoHandles(be.drm_fd);

        // Prepare arrays for drmModeAddFB2
        var handles: [4]u32 = .{ 0, 0, 0, 0 };
        var pitches: [4]u32 = dmabuf_attrs.strides;
        var offsets: [4]u32 = dmabuf_attrs.offsets;
        var modifiers: [4]u64 = .{ dmabuf_attrs.modifier, dmabuf_attrs.modifier, dmabuf_attrs.modifier, dmabuf_attrs.modifier };

        var i: usize = 0;
        while (i < num_planes) : (i += 1) {
            handles[i] = self.bo_handles[i];
        }

        // Try to add framebuffer with modifiers if supported
        var fb_id: u32 = 0;
        if (be.drm_props.supports_add_fb2_modifiers and dmabuf_attrs.modifier != 0) {
            const result = c.drmModeAddFB2WithModifiers(
                be.drm_fd,
                width,
                height,
                dmabuf_attrs.format,
                &handles,
                &pitches,
                &offsets,
                &modifiers,
                &fb_id,
                c.DRM_MODE_FB_MODIFIERS,
            );
            if (result != 0) {
                // Fall back to simple AddFB2 without modifiers
                const simple_result = c.drmModeAddFB2(
                    be.drm_fd,
                    width,
                    height,
                    dmabuf_attrs.format,
                    &handles,
                    &pitches,
                    &offsets,
                    &fb_id,
                    0,
                );
                if (simple_result != 0) {
                    return error.AddFramebufferFailed;
                }
            }
        } else {
            // Use simple AddFB2 without modifiers
            const result = c.drmModeAddFB2(
                be.drm_fd,
                width,
                height,
                dmabuf_attrs.format,
                &handles,
                &pitches,
                &offsets,
                &fb_id,
                0,
            );
            if (result != 0) {
                return error.AddFramebufferFailed;
            }
        }

        self.id = fb_id;
        return self;
    }

    pub fn deinit(self: *Framebuffer) void {
        self.drop();
        self.allocator.destroy(self);
    }

    pub fn drop(self: *Framebuffer) void {
        if (self.dropped) return;
        self.dropped = true;

        if (self.id != 0) {
            _ = c.drmModeRmFB(self.be.drm_fd, self.id);
        }

        self.cleanupBoHandles(self.be.drm_fd);
    }

    fn importDmaBufHandles(self: *Framebuffer, drm_fd: i32, dmabuf_attrs: *const Buffer.DMABufAttributes, num_planes: usize) !void {
        var i: usize = 0;
        while (i < num_planes) : (i += 1) {
            if (dmabuf_attrs.fds[i] < 0) break;

            const fd = dmabuf_attrs.fds[i];
            var handle: u32 = 0;
            const prime_result = c.drmPrimeFDToHandle(drm_fd, fd, &handle);
            if (prime_result != 0) {
                return error.DMABufImportFailed;
            }
            self.bo_handles[i] = handle;
        }
    }

    fn cleanupBoHandles(self: *Framebuffer, drm_fd: i32) void {
        for (self.bo_handles) |handle| {
            if (handle != 0) {
                var gem_close: c.struct_drm_gem_close = undefined;
                gem_close.handle = handle;
                _ = c.drmIoctl(drm_fd, c.DRM_IOCTL_GEM_CLOSE, &gem_close);
            }
        }
    }
};

/// DRM be properties
pub const BackendProps = struct {
    supports_add_fb2_modifiers: bool = false,
    supports_timeline_sync_obj: bool = false,
    supports_sync_obj_eventfd: bool = false,
};

/// DRM be implementation
pub const Backend = struct {
    allocator: std.mem.Allocator,
    drm_fd: i32 = -1,
    render_node_fd: i32 = -1,
    gpu_name: []const u8,
    gpu_path: []const u8,
    atomic_modesetting: bool = false,
    backend_ptr: ?*anyopaque = null, // Opaque pointer to avoid circular dependency
    session_device: ?*session.Device = null,

    // DRM resources
    connectors: std.ArrayList(*Connector),
    crtcs: std.ArrayList(*CRTC),
    planes: std.ArrayList(*Plane),
    drm_props: BackendProps = .{},

    // Formats
    primary_formats: std.ArrayList(misc.DRMFormat),
    cursor_formats: std.ArrayList(misc.DRMFormat),

    // Poll FDs
    poll_fds: [1]backend.PollFd = undefined,

    const Self = @This();

    /// Attempt to create DRM backends for all available GPUs
    pub fn attempt(alloc: std.mem.Allocator, backend_ptr: ?*anyopaque) !std.ArrayList(*Self) {
        var backends = std.ArrayList(*Self){};
        errdefer {
            for (backends.items) |b| {
                b.deinit();
            }
            backends.deinit(alloc);
        }

        // Get be coordinator to access session
        const coordinator: *backend.Coordinator = @ptrCast(@alignCast(backend_ptr orelse return backends));
        const sess = coordinator.session orelse return backends;

        // Scan for GPUs via session devices
        const devices = try scanGPUs(alloc, sess);
        defer alloc.free(devices);

        // Create backends for each GPU
        for (devices) |device| {
            const be = Self.fromGpu(alloc, device.path, backend_ptr, null) catch |err| {
                cli.log.warn("Failed to create DRM be for GPU", .{});
                _ = err;
                continue;
            };
            try backends.append(alloc, be);
        }

        return backends;
    }

    /// Create DRM be from a specific GPU path
    pub fn fromGpu(
        alloc: std.mem.Allocator,
        path: []const u8,
        be: ?*anyopaque,
        primary: ?*Self,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        // Extract GPU name from path (e.g., "card0" from "/dev/dri/card0")
        const name = std.fs.path.basename(path);

        self.* = .{
            .allocator = alloc,
            .gpu_name = try alloc.dupe(u8, name),
            .gpu_path = try alloc.dupe(u8, path),
            .backend_ptr = be,
            .connectors = std.ArrayList(*Connector){},
            .crtcs = std.ArrayList(*CRTC){},
            .planes = std.ArrayList(*Plane){},
            .primary_formats = std.ArrayList(misc.DRMFormat){},
            .cursor_formats = std.ArrayList(misc.DRMFormat){},
        };

        _ = primary; // For multi-GPU support later

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up DRM resources
        for (self.connectors.items) |conn| {
            conn.deinit();
        }
        self.connectors.deinit(self.allocator);

        for (self.crtcs.items) |crtc| {
            crtc.deinit();
        }
        self.crtcs.deinit(self.allocator);

        for (self.planes.items) |plane| {
            plane.deinit();
        }
        self.planes.deinit(self.allocator);

        for (self.primary_formats.items) |*fmt| {
            fmt.deinit(self.allocator);
        }
        self.primary_formats.deinit(self.allocator);

        for (self.cursor_formats.items) |*fmt| {
            fmt.deinit(self.allocator);
        }
        self.cursor_formats.deinit(self.allocator);

        if (self.drm_fd >= 0) {
            std.posix.close(self.drm_fd);
        }
        if (self.render_node_fd >= 0) {
            std.posix.close(self.render_node_fd);
        }

        self.allocator.free(self.gpu_name);
        self.allocator.free(self.gpu_path);
        self.allocator.destroy(self);
    }

    /// Get VTable to use as IBackendImplementation
    pub fn asInterface(self: *Self) backend.Implementation {
        const vtable = comptime backend.Implementation.VTableDef{
            .backend_type = backendTypeImpl,
            .start = startImpl,
            .poll_fds = pollFdsImpl,
            .drm_fd = drmFdImpl,
            .drm_render_node_fd = drmRenderNodeFdImpl,
            .get_render_formats = getRenderFormatsImpl,
            .on_ready = onReadyImpl,
            .deinit = deinitImpl,
        };

        return backend.Implementation.init(self, &vtable);
    }

    fn backendTypeImpl(ptr: *anyopaque) backend.Type {
        _ = ptr;
        return .drm;
    }

    fn startImpl(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Open DRM device
        self.drm_fd = std.posix.open(
            self.gpu_path,
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        ) catch return false;

        // Check for atomic modesetting support
        var has_atomic: u64 = 0;
        if (c.drmGetCap(self.drm_fd, CAP_ATOMIC, &has_atomic) == 0 and has_atomic != 0) {
            if (c.drmSetClientCap(self.drm_fd, CLIENT_CAP_ATOMIC, 1) == 0) {
                self.atomic_modesetting = true;
            }
        }

        // Enable universal planes
        _ = c.drmSetClientCap(self.drm_fd, CLIENT_CAP_UNIVERSAL_PLANES, 1);

        // Check capabilities
        var has_modifiers: u64 = 0;
        if (c.drmGetCap(self.drm_fd, CAP_ADDFB2_MODIFIERS, &has_modifiers) == 0 and has_modifiers != 0) {
            self.drm_props.supports_add_fb2_modifiers = true;
        }

        // Initialize poll FD for DRM events
        self.poll_fds[0] = .{
            .fd = self.drm_fd,
            .callback = null, // Event handler will be called by coordinator
        };

        // Scan resources
        self.scanResources() catch return false;

        return true;
    }

    fn pollFdsImpl(ptr: *anyopaque) []const backend.PollFd {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.drm_fd >= 0) {
            return &self.poll_fds;
        }
        return &[_]backend.PollFd{};
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
        return self.primary_formats.items;
    }

    fn onReadyImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Scan and initialize connected outputs
        self.scanOutputs() catch |err| {
            if (self.backend_ptr) |_| {
                cli.log.err("Failed to scan DRM outputs", .{});
                _ = err;
            }
        };
    }
    
    /// Scan connected outputs and parse EDID information
    fn scanOutputs(self: *Self) !void {
        const edid_parser = @import("core.display").edid;
        
        for (self.connectors.items) |conn| {
            // Only process connected displays
            if (conn.status != .connected) continue;
            
            // Log basic connector info
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Found connected output: {s}", .{conn.name}) catch "Output found";
            cli.log.debug("{s}", .{msg});
            
            // Try to get EDID data
            if (conn.props.edid != 0) {
                const edid_data = self.getConnectorEDID(conn) catch {
                    cli.log.warn("Failed to read EDID data", .{});
                    continue;
                };
                defer self.allocator.free(edid_data);
                
                // Parse EDID
                const parsed = edid_parser.fast.parse(edid_data) catch {
                    cli.log.warn("Failed to parse EDID data", .{});
                    continue;
                };
                
                // Log display information
                const manufacturer = parsed.getManufacturerName() orelse "Unknown";
                const serial = parsed.getSerialNumber();
                
                const info_msg = std.fmt.bufPrint(&msg_buf, 
                    "Display: {s} (Serial: {d})", 
                    .{manufacturer, serial}
                ) catch "Display info";
                cli.log.debug("{s}", .{info_msg});
                
                // Log physical size if available
                const width_cm = parsed.getScreenWidthCm();
                const height_cm = parsed.getScreenHeightCm();
                if (width_cm > 0 and height_cm > 0) {
                    const size_msg = std.fmt.bufPrint(&msg_buf,
                        "Physical size: {d}x{d} cm",
                        .{width_cm, height_cm}
                    ) catch "Physical size";
                    cli.log.debug("{s}", .{size_msg});
                }
            }
            
            // Log available modes
            if (conn.modes.items.len > 0) {
                const mode_msg = std.fmt.bufPrint(&msg_buf,
                    "Available modes: {d}",
                    .{conn.modes.items.len}
                ) catch "Modes available";
                cli.log.debug("{s}", .{mode_msg});
                
                // Log preferred mode if any
                for (conn.modes.items) |mode| {
                    if (mode.preferred) {
                        const pref_msg = std.fmt.bufPrint(&msg_buf,
                            "Preferred mode: {d}x{d} @ {d}Hz",
                            .{
                                @as(u32, @intFromFloat(mode.pixel_size.getX())),
                                @as(u32, @intFromFloat(mode.pixel_size.getY())),
                                mode.refresh_rate / 1000,
                            }
                        ) catch "Preferred mode";
                        cli.log.debug("{s}", .{pref_msg});
                        break;
                    }
                }
            }
        }
    }
    
    /// Read EDID blob from connector property
    fn getConnectorEDID(self: *Self, conn: *Connector) ![]u8 {
        if (conn.props.edid == 0) return error.NoEDIDProperty;
        
        // Get the property blob
        const props = c.drmModeObjectGetProperties(self.drm_fd, conn.id, c.DRM_MODE_OBJECT_CONNECTOR);
        if (props == null) return error.GetPropertiesFailed;
        defer c.drmModeFreeObjectProperties(props.?);
        
        // Find the EDID property value (blob ID)
        var blob_id: u64 = 0;
        var i: u32 = 0;
        while (i < props.?.*.count_props) : (i += 1) {
            if (props.?.*.props[i] == conn.props.edid) {
                blob_id = props.?.*.prop_values[i];
                break;
            }
        }
        
        if (blob_id == 0) return error.NoEDIDBlob;
        
        // Get the blob data
        const blob = c.drmModeGetPropertyBlob(self.drm_fd, @intCast(blob_id));
        if (blob == null) return error.GetBlobFailed;
        defer c.drmModeFreePropertyBlob(blob.?);
        
        const edid_len = blob.?.*.length;
        if (edid_len == 0 or edid_len > 8192) return error.InvalidEDIDSize;
        
        // Copy EDID data
        const edid_data = try self.allocator.alloc(u8, edid_len);
        errdefer self.allocator.free(edid_data);
        
        const src_ptr: [*]const u8 = @ptrCast(blob.?.*.data);
        @memcpy(edid_data, src_ptr[0..edid_len]);
        
        return edid_data;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// Scan DRM resources (connectors, CRTCs, planes)
    fn scanResources(self: *Self) !void {
        const resources = c.drmModeGetResources(self.drm_fd) orelse return error.GetResourcesFailed;
        defer c.drmModeFreeResources(resources);

        // Scan CRTCs
        var i: usize = 0;
        while (i < resources.*.count_crtcs) : (i += 1) {
            const crtc = try CRTC.init(self.allocator, self.drm_fd, resources.*.crtcs[i], @intCast(i));
            try self.crtcs.append(self.allocator, crtc);
        }

        // Scan planes
        const plane_res = c.drmModeGetPlaneResources(self.drm_fd) orelse return error.GetPlaneResourcesFailed;
        defer c.drmModeFreePlaneResources(plane_res);

        i = 0;
        while (i < plane_res.*.count_planes) : (i += 1) {
            const plane = try Plane.init(self.allocator, self.drm_fd, plane_res.*.planes[i]);
            try self.planes.append(self.allocator, plane);

            // Assign planes to CRTCs
            for (self.crtcs.items, 0..) |crtc, crtc_idx| {
                const crtc_mask = @as(u32, 1) << @intCast(crtc_idx);
                if ((plane.possible_crtcs & crtc_mask) != 0) {
                    if (plane.type == .primary and crtc.primary == null) {
                        crtc.primary = plane;
                    } else if (plane.type == .cursor and crtc.cursor == null) {
                        crtc.cursor = plane;
                    }
                }
            }
        }

        // Scan connectors
        i = 0;
        while (i < resources.*.count_connectors) : (i += 1) {
            const connector = try Connector.init(self.allocator, self, resources.*.connectors[i]);
            try self.connectors.append(self.allocator, connector);
        }

        // Build format lists from primary planes with modifiers
        for (self.planes.items) |plane| {
            if (plane.type == .primary) {
                try self.queryPlaneFormats(plane, &self.primary_formats);
                break;
            }
        }

        // Build format lists from cursor planes with modifiers
        for (self.planes.items) |plane| {
            if (plane.type == .cursor) {
                try self.queryPlaneFormats(plane, &self.cursor_formats);
                break;
            }
        }
    }
    
    /// Query plane formats and modifiers
    fn queryPlaneFormats(self: *Self, plane: *Plane, format_list: *std.ArrayList(misc.DRMFormat)) !void {
        // Try to get format modifiers if supported
        const plane_res = c.drmModeGetPlane(self.drm_fd, plane.id);
        if (plane_res == null) return;
        defer c.drmModeFreePlane(plane_res.?);
        
        var i: u32 = 0;
        while (i < plane_res.?.*.count_formats) : (i += 1) {
            const format = plane_res.?.*.formats[i];
            
            var drm_fmt = misc.DRMFormat.init(self.allocator);
            drm_fmt.drm_format = format;
            
            // Try to get modifiers for this format if kernel supports it
            if (self.drm_props.supports_add_fb2_modifiers) {
                const modifiers = self.getPlaneFormatModifiers(plane.id, format) catch null;
                if (modifiers) |mod_list| {
                    defer self.allocator.free(mod_list);
                    for (mod_list) |modifier| {
                        try drm_fmt.addModifier(self.allocator, modifier);
                    }
                }
            }
            
            // If no modifiers found, add linear modifier as fallback
            if (drm_fmt.modifiers.items.len == 0) {
                try drm_fmt.addModifier(self.allocator, 0); // DRM_FORMAT_MOD_LINEAR
            }
            
            try format_list.append(self.allocator, drm_fmt);
        }
    }
    
    /// Get format modifiers for a specific plane and format
    fn getPlaneFormatModifiers(self: *Self, plane_id: u32, format: u32) ![]u64 {
        // Get plane properties to find IN_FORMATS blob
        const props = c.drmModeObjectGetProperties(self.drm_fd, plane_id, c.DRM_MODE_OBJECT_PLANE);
        if (props == null) return error.GetPropertiesFailed;
        defer c.drmModeFreeObjectProperties(props.?);
        
        var in_formats_blob_id: u64 = 0;
        var i: u32 = 0;
        while (i < props.?.*.count_props) : (i += 1) {
            const prop = c.drmModeGetProperty(self.drm_fd, props.?.*.props[i]) orelse continue;
            defer c.drmModeFreeProperty(prop);
            
            const prop_name = std.mem.sliceTo(&prop.*.name, 0);
            if (std.mem.eql(u8, prop_name, "IN_FORMATS")) {
                in_formats_blob_id = props.?.*.prop_values[i];
                break;
            }
        }
        
        if (in_formats_blob_id == 0) return error.NoInFormatsBlob;
        
        // Get the blob data
        const blob = c.drmModeGetPropertyBlob(self.drm_fd, @intCast(in_formats_blob_id));
        if (blob == null) return error.GetBlobFailed;
        defer c.drmModeFreePropertyBlob(blob.?);
        
        // Parse IN_FORMATS blob to extract modifiers for this format
        // This is a simplified version - proper parsing would need the drm_format_modifier_blob structure
        // For now, return empty array and let caller use linear modifier
        _ = format;
        return error.NotImplemented;
    }
};

/// Scan for available GPUs via udev
fn scanGPUs(alloc: std.mem.Allocator, sess: *session.Type) ![]const *session.Device {
    const udev_handle = sess.udev_handle orelse return error.UdevNotInitialized;

    const enumerate = c.udev_enumerate_new(udev_handle) orelse return error.UdevEnumerateFailed;
    defer _ = c.udev_enumerate_unref(enumerate);

    _ = c.udev_enumerate_add_match_subsystem(enumerate, "drm");
    _ = c.udev_enumerate_add_match_sysname(enumerate, "card[0-9]*");

    if (c.udev_enumerate_scan_devices(enumerate) != 0) {
        return error.UdevScanFailed;
    }

    var devices = std.ArrayList(*session.Device){};
    errdefer {
        for (devices.items) |dev| {
            dev.deinit();
        }
        devices.deinit(alloc);
    }

    var entry = c.udev_enumerate_get_list_entry(enumerate);
    while (entry != null) : (entry = c.udev_list_entry_get_next(entry)) {
        const path = c.udev_list_entry_get_name(entry) orelse continue;
        const device = c.udev_device_new_from_syspath(udev_handle, path) orelse continue;
        defer _ = c.udev_device_unref(device);

        // Check seat
        const seat = c.udev_device_get_property_value(device, "ID_SEAT");
        const seat_name = if (seat != null) std.mem.span(seat) else "seat0";

        if (sess.seat_name.len > 0 and !std.mem.eql(u8, sess.seat_name, seat_name)) {
            continue;
        }

        const devnode = c.udev_device_get_devnode(device) orelse continue;
        const devnode_str = std.mem.span(devnode);

        // Try to open as KMS device
        const session_device = session.Device.openIfKms(alloc, sess, devnode_str) catch continue;
        if (session_device) |dev| {
            try devices.append(alloc, dev);
        }
    }

    return devices.toOwnedSlice(alloc);
}

/// Calculate custom mode using CVT (Coordinated Video Timings)
pub fn calculateMode(alloc: std.mem.Allocator, width: u32, height: u32, refresh: f64) !c.drmModeModeInfo {
    _ = alloc;

    const timing = cvt.compute(.{
        .reduced_blanking = .none,
        .h_pixels = width,
        .v_lines = height,
        .refresh_rate_hz = if (refresh > 0) refresh else 60.0,
    });

    const hsync_start: u16 = @intCast(timing.h_active + timing.h_front_porch);
    const vsync_start: u16 = @intCast(timing.v_active + timing.v_front_porch);
    const hsync_end: u16 = @intCast(@as(u32, hsync_start) + timing.h_sync);
    const vsync_end: u16 = @intCast(@as(u32, vsync_start) + timing.v_sync);

    var mode_info: c.drmModeModeInfo = undefined;
    @memset(std.mem.asBytes(&mode_info), 0);

    mode_info.clock = @intFromFloat(@round(timing.pixel_clock_mhz * 1000.0));
    mode_info.hdisplay = @intCast(timing.h_active);
    mode_info.hsync_start = hsync_start;
    mode_info.hsync_end = hsync_end;
    mode_info.htotal = @intCast(timing.h_total);
    mode_info.vdisplay = @intCast(timing.v_active);
    mode_info.vsync_start = vsync_start;
    mode_info.vsync_end = vsync_end;
    mode_info.vtotal = @intCast(timing.v_total);
    mode_info.vrefresh = @intFromFloat(@round(timing.refresh_rate_hz));
    mode_info.flags = c.DRM_MODE_FLAG_NHSYNC | c.DRM_MODE_FLAG_PVSYNC;

    // Set mode name
    const name = std.fmt.bufPrint(&mode_info.name, "{d}x{d}", .{ width, height }) catch unreachable;
    @memset(mode_info.name[name.len..], 0);

    return mode_info;
}

/// Atomic commit request builder
pub const AtomicRequest = struct {
    allocator: std.mem.Allocator,
    be: ?*anyopaque = null, // Opaque pointer to DRMBackend to avoid circular dependency
    request: ?*c.drmModeAtomicReq = null,
    failed: bool = false,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, be: ?*anyopaque) Self {
        const req = c.drmModeAtomicAlloc();
        return .{
            .allocator = alloc,
            .be = be,
            .request = req,
            .failed = (req == null),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.request) |req| {
            c.drmModeAtomicFree(req);
        }
    }

    /// Add a property to the atomic request
    pub fn add(self: *Self, object_id: u32, property_id: u32, value: u64) void {
        if (self.failed) return;
        if (object_id == 0 or property_id == 0) return;

        if (self.request) |req| {
            const result = c.drmModeAtomicAddProperty(req, object_id, property_id, value);
            if (result < 0) {
                self.failed = true;
            }
        }
    }

    /// Set plane properties
    pub fn setPlaneProps(
        self: *Self,
        plane: *const Plane,
        fb_id: u32,
        crtc_id: u32,
        pos: Vector2D,
        size: Vector2D,
    ) void {
        if (self.failed) return;

        if (fb_id == 0 or crtc_id == 0) {
            // Disable the plane
            self.add(plane.id, plane.props.fb_id, 0);
            self.add(plane.id, plane.props.crtc_id, 0);
            return;
        }

        // Set framebuffer
        self.add(plane.id, plane.props.fb_id, fb_id);
        
        // Set CRTC
        self.add(plane.id, plane.props.crtc_id, crtc_id);
        
        // Set position (CRTC_X, CRTC_Y)
        const crtc_x: u64 = @intFromFloat(pos.getX());
        const crtc_y: u64 = @intFromFloat(pos.getY());
        self.add(plane.id, plane.props.crtc_x, crtc_x);
        self.add(plane.id, plane.props.crtc_y, crtc_y);
        
        // Set destination size (CRTC_W, CRTC_H)
        const crtc_w: u64 = @intFromFloat(size.getX());
        const crtc_h: u64 = @intFromFloat(size.getY());
        self.add(plane.id, plane.props.crtc_w, crtc_w);
        self.add(plane.id, plane.props.crtc_h, crtc_h);
        
        // Set source rectangle (16.16 fixed point)
        // Source starts at (0, 0) and spans the full buffer
        const src_w: u64 = @intFromFloat(size.getX() * 65536.0);
        const src_h: u64 = @intFromFloat(size.getY() * 65536.0);
        self.add(plane.id, plane.props.src_x, 0);
        self.add(plane.id, plane.props.src_y, 0);
        self.add(plane.id, plane.props.src_w, src_w);
        self.add(plane.id, plane.props.src_h, src_h);
    }

    /// Commit the atomic request
    pub fn commit(self: *Self, flags: u32, drm_fd: i32) bool {
        if (self.failed) return false;

        if (self.request) |req| {
            const result = c.drmModeAtomicCommit(drm_fd, req, flags, null);
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
test "DRMBackend - fromGpu creates be" {
    const testing = core.testing;

    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    try testing.expectEqualStrings("card0", be.gpu_name);
    try testing.expectEqualStrings("/dev/dri/card0", be.gpu_path);
    try testing.expectEqual(@as(i32, -1), be.drm_fd);
}

test "DRMBackend - asInterface returns correct type" {
    const testing = core.testing;

    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    const interface = be.asInterface();
    try testing.expectEqual(backend.Type.drm, interface.backendType());
}

test "AtomicRequest - initialization" {
    const testing = core.testing;

    var request = AtomicRequest.init(testing.allocator, null);
    defer request.deinit();

    try testing.expectFalse(request.failed);
}

test "AtomicRequest - add does nothing when failed" {
    const testing = core.testing;

    var request = AtomicRequest.init(testing.allocator, null);
    defer request.deinit();

    request.failed = true;
    request.add(1, 2, 3); // Should not crash

    try testing.expect(request.failed);
}

test "getMaxBpc - 8-bit formats" {
    const testing = core.testing;

    const DRM_FORMAT_XRGB8888: u32 = 0x34325258;
    const DRM_FORMAT_ARGB8888: u32 = 0x34325241;

    try testing.expectEqual(@as(u8, 8), getMaxBpc(DRM_FORMAT_XRGB8888));
    try testing.expectEqual(@as(u8, 8), getMaxBpc(DRM_FORMAT_ARGB8888));
}

test "getMaxBpc - 10-bit formats" {
    const testing = core.testing;

    const DRM_FORMAT_XRGB2101010: u32 = 0x30335258;
    const DRM_FORMAT_ARGB2101010: u32 = 0x30335241;

    try testing.expectEqual(@as(u8, 10), getMaxBpc(DRM_FORMAT_XRGB2101010));
    try testing.expectEqual(@as(u8, 10), getMaxBpc(DRM_FORMAT_ARGB2101010));
}

test "getMaxBpc - 16-bit formats" {
    const testing = core.testing;

    const DRM_FORMAT_XRGB16161616: u32 = 0x38345258;
    const DRM_FORMAT_ARGB16161616: u32 = 0x38345241;

    try testing.expectEqual(@as(u8, 16), getMaxBpc(DRM_FORMAT_XRGB16161616));
    try testing.expectEqual(@as(u8, 16), getMaxBpc(DRM_FORMAT_ARGB16161616));
}

test "getMaxBpc - unknown format defaults to 8" {
    const testing = core.testing;

    try testing.expectEqual(@as(u8, 8), getMaxBpc(0xDEADBEEF));
    try testing.expectEqual(@as(u8, 8), getMaxBpc(0));
}

test "Plane.PlaneProps - initialization" {
    const testing = core.testing;

    const props: Plane.PlaneProps = .{};
    try testing.expectEqual(@as(u32, 0), props.fb_id);
    try testing.expectEqual(@as(u32, 0), props.crtc_id);
    try testing.expectEqual(@as(u32, 0), props.crtc_x);
    try testing.expectEqual(@as(u32, 0), props.src_w);
}

test "Backend - poll_fds array size" {
    const testing = core.testing;

    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    // Poll FDs should be 1 element array
    try testing.expectEqual(@as(usize, 1), be.poll_fds.len);
}

test "Backend - getRenderFormats returns primary formats" {
    const testing = core.testing;

    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    // Add test format
    var fmt = misc.DRMFormat.init(testing.allocator);
    fmt.drm_format = 0x34325258; // DRM_FORMAT_XRGB8888
    try be.primary_formats.append(testing.allocator, fmt);

    const interface = be.asInterface();
    const formats = interface.getRenderFormats();

    try testing.expectEqual(@as(usize, 1), formats.len);
    try testing.expectEqual(@as(u32, 0x34325258), formats[0].drm_format);
}

test "AtomicRequest - setPlaneProps with disabled plane" {
    const testing = core.testing;

    var request = AtomicRequest.init(testing.allocator, null);
    defer request.deinit();

    // Create a test plane with some properties
    var plane = Plane{
        .id = 1,
        .type = .primary,
        .initial_fb_id = 0,
        .possible_crtcs = 1,
        .formats = std.ArrayList(u32){},
        .props = .{
            .fb_id = 10,
            .crtc_id = 11,
        },
        .allocator = testing.allocator,
    };
    defer plane.formats.deinit(testing.allocator);

    const pos = Vector2D.init(0, 0);
    const size = Vector2D.init(1920, 1080);

    // Disable plane (fb_id = 0)
    request.setPlaneProps(&plane, 0, 0, pos, size);

    // Should not fail
    try testing.expectFalse(request.failed);
}

test "AtomicRequest - setPlaneProps with valid configuration" {
    const testing = core.testing;

    var request = AtomicRequest.init(testing.allocator, null);
    defer request.deinit();

    var plane = Plane{
        .id = 1,
        .type = .primary,
        .initial_fb_id = 0,
        .possible_crtcs = 1,
        .formats = std.ArrayList(u32){},
        .props = .{
            .fb_id = 10,
            .crtc_id = 11,
            .crtc_x = 12,
            .crtc_y = 13,
            .crtc_w = 14,
            .crtc_h = 15,
            .src_x = 16,
            .src_y = 17,
            .src_w = 18,
            .src_h = 19,
        },
        .allocator = testing.allocator,
    };
    defer plane.formats.deinit(testing.allocator);

    const pos = Vector2D.init(100, 200);
    const size = Vector2D.init(1920, 1080);

    // Set plane properties
    request.setPlaneProps(&plane, 42, 5, pos, size);

    // Should not fail
    try testing.expectFalse(request.failed);
}

test "Framebuffer - initialization sets defaults" {
    const testing = core.testing;

    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    // Can't test full init without valid DMA-BUF, but can test structure
    const fb = Framebuffer{
        .id = 123,
        .buffer = null,
        .be = be,
        .bo_handles = .{ 1, 2, 3, 4 },
        .dropped = false,
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 123), fb.id);
    try testing.expectFalse(fb.dropped);
    try testing.expectEqual(@as(u32, 1), fb.bo_handles[0]);
}
