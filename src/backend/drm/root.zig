//! DRM be implementation with atomic modesetting
//! Avoids circular dependencies by using opaque pointers

const std = @import("std");
const string = @import("core.string").string;
const core = @import("core");
const cli = @import("core.cli");
const cvt = @import("core.display").cvt;
const math = @import("core.math");
const Vector2D = math.Vec2;
const backend = @import("../backend.zig");
const session = @import("../session.zig");
const allocator = @import("../allocator.zig");
const misc = @import("../misc.zig");
const output = @import("../output.zig");
const Buffer = @import("../buffer.zig").Interface;
const drm_format = @import("format.zig");
const drm_fb = @import("fb.zig");
pub const Output = @import("output.zig").Output;
pub const shouldStartNative = @import("output.zig").shouldStartNative;
pub const hasLiveParentCompositor = @import("output.zig").hasLiveParentCompositor;
const vulkan = @import("../vulkan.zig");
pub const getMaxBpc = drm_format.getMaxBpc;

const c = @cImport({
    @cInclude("drm.h");
    @cInclude("drm_mode.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

// DRM capability constants (from drm.h)
const CAP_ATOMIC: u64 = 0x5;
const CAP_ADDFB2_MODIFIERS: u64 = 0x10;
const CLIENT_CAP_ATOMIC: u64 = 3;
const CLIENT_CAP_UNIVERSAL_PLANES: u64 = 2;

/// DRM property information
pub const Property = struct {
    id: u32 = 0,
    name: string = "",
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, fd: i32, prop_id: u32) !Property {
        const prop = c.drmModeGetProperty(fd, prop_id) orelse return error.PropertyNotFound;
        defer c.drmModeFreeProperty(prop);

        return .{
            .id = prop_id,
            .name = try alloc.dupe(u8, std.mem.sliceTo(prop.*.name[0..], 0)),
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
    type: Type,
    initial_fb_id: u32,
    possible_crtcs: u32,
    formats: std.ArrayList(u32),
    props: Props = .{},
    allocator: std.mem.Allocator,

    pub const Type = enum(u32) {
        primary = 1,
        cursor = 2,
        overlay = 0,
    };

    pub const Props = struct {
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
        in_formats_blob: u64 = 0,
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
            .formats = std.ArrayList(u32).empty,
            .allocator = alloc,
        };
        errdefer self.formats.deinit(alloc);

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

            const prop_name = std.mem.sliceTo(prop.*.name[0..], 0);
            const prop_id = props.*.props[j];
            const prop_value = props.*.prop_values[j];

            self.parseProperty(prop_name, prop_id, prop_value);
        }
    }

    fn parseProperty(self: *Plane, name: string, prop_id: u32, value: u64) void {
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
        } else if (std.mem.eql(u8, name, "IN_FORMATS")) {
            self.props.in_formats_blob = value;
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
    props: Props = .{},
    allocator: std.mem.Allocator,

    pub const Props = struct {
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
        self.loadProperties(fd);
        return self;
    }

    fn loadProperties(self: *CRTC, fd: i32) void {
        const props = c.drmModeObjectGetProperties(fd, self.id, c.DRM_MODE_OBJECT_CRTC) orelse return;
        defer c.drmModeFreeObjectProperties(props);
        var i: u32 = 0;
        while (i < props.*.count_props) : (i += 1) {
            self.parseProperty(fd, props.*.props[i], props.*.prop_values[i]);
        }
    }

    fn parseProperty(self: *CRTC, fd: i32, prop_id: u32, value: u64) void {
        const prop = c.drmModeGetProperty(fd, prop_id) orelse return;
        defer c.drmModeFreeProperty(prop);
        const name = std.mem.sliceTo(prop.*.name[0..], 0);
        self.assignProperty(name, prop_id, value);
    }

    fn assignProperty(self: *CRTC, name: string, prop_id: u32, value: u64) void {
        if (std.mem.eql(u8, name, "MODE_ID")) {
            self.props.mode_id = prop_id;
        } else if (std.mem.eql(u8, name, "ACTIVE")) {
            self.props.active = prop_id;
        } else if (std.mem.eql(u8, name, "GAMMA_LUT")) {
            self.props.gamma_lut = prop_id;
        } else if (std.mem.eql(u8, name, "GAMMA_LUT_SIZE")) {
            self.props.gamma_lut_size = @intCast(value);
        } else if (std.mem.eql(u8, name, "DEGAMMA_LUT")) {
            self.props.degamma_lut = prop_id;
        } else if (std.mem.eql(u8, name, "DEGAMMA_LUT_SIZE")) {
            self.props.degamma_lut_size = @intCast(value);
        } else if (std.mem.eql(u8, name, "CTM")) {
            self.props.ctm = prop_id;
        } else if (std.mem.eql(u8, name, "VRR_ENABLED")) {
            self.props.vrr_enabled = prop_id;
        }
    }

    pub fn deinit(self: *CRTC) void {
        self.allocator.destroy(self);
    }
};

/// DRM connector information
pub const Connector = struct {
    id: u32,
    name: string,
    type: u32,
    type_id: u32,
    status: Status,
    modes: std.ArrayList(output.Mode),
    crtc: ?*CRTC = null,
    non_desktop: bool = false,
    max_bpc_min: u64 = 0,
    max_bpc_max: u64 = 0,
    colorspace_default: u64 = 0,
    colorspace_bt2020_rgb: u64 = 0,
    hdr: HdrStatic = .{},
    props: Props = .{},
    allocator: std.mem.Allocator,
    be: *Backend,

    pub const HdrStatic = struct {
        hdr10: bool = false,
        hlg: bool = false,
        bt2020: bool = false,
        max_luminance_cdm2: f32 = 0,
        max_frame_avg_luminance_cdm2: f32 = 0,
        min_luminance_cdm2: f32 = 0,
    };

    pub const Status = enum(u32) {
        connected = 1,
        disconnected = 2,
        unknown = 3,
    };

    pub const Props = struct {
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
        colorspace: u32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator, be: *Backend, connector_id: u32) !*Connector {
        const self = try alloc.create(Connector);
        errdefer alloc.destroy(self);

        const conn = c.drmModeGetConnector(be.drm_fd, connector_id) orelse return error.ConnectorNotFound;
        defer c.drmModeFreeConnector(conn);

        const type_name = typeName(conn.*.connector_type);
        const name = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ type_name, conn.*.connector_type_id });
        errdefer alloc.free(name);

        self.* = .{
            .id = connector_id,
            .name = name,
            .type = conn.*.connector_type,
            .type_id = conn.*.connector_type_id,
            .status = connectorStatus(conn.*.connection),
            .modes = std.ArrayList(output.Mode).empty,
            .allocator = alloc,
            .be = be,
        };
        errdefer self.deinitModes();

        try self.appendModes(conn.*.count_modes, conn.*.modes);
        self.loadProperties();
        return self;
    }

    pub fn deinit(self: *Connector) void {
        self.deinitModes();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    fn deinitModes(self: *Connector) void {
        for (self.modes.items) |mode| {
            destroyModeInfo(self.allocator, mode);
        }
        self.modes.deinit(self.allocator);
    }

    fn destroyModeInfo(alloc: std.mem.Allocator, mode: output.Mode) void {
        const info = mode.drm_mode_info orelse return;
        const mode_info: *c.drmModeModeInfo = @ptrCast(@alignCast(info));
        alloc.destroy(mode_info);
    }

    fn appendModes(self: *Connector, count: c_int, modes: [*]c.drmModeModeInfo) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.appendMode(self.allocator, modes[i]);
        }
    }

    fn loadProperties(self: *Connector) void {
        const props = c.drmModeObjectGetProperties(self.be.drm_fd, self.id, c.DRM_MODE_OBJECT_CONNECTOR) orelse return;
        defer c.drmModeFreeObjectProperties(props);
        var j: u32 = 0;
        while (j < props.*.count_props) : (j += 1) {
            self.parseProperty(props.*.props[j], props.*.prop_values[j]);
        }
    }

    fn parseProperty(self: *Connector, prop_id: u32, value: u64) void {
        const prop = c.drmModeGetProperty(self.be.drm_fd, prop_id) orelse return;
        defer c.drmModeFreeProperty(prop);
        const name = std.mem.sliceTo(prop.*.name[0..], 0);
        if (std.mem.eql(u8, name, "non-desktop")) {
            self.props.non_desktop = prop_id;
            self.non_desktop = value != 0;
            return;
        }
        if (std.mem.eql(u8, name, "max bpc")) {
            self.props.max_bpc = prop_id;
            self.readMaxBpcRange(prop.*.flags, prop.*.count_values, prop.*.values);
            return;
        }
        if (std.mem.eql(u8, name, "Colorspace")) {
            self.recordColorspace(prop, prop_id);
            return;
        }
        self.assignProperty(name, prop_id);
    }

    fn readMaxBpcRange(self: *Connector, flags: u32, count_values: i32, values: ?[*]u64) void {
        if ((flags & c.DRM_MODE_PROP_RANGE) == 0 or count_values < 2) return;
        const range = values orelse return;
        self.max_bpc_min = range[0];
        self.max_bpc_max = range[1];
    }

    fn assignProperty(self: *Connector, name: string, prop_id: u32) void {
        if (std.mem.eql(u8, name, "CRTC_ID")) {
            self.props.crtc_id = prop_id;
        } else if (std.mem.eql(u8, name, "DPMS")) {
            self.props.dpms = prop_id;
        } else if (std.mem.eql(u8, name, "EDID")) {
            self.props.edid = prop_id;
        } else if (std.mem.eql(u8, name, "link-status")) {
            self.props.link_status = prop_id;
        } else if (std.mem.eql(u8, name, "PATH")) {
            self.props.path = prop_id;
        } else if (std.mem.eql(u8, name, "vrr_capable")) {
            self.props.vrr_capable = prop_id;
        } else if (std.mem.eql(u8, name, "subconnector")) {
            self.props.subconnector = prop_id;
        } else if (std.mem.eql(u8, name, "panel orientation")) {
            self.props.panel_orientation = prop_id;
        } else if (std.mem.eql(u8, name, "content type")) {
            self.props.content_type = prop_id;
        } else if (std.mem.eql(u8, name, "HDR_OUTPUT_METADATA")) {
            self.props.hdr_output_metadata = prop_id;
        }
    }

    fn recordColorspace(self: *Connector, prop: *c.drmModePropertyRes, prop_id: u32) void {
        self.props.colorspace = prop_id;
        const enums = prop.*.enums orelse return;
        var i: i32 = 0;
        while (i < prop.*.count_enums) : (i += 1) {
            const entry = enums[@intCast(i)];
            const enum_name = std.mem.sliceTo(&entry.name, 0);
            if (std.mem.eql(u8, enum_name, "Default")) self.colorspace_default = entry.value;
            if (std.mem.eql(u8, enum_name, "BT2020_RGB")) self.colorspace_bt2020_rgb = entry.value;
        }
    }

    pub fn refreshFromKernel(self: *Connector) void {
        const drm_conn = c.drmModeGetConnector(self.be.drm_fd, self.id) orelse return;
        defer c.drmModeFreeConnector(drm_conn);
        self.status = connectorStatus(drm_conn.*.connection);
        self.reloadModesIfEmpty(drm_conn);
    }

    fn reloadModesIfEmpty(self: *Connector, drm_conn: *c.drmModeConnector) void {
        if (self.status != .connected) return;
        if (self.modes.items.len != 0) return;
        self.appendModes(drm_conn.count_modes, drm_conn.modes) catch return;
        self.loadProperties();
    }

    fn appendMode(self: *Connector, alloc: std.mem.Allocator, mode: c.drmModeModeInfo) !void {
        const info = try alloc.create(c.drmModeModeInfo);
        errdefer alloc.destroy(info);
        info.* = mode;
        try self.modes.append(alloc, .{
            .pixel_size = Vector2D.init(@floatFromInt(mode.hdisplay), @floatFromInt(mode.vdisplay)),
            .refresh_rate = refreshRateMillihertz(mode),
            .preferred = (mode.type & c.DRM_MODE_TYPE_PREFERRED) != 0,
            .drm_mode_info = info,
        });
    }

    fn typeName(kind: u32) string {
        return switch (kind) {
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

        const dmabuf_attrs = buffer.dmabuf();
        if (!dmabuf_attrs.success) return error.NoDMABufAttributes;

        var imports: [4]drm_fb.Import = .{ .{}, .{}, .{}, .{} };
        const count = framebufferImports(dmabuf_attrs, &imports);
        if (count == 0) return error.DMABufImportFailed;
        errdefer self.cleanupBoHandles(be.drm_fd);

        const width: u32 = @intFromFloat(dmabuf_attrs.size.getX());
        const height: u32 = @intFromFloat(dmabuf_attrs.size.getY());
        self.id = drm_fb.addFromImports(
            be.drm_fd,
            width,
            height,
            dmabuf_attrs.format,
            imports[0..count],
            &self.bo_handles,
            be.capabilities.supports_add_fb2_modifiers,
        ) orelse return error.AddFramebufferFailed;
        return self;
    }

    pub fn deinit(self: *Framebuffer) void {
        self.drop();
        self.allocator.destroy(self);
    }

    pub fn drop(self: *Framebuffer) void {
        if (self.dropped) return;
        self.dropped = true;

        if (self.id != 0) drm_fb.remove(self.be.drm_fd, self.id);
        self.cleanupBoHandles(self.be.drm_fd);
    }

    fn cleanupBoHandles(self: *Framebuffer, drm_fd: i32) void {
        drm_fb.closeHandles(drm_fd, &self.bo_handles);
    }
};

/// DRM backend capabilities
pub const Capabilities = struct {
    supports_add_fb2_modifiers: bool = false,
    supports_timeline_sync_obj: bool = false,
    supports_sync_obj_eventfd: bool = false,
};

/// DRM be implementation
pub const Backend = struct {
    allocator: std.mem.Allocator,
    drm_fd: i32 = -1,
    render_node_fd: i32 = -1,
    gpu_name: string,
    gpu_path: string,
    atomic_modesetting: bool = false,
    backend_ptr: ?*anyopaque = null, // Opaque pointer to avoid circular dependency
    session_device: ?*session.Device = null,
    render_session_device: ?*session.Device = null,
    seat_paused: bool = false,

    // DRM resources
    connectors: std.ArrayList(*Connector),
    crtcs: std.ArrayList(*CRTC),
    planes: std.ArrayList(*Plane),
    capabilities: Capabilities = .{},

    // Formats
    primary_formats: std.ArrayList(misc.DRMFormat),
    cursor_formats: std.ArrayList(misc.DRMFormat),
    outputs: std.ArrayList(*Output),

    // Poll FDs
    poll_fds: [1]backend.PollFd = undefined,
    gpu: ?*vulkan.Device = null,

    const Self = @This();

    /// Attempt to create DRM backends for all available GPUs
    pub fn attempt(alloc: std.mem.Allocator, backend_ptr: ?*anyopaque) !std.ArrayList(*Self) {
        var backends = std.ArrayList(*Self).empty;
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

        for (devices) |device| {
            const be = Self.fromGpu(alloc, device.path, backend_ptr, null) catch {
                cli.log.warn("Failed to create DRM backend for {s}", .{device.path});
                continue;
            };
            be.session_device = device;
            be.drm_fd = device.fd;
            try backends.append(alloc, be);
        }

        return backends;
    }

    /// Create DRM be from a specific GPU path
    pub fn fromGpu(
        alloc: std.mem.Allocator,
        path: string,
        be: ?*anyopaque,
        primary: ?*Self,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const name = std.Io.Dir.path.basename(path);
        const gpu_name = try alloc.dupe(u8, name);
        errdefer alloc.free(gpu_name);
        const gpu_path = try alloc.dupe(u8, path);
        errdefer alloc.free(gpu_path);

        self.* = .{
            .allocator = alloc,
            .gpu_name = gpu_name,
            .gpu_path = gpu_path,
            .backend_ptr = be,
            .connectors = std.ArrayList(*Connector).empty,
            .crtcs = std.ArrayList(*CRTC).empty,
            .planes = std.ArrayList(*Plane).empty,
            .primary_formats = std.ArrayList(misc.DRMFormat).empty,
            .cursor_formats = std.ArrayList(misc.DRMFormat).empty,
            .outputs = std.ArrayList(*Output).empty,
        };

        _ = primary; // For multi-GPU support later

        return self;
    }

    /// Create a coordinator implementation for the first available KMS GPU.
    pub fn createImplementation(coordinator: *backend.Coordinator) !backend.Implementation {
        var backends = try attempt(coordinator.allocator, coordinator);
        defer backends.deinit(coordinator.allocator);
        if (backends.items.len == 0) return error.BackendNotImplemented;

        const primary = adoptPrimaryGpu(backends.items) orelse return error.BackendNotImplemented;
        claimAdoptedPrimary(primary);
        return primary.asInterface();
    }

    pub fn deinit(self: *Self) void {
        for (self.outputs.items) |out| {
            out.deinit();
        }
        self.outputs.deinit(self.allocator);

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

        if (self.gpu) |gpu| {
            gpu.deinit();
            self.gpu = null;
        }
        if (self.session_device == null and self.drm_fd >= 0) {
            core.unix.close(self.drm_fd);
        }
        self.drm_fd = -1;
        self.closeRenderNode();

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
        return self.start();
    }

    pub fn start(self: *Self) bool {
        if (!self.openDevice()) return false;
        std.debug.assert(self.drm_fd >= 0);
        if (!self.enableAtomicModesetting()) {
            cli.log.err("DRM device {s} does not support atomic modesetting", .{self.gpu_path});
            return false;
        }

        if (c.drmSetClientCap(self.drm_fd, CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0) {
            cli.log.err("DRM device {s} does not support universal planes", .{self.gpu_path});
            return false;
        }
        self.probeModifierSupport();
        self.attachRenderNode();
        self.attachGpu();
        self.poll_fds[0] = .{
            .fd = self.drm_fd,
            .callback = null,
        };

        self.scanResources() catch return false;
        self.assignCrtcs();
        if (self.hasUsableOutput()) return true;
        cli.log.err("DRM device {s} has no usable connected output", .{self.gpu_path});
        return false;
    }

    /// True when at least one connected desktop connector has a CRTC.
    pub fn hasUsableOutput(self: *const Self) bool {
        for (self.connectors.items) |conn| {
            if (connectorIsUsable(conn)) return true;
        }
        return false;
    }

    /// Drop DRM master for a VT switch without closing fds.
    pub fn pauseForSeatDisable(self: *Self) void {
        if (self.drm_fd >= 0) _ = c.drmDropMaster(self.drm_fd);
        self.seat_paused = true;
        for (self.outputs.items) |out| {
            out.flags.waiting_flip = false;
        }
    }

    /// Reclaim DRM master after the seat is enabled again.
    pub fn resumeForSeatEnable(self: *Self) void {
        if (self.drm_fd >= 0) _ = c.drmSetMaster(self.drm_fd);
        self.seat_paused = false;
        for (self.outputs.items) |out| {
            out.flags.modeset_done = false;
        }
    }

    fn openDevice(self: *Self) bool {
        if (self.session_device == null) {
            cli.log.err("DRM backend requires a libseat-opened device", .{});
            return false;
        }
        return self.drm_fd >= 0;
    }

    /// Forget a seat-owned card fd without closing it.
    pub fn abandonSessionDevice(self: *Self) void {
        self.session_device = null;
        self.drm_fd = -1;
    }

    fn enableAtomicModesetting(self: *Self) bool {
        var has_atomic: u64 = 0;
        if (c.drmGetCap(self.drm_fd, CAP_ATOMIC, &has_atomic) != 0 or has_atomic == 0) return false;
        if (c.drmSetClientCap(self.drm_fd, CLIENT_CAP_ATOMIC, 1) != 0) return false;
        self.atomic_modesetting = true;
        return true;
    }

    fn probeModifierSupport(self: *Self) void {
        var has_modifiers: u64 = 0;
        if (c.drmGetCap(self.drm_fd, CAP_ADDFB2_MODIFIERS, &has_modifiers) != 0) return;
        self.capabilities.supports_add_fb2_modifiers = has_modifiers != 0;
    }

    fn attachGpu(self: *Self) void {
        if (self.gpu != null) return;
        const render_fd = if (self.render_node_fd >= 0) self.render_node_fd else return;
        self.gpu = vulkan.Device.create(self.allocator, render_fd, self.drm_fd) catch |err| {
            cli.log.warn("Vulkan scanout unavailable on {s}: {}", .{ self.gpu_path, err });
            return;
        };
        cli.log.info("Vulkan scanout ready on {s}", .{self.gpu_path});
    }

    fn attachRenderNode(self: *Self) void {
        if (self.render_node_fd >= 0) return;
        const name = c.drmGetRenderDeviceNameFromFd(self.drm_fd) orelse return;
        defer std.c.free(name);
        self.render_node_fd = self.openRenderNodeFd(std.mem.span(name));
    }

    fn openRenderNodeFd(self: *Self, path: string) i32 {
        if (self.openRenderNodeViaSession(path)) |fd| return fd;
        return core.unix.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch -1;
    }

    fn openRenderNodeViaSession(self: *Self, path: string) ?i32 {
        const sess_dev = self.session_device orelse return null;
        const sess = sess_dev.session orelse return null;
        const opened = session.Device.open(self.allocator, sess, path) catch return null;
        self.render_session_device = opened;
        return opened.fd;
    }

    fn closeRenderNode(self: *Self) void {
        if (self.render_session_device) |dev| {
            dev.deinit();
            self.render_session_device = null;
            self.render_node_fd = -1;
            return;
        }
        if (self.render_node_fd < 0) return;
        core.unix.close(self.render_node_fd);
        self.render_node_fd = -1;
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
        self.scanOutputs() catch {
            cli.log.err("Failed to scan DRM outputs", .{});
        };
        self.createOutputs() catch {
            cli.log.err("Failed to create DRM outputs", .{});
        };
    }

    /// Re-read every connector and create or destroy outputs to match.
    pub fn rescanConnectors(self: *Self) !void {
        try self.rescanHotplug(0);
    }

    /// `connector_id == 0` refreshes all connectors; otherwise that connector.
    pub fn rescanHotplug(self: *Self, connector_id: u32) !void {
        try self.adoptMissingConnectors(connector_id);
        self.refreshConnectorStatus(connector_id);
        self.releaseUnusableCrtcs();
        self.assignCrtcs();
        self.destroyUnusableOutputs();
        try self.createOutputs();
    }

    fn createOutputs(self: *Self) !void {
        for (self.connectors.items) |conn| {
            try self.createConnectedOutput(conn);
        }
    }

    fn createConnectedOutput(self: *Self, conn: *Connector) !void {
        if (!connectorIsUsable(conn)) return;
        if (self.outputForConnector(conn.id) != null) return;
        const out = try Output.create(self.allocator, self, conn);
        errdefer out.deinit();
        out.preheatScanout();
        try self.outputs.append(self.allocator, out);
        cli.log.info("DRM output {s} ready", .{out.name});
    }

    fn adoptMissingConnectors(self: *Self, connector_id: u32) !void {
        if (self.drm_fd < 0) return;
        if (connector_id != 0) {
            try self.adoptConnector(connector_id);
            return;
        }
        try self.discoverConnectors();
    }

    fn discoverConnectors(self: *Self) !void {
        const resources = c.drmModeGetResources(self.drm_fd) orelse return;
        defer c.drmModeFreeResources(resources);
        var index: usize = 0;
        while (index < resources.*.count_connectors) : (index += 1) {
            try self.adoptConnector(resources.*.connectors[index]);
        }
    }

    fn adoptConnector(self: *Self, connector_id: u32) !void {
        if (self.connectorById(connector_id) != null) return;
        const connector = Connector.init(self.allocator, self, connector_id) catch return;
        try self.connectors.append(self.allocator, connector);
    }

    fn refreshConnectorStatus(self: *Self, connector_id: u32) void {
        if (self.drm_fd < 0) return;
        for (self.connectors.items) |conn| {
            if (connector_id != 0 and conn.id != connector_id) continue;
            conn.refreshFromKernel();
        }
    }

    fn releaseUnusableCrtcs(self: *Self) void {
        for (self.connectors.items) |conn| {
            if (conn.status == .connected and !conn.non_desktop) continue;
            conn.crtc = null;
        }
    }

    fn destroyUnusableOutputs(self: *Self) void {
        var index: usize = 0;
        while (index < self.outputs.items.len) {
            const out = self.outputs.items[index];
            if (connectorIsUsable(out.connector)) {
                index += 1;
                continue;
            }
            _ = self.outputs.swapRemove(index);
            finishDestroyedOutput(out);
        }
    }

    fn outputForConnector(self: *const Self, connector_id: u32) ?*Output {
        for (self.outputs.items) |out| {
            if (out.connector.id == connector_id) return out;
        }
        return null;
    }

    fn connectorById(self: *const Self, connector_id: u32) ?*Connector {
        for (self.connectors.items) |conn| {
            if (conn.id == connector_id) return conn;
        }
        return null;
    }

    pub fn dispatchEvents(self: *Self) void {
        if (self.drm_fd < 0) return;
        handleDrmEvents(self.drm_fd);
    }

    fn assignCrtcs(self: *Self) void {
        var used = usedCrtcMask(self.connectors.items);
        for (self.connectors.items) |conn| {
            if (conn.crtc != null) continue;
            if (conn.status != .connected or conn.non_desktop) continue;
            const crtc = self.pickCrtc(conn, used) orelse continue;
            conn.crtc = crtc;
            used |= crtcBit(crtc.legacy_crtc_idx);
        }
    }

    fn pickCrtc(self: *Self, conn: *Connector, used: u32) ?*CRTC {
        const drm_conn = c.drmModeGetConnectorCurrent(self.drm_fd, conn.id) orelse
            c.drmModeGetConnector(self.drm_fd, conn.id) orelse return null;
        defer c.drmModeFreeConnector(drm_conn);
        if (self.crtcForEncoder(drm_conn.*.encoder_id, used)) |crtc| return crtc;
        return self.crtcFromEncoderList(drm_conn, used);
    }

    fn crtcFromEncoderList(self: *Self, drm_conn: *c.drmModeConnector, used: u32) ?*CRTC {
        var index: usize = 0;
        while (index < drm_conn.*.count_encoders) : (index += 1) {
            if (self.crtcForEncoder(drm_conn.*.encoders[index], used)) |crtc| return crtc;
        }
        return null;
    }

    fn crtcForEncoder(self: *Self, encoder_id: u32, used: u32) ?*CRTC {
        if (encoder_id == 0) return null;
        const encoder = c.drmModeGetEncoder(self.drm_fd, encoder_id) orelse return null;
        defer c.drmModeFreeEncoder(encoder);
        if (self.crtcIfUsable(encoder.*.crtc_id, encoder.*.possible_crtcs, used)) |crtc| return crtc;
        for (self.crtcs.items, 0..) |crtc, idx| {
            if (!crtcBitUsable(encoder.*.possible_crtcs, used, idx)) continue;
            return crtc;
        }
        return null;
    }

    fn crtcIfUsable(self: *Self, crtc_id: u32, possible: u32, used: u32) ?*CRTC {
        if (crtc_id == 0) return null;
        for (self.crtcs.items, 0..) |crtc, idx| {
            if (crtc.id != crtc_id) continue;
            if (!crtcBitUsable(possible, used, idx)) return null;
            return crtc;
        }
        return null;
    }

    fn crtcBitUsable(possible: u32, used: u32, idx: usize) bool {
        const mask = @as(u32, 1) << @intCast(idx);
        return (possible & mask) != 0 and (used & mask) == 0;
    }

    /// Scan connected outputs and parse EDID information
    fn scanOutputs(self: *Self) !void {
        for (self.connectors.items) |conn| {
            if (conn.status != .connected) continue;
            cli.log.debug("Found connected output: {s}", .{conn.name});
            self.logConnectorEdid(conn);
            self.logConnectorModes(conn);
        }
    }

    fn logConnectorEdid(self: *Self, conn: *Connector) void {
        if (conn.props.edid == 0) return;
        const edid_data = self.readEdid(conn) catch {
            cli.log.warn("Failed to read EDID for {s}", .{conn.name});
            return;
        };
        defer self.allocator.free(edid_data);
        self.logParsedEdid(conn.name, edid_data);
        self.logHdrCaps(conn, edid_data);
    }

    fn logParsedEdid(_: *Self, name: string, edid_data: []const u8) void {
        const edid_parser = @import("core.display").edid;
        const parsed = edid_parser.fast.parse(edid_data) catch {
            cli.log.warn("Failed to parse EDID for {s}", .{name});
            return;
        };
        const manufacturer = parsed.getManufacturerName() orelse "Unknown";
        cli.log.debug("Display {s}: {s} (Serial: {d})", .{ name, manufacturer, parsed.getSerialNumber() });
        const width_cm = parsed.getScreenWidthCm();
        const height_cm = parsed.getScreenHeightCm();
        if (width_cm == 0 or height_cm == 0) return;
        cli.log.debug("Physical size {s}: {d}x{d} cm", .{ name, width_cm, height_cm });
    }

    fn logConnectorModes(_: *Self, conn: *Connector) void {
        if (conn.modes.items.len == 0) return;
        cli.log.debug("Available modes for {s}: {d}", .{ conn.name, conn.modes.items.len });
        for (conn.modes.items) |mode| {
            if (!mode.preferred) continue;
            cli.log.debug("Preferred mode {s}: {d}x{d} @ {d}Hz", .{
                conn.name,
                @as(u32, @intFromFloat(mode.pixel_size.getX())),
                @as(u32, @intFromFloat(mode.pixel_size.getY())),
                mode.refresh_rate / 1000,
            });
            return;
        }
    }

    fn logHdrCaps(self: *Self, conn: *Connector, edid_data: []const u8) void {
        _ = self;
        const cta = @import("core.display").cta;
        var offset: usize = 128;
        while (offset + 128 <= edid_data.len) : (offset += 128) {
            if (edid_data[offset] != cta.extension_tag) continue;
            const bytes: *align(1) const [128]u8 = @ptrCast(edid_data[offset .. offset + 128]);
            const extension = cta.CtaExtensionBlock.fromBytes(bytes);
            const hdr = extension.getHdrStaticMetadata() orelse continue;
            const colorimetry = extension.getColorimetryBlock();
            conn.hdr = .{
                .hdr10 = hdr.supportsHdr10(),
                .hlg = hdr.supportsHlg(),
                .bt2020 = if (colorimetry) |value| value.supportsBt2020() else false,
                .max_luminance_cdm2 = hdr.max_luminance_cdm2,
                .max_frame_avg_luminance_cdm2 = hdr.max_frame_avg_luminance_cdm2,
                .min_luminance_cdm2 = hdr.min_luminance_cdm2,
            };
            cli.log.info(
                "HDR caps {s}: HDR10={} HLG={} BT.2020={} max={d:.1} avg={d:.1} min={d:.4} cd/m2",
                .{
                    conn.name,
                    conn.hdr.hdr10,
                    conn.hdr.hlg,
                    conn.hdr.bt2020,
                    conn.hdr.max_luminance_cdm2,
                    conn.hdr.max_frame_avg_luminance_cdm2,
                    conn.hdr.min_luminance_cdm2,
                },
            );
            return;
        }
        conn.hdr = .{};
        cli.log.info("HDR caps {s}: SDR-only (no CTA HDR static metadata)", .{conn.name});
    }

    fn readEdid(self: *Self, conn: *Connector) ![]u8 {
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

    fn assignPlane(self: *Self, plane: *Plane) void {
        for (self.crtcs.items, 0..) |crtc, crtc_idx| {
            if ((plane.possible_crtcs & crtcBit(@intCast(crtc_idx))) == 0) continue;
            if (takePlane(crtc, plane)) return;
        }
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
            self.assignPlane(plane);
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
        const blob = self.readInFormatsBlob(plane);
        defer if (blob) |bytes| self.allocator.free(bytes);
        for (plane.formats.items) |format| {
            try self.appendPlaneFormat(format_list, format, blob);
        }
    }

    fn appendPlaneFormat(
        self: *Self,
        format_list: *std.ArrayList(misc.DRMFormat),
        format: u32,
        blob: ?[]const u8,
    ) !void {
        var drm_fmt = misc.DRMFormat.init(self.allocator);
        errdefer drm_fmt.deinit(self.allocator);
        drm_fmt.drm_format = format;
        if (blob) |bytes| {
            try drm_format.appendModifiers(bytes, format, self.allocator, &drm_fmt.modifiers);
            if (drm_fmt.modifiers.items.len == 0) return;
        } else {
            try drm_fmt.addModifier(self.allocator, drm_format.MOD_LINEAR);
        }
        try format_list.append(self.allocator, drm_fmt);
    }

    fn readInFormatsBlob(self: *Self, plane: *const Plane) ?[]u8 {
        if (plane.props.in_formats_blob == 0) return null;
        const blob = c.drmModeGetPropertyBlob(self.drm_fd, @intCast(plane.props.in_formats_blob)) orelse
            return null;
        defer c.drmModeFreePropertyBlob(blob);
        const len = blob.*.length;
        if (len == 0) return null;
        const src: [*]const u8 = @ptrCast(blob.*.data);
        return self.allocator.dupe(u8, src[0..len]) catch null;
    }
};

fn scanGPUs(alloc: std.mem.Allocator, sess: *session.Type) ![]const *session.Device {
    return sess.collectKmsDevices(alloc);
}

fn framebufferImports(attrs: @import("../buffer.zig").DMABUFAttrs, imports: *[4]drm_fb.Import) usize {
    const count: usize = @intCast(@min(@max(attrs.planes, 0), 4));
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (attrs.fds[index] < 0) return 0;
        imports[index] = .{
            .fd = attrs.fds[index],
            .stride = attrs.strides[index],
            .offset = attrs.offsets[index],
            .modifier = attrs.modifier,
        };
    }
    return count;
}

fn takePlane(crtc: *CRTC, plane: *Plane) bool {
    if (plane.type == .primary and crtc.primary == null) {
        crtc.primary = plane;
        return true;
    }
    if (plane.type == .cursor and crtc.cursor == null) {
        crtc.cursor = plane;
        return true;
    }
    return false;
}

fn connectorIsUsable(conn: *const Connector) bool {
    return conn.status == .connected and !conn.non_desktop and conn.crtc != null;
}

fn connectorStatus(connection: c.drmModeConnection) Connector.Status {
    return switch (connection) {
        c.DRM_MODE_CONNECTED => .connected,
        c.DRM_MODE_DISCONNECTED => .disconnected,
        else => .unknown,
    };
}

fn usedCrtcMask(connectors: []const *Connector) u32 {
    var used: u32 = 0;
    for (connectors) |conn| {
        const crtc = conn.crtc orelse continue;
        used |= crtcBit(crtc.legacy_crtc_idx);
    }
    return used;
}

fn crtcBit(legacy_idx: u32) u32 {
    return @as(u32, 1) << @intCast(legacy_idx);
}

fn finishDestroyedOutput(out: *Output) void {
    const callback = out.destroy_event_callback;
    const userdata = out.destroy_event_userdata;
    out.destroy_event_callback = null;
    out.destroy_event_userdata = null;
    if (callback) |cb| cb(userdata);
    out.deinit();
}

/// Keep backends[0], release unused GPUs, and deinit extras.
fn adoptPrimaryGpu(backends: []const *Backend) ?*Backend {
    if (backends.len == 0) return null;
    const primary = backends[0];
    for (backends[1..]) |extra| disposeUnusedGpu(extra);
    return primary;
}

fn disposeUnusedGpu(extra: *Backend) void {
    releaseUnusedGpu(extra);
    extra.abandonSessionDevice();
    extra.deinit();
}

fn releaseUnusedGpu(extra: *Backend) void {
    const device = extra.session_device orelse return;
    const sess = device.session orelse {
        device.deinit();
        return;
    };
    releaseExtraDevice(sess, device);
}

fn claimAdoptedPrimary(primary: *Backend) void {
    const device = primary.session_device orelse return;
    const sess = device.session orelse return;
    claimPrimaryDevice(sess, device);
}

fn claimPrimaryDevice(sess: *session.Type, device: *session.Device) void {
    sess.claimKmsDevice(device);
}

fn releaseExtraDevice(sess: *session.Type, device: *session.Device) void {
    sess.releaseKmsDevice(device);
}

/// Convert a KMS mode to millihertz. Kernel `vrefresh` is often 0 or rounded.
pub fn refreshRateMillihertz(mode: c.drmModeModeInfo) u32 {
    if (mode.htotal == 0 or mode.vtotal == 0) return mode.vrefresh * 1000;
    var num: u64 = @as(u64, mode.clock) * 1_000_000;
    var den: u64 = @as(u64, mode.htotal) * @as(u64, mode.vtotal);
    if ((mode.flags & c.DRM_MODE_FLAG_INTERLACE) != 0) num *= 2;
    if ((mode.flags & c.DRM_MODE_FLAG_DBLSCAN) != 0) den *= 2;
    if (mode.vscan > 1) den *= mode.vscan;
    return @intCast((num + den / 2) / den);
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

    /// Rewind the libdrm request so the same allocation can be reused on the next flip.
    pub fn reset(self: *Self) void {
        const req = self.request orelse {
            self.failed = true;
            return;
        };
        c.drmModeAtomicSetCursor(req, 0);
        self.failed = false;
    }

    pub fn cursor(self: *const Self) c_int {
        const req = self.request orelse return 0;
        return c.drmModeAtomicGetCursor(req);
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
        const src_w: u64 = crtc_w << 16;
        const src_h: u64 = crtc_h << 16;
        self.add(plane.id, plane.props.src_x, 0);
        self.add(plane.id, plane.props.src_y, 0);
        self.add(plane.id, plane.props.src_w, src_w);
        self.add(plane.id, plane.props.src_h, src_h);
    }

    /// Commit the atomic request
    pub fn commit(self: *Self, flags: u32, drm_fd: i32, userdata: ?*anyopaque) bool {
        if (self.failed) return false;

        if (self.request) |req| {
            const result = c.drmModeAtomicCommit(drm_fd, req, flags, userdata);
            return result == 0;
        }
        return false;
    }
};

fn handleDrmEvents(drm_fd: i32) void {
    var context = std.mem.zeroes(c.drmEventContext);
    context.version = 3;
    context.page_flip_handler2 = pageFlipHandler;
    _ = c.drmHandleEvent(drm_fd, &context);
}

fn pageFlipHandler(
    fd: c_int,
    sequence: c_uint,
    tv_sec: c_uint,
    tv_usec: c_uint,
    crtc_id: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = fd;
    _ = sequence;
    _ = tv_sec;
    _ = tv_usec;
    _ = crtc_id;
    std.debug.assert(user_data != null);
    const out: *Output = @ptrCast(@alignCast(user_data.?));
    out.handlePageFlip();
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

test "DRMBackend - start without libseat device does not open a card" {
    const testing = core.testing;

    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    try testing.expect(!be.start());
    try testing.expectEqual(@as(i32, -1), be.drm_fd);
    try testing.expect(be.session_device == null);
}

test "DRMBackend - abandonSessionDevice forgets the seat fd" {
    const testing = core.testing;

    var sess = try session.Type.init(testing.allocator);
    defer sess.deinit();
    var device = try session.Device.init(testing.allocator, sess, "/dev/dri/card0");
    defer device.deinit();

    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    be.drm_fd = 42;
    be.session_device = device;
    be.abandonSessionDevice();
    try testing.expectEqual(@as(i32, -1), be.drm_fd);
    try testing.expect(be.session_device == null);
}

test "DRMBackend - createImplementation without session fails" {
    const testing = core.testing;
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, .{});
    defer coordinator.deinit();

    try testing.expectError(error.BackendNotImplemented, Backend.createImplementation(coordinator));
}

test "assignPlane - primary attaches to one CRTC" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    var crtc0 = CRTC{ .id = 1, .legacy_crtc_idx = 0, .allocator = testing.allocator };
    var crtc1 = CRTC{ .id = 2, .legacy_crtc_idx = 1, .allocator = testing.allocator };
    try be.crtcs.append(testing.allocator, &crtc0);
    try be.crtcs.append(testing.allocator, &crtc1);
    defer be.crtcs.clearRetainingCapacity();

    var plane = Plane{
        .id = 10,
        .type = .primary,
        .initial_fb_id = 0,
        .possible_crtcs = 0b11,
        .formats = std.ArrayList(u32).empty,
        .allocator = testing.allocator,
    };
    defer plane.formats.deinit(testing.allocator);

    be.assignPlane(&plane);
    try testing.expect(crtc0.primary == &plane);
    try testing.expect(crtc1.primary == null);
}

test "hasUsableOutput - no connectors is false" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    try testing.expect(!be.hasUsableOutput());
}

test "hasUsableOutput - only connected desktop CRTC counts" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    var crtc = CRTC{ .id = 1, .legacy_crtc_idx = 0, .allocator = testing.allocator };
    try expectUsableOutput(be, .connected, false, &crtc, true);
    try expectUsableOutput(be, .connected, true, &crtc, false);
    try expectUsableOutput(be, .disconnected, false, &crtc, false);
    try expectUsableOutput(be, .connected, false, null, false);
}

test "adoptPrimaryGpu - empty list is null" {
    const testing = core.testing;
    try testing.expect(adoptPrimaryGpu(&[_]*Backend{}) == null);
}

test "adoptPrimaryGpu - one backend is kept" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    const backends = [_]*Backend{be};
    try testing.expect(adoptPrimaryGpu(&backends) == be);
}

test "adoptPrimaryGpu - two backends deinits the extra" {
    const testing = core.testing;
    const primary = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer primary.deinit();
    const extra = try Backend.fromGpu(testing.allocator, "/dev/dri/card1", null, null);
    const backends = [_]*Backend{ primary, extra };
    try testing.expect(adoptPrimaryGpu(&backends) == primary);
}

test "adoptPrimaryGpu - extra session device leaves kms_devices" {
    const testing = core.testing;
    var sess = try session.Type.init(testing.allocator);
    defer sess.deinit();

    const primary_dev = try session.Device.init(testing.allocator, sess, "/dev/dri/card0");
    const extra_dev = try session.Device.init(testing.allocator, sess, "/dev/dri/card1");
    try sess.kms_devices.append(sess.allocator, primary_dev);
    try sess.kms_devices.append(sess.allocator, extra_dev);

    const primary = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer primary.deinit();
    primary.session_device = primary_dev;

    const extra = try Backend.fromGpu(testing.allocator, "/dev/dri/card1", null, null);
    extra.session_device = extra_dev;

    const backends = [_]*Backend{ primary, extra };
    try testing.expect(adoptPrimaryGpu(&backends) == primary);
    claimAdoptedPrimary(primary);

    try testing.expect(primary_dev.claimed);
    try testing.expectEqual(@as(usize, 1), sess.kms_devices.items.len);
    try testing.expect(sess.kms_devices.items[0] == primary_dev);
}

test "pauseForSeatDisable - toggles seat_paused without ioctl" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();

    try testing.expect(!be.seat_paused);
    try testing.expectEqual(@as(i32, -1), be.drm_fd);
    be.pauseForSeatDisable();
    try testing.expect(be.seat_paused);
    be.resumeForSeatEnable();
    try testing.expect(!be.seat_paused);
}

fn expectUsableOutput(
    be: *Backend,
    status: Connector.Status,
    non_desktop: bool,
    crtc: ?*CRTC,
    usable: bool,
) !void {
    var connector = Connector{
        .id = 1,
        .name = "HDMI-A-1",
        .type = 0,
        .type_id = 1,
        .status = status,
        .modes = std.ArrayList(output.Mode).empty,
        .crtc = crtc,
        .non_desktop = non_desktop,
        .allocator = be.allocator,
        .be = be,
    };
    try be.connectors.append(be.allocator, &connector);
    defer be.connectors.clearRetainingCapacity();
    try core.testing.expectEqual(usable, be.hasUsableOutput());
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

test "AtomicRequest - reset reuses the same req" {
    const testing = core.testing;

    var request = AtomicRequest.init(testing.allocator, null);
    defer request.deinit();

    request.add(1, 2, 3);
    const filled = request.cursor();
    try testing.expect(filled > 0);

    request.reset();
    try testing.expectEqual(@as(c_int, 0), request.cursor());
    try testing.expect(!request.failed);

    request.add(1, 2, 3);
    try testing.expectEqual(filled, request.cursor());
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

test "Plane.Props - initialization" {
    const testing = core.testing;

    const props: Plane.Props = .{};
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
        .formats = std.ArrayList(u32).empty,
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
        .formats = std.ArrayList(u32).empty,
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

test "framebufferImports - copies planes and rejects a missing fd" {
    const testing = core.testing;
    var imports: [4]drm_fb.Import = .{ .{}, .{}, .{}, .{} };
    const count = framebufferImports(.{
        .success = true,
        .planes = 1,
        .fds = .{ 3, -1, -1, -1 },
        .strides = .{ 7680, 0, 0, 0 },
        .offsets = .{ 16, 0, 0, 0 },
        .modifier = drm_format.MOD_LINEAR,
    }, &imports);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(i32, 3), imports[0].fd);
    try testing.expectEqual(@as(u32, 7680), imports[0].stride);
    try testing.expectEqual(@as(usize, 0), framebufferImports(.{
        .success = true,
        .planes = 1,
        .fds = .{ -1, -1, -1, -1 },
    }, &imports));
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

test "refreshRateMillihertz - 1080p60 from clock and totals" {
    const testing = core.testing;
    var mode = std.mem.zeroes(c.drmModeModeInfo);
    mode.clock = 148500;
    mode.hdisplay = 1920;
    mode.htotal = 2200;
    mode.vdisplay = 1080;
    mode.vtotal = 1125;
    try testing.expectEqual(@as(u32, 60000), refreshRateMillihertz(mode));
}

test "refreshRateMillihertz - falls back to kernel vrefresh" {
    const testing = core.testing;
    var mode = std.mem.zeroes(c.drmModeModeInfo);
    mode.vrefresh = 75;
    try testing.expectEqual(@as(u32, 75000), refreshRateMillihertz(mode));
}

fn stackConnector(
    be: *Backend,
    id: u32,
    name: string,
    status: Connector.Status,
    non_desktop: bool,
    crtc: ?*CRTC,
) Connector {
    return .{
        .id = id,
        .name = name,
        .type = 0,
        .type_id = 1,
        .status = status,
        .modes = std.ArrayList(output.Mode).empty,
        .crtc = crtc,
        .non_desktop = non_desktop,
        .allocator = be.allocator,
        .be = be,
    };
}

test "rescanConnectors - no connectors does not add outputs" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    try be.rescanConnectors();
    try testing.expectEqual(@as(usize, 0), be.outputs.items.len);
}

test "rescanConnectors - no status change does not add outputs" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    var connector = stackConnector(be, 1, "HDMI-A-1", .disconnected, false, null);
    try be.connectors.append(be.allocator, &connector);
    defer be.connectors.clearRetainingCapacity();
    try be.rescanConnectors();
    try testing.expectEqual(@as(usize, 0), be.outputs.items.len);
    try be.rescanConnectors();
    try testing.expectEqual(@as(usize, 0), be.outputs.items.len);
}

test "rescanConnectors - does not duplicate an already-created output" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    var crtc = CRTC{ .id = 1, .legacy_crtc_idx = 0, .allocator = testing.allocator };
    var connector = stackConnector(be, 8, "DP-1", .connected, false, &crtc);
    try be.connectors.append(be.allocator, &connector);
    defer be.connectors.clearRetainingCapacity();
    try be.rescanConnectors();
    try testing.expectEqual(@as(usize, 1), be.outputs.items.len);
    try be.rescanConnectors();
    try testing.expectEqual(@as(usize, 1), be.outputs.items.len);
    try testing.expectEqual(@as(u32, 8), be.outputs.items[0].connector.id);
}

test "rescanConnectors - disconnected and non_desktop connectors are not created" {
    const testing = core.testing;
    var be = try Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    var crtc = CRTC{ .id = 1, .legacy_crtc_idx = 0, .allocator = testing.allocator };
    var disconnected = stackConnector(be, 2, "HDMI-A-1", .disconnected, false, &crtc);
    var non_desktop = stackConnector(be, 3, "DP-2", .connected, true, &crtc);
    try be.connectors.append(be.allocator, &disconnected);
    try be.connectors.append(be.allocator, &non_desktop);
    defer be.connectors.clearRetainingCapacity();
    try be.rescanConnectors();
    try testing.expectEqual(@as(usize, 0), be.outputs.items.len);
}
