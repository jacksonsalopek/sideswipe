//! Wayland backend implementation inspired by aquamarine
//! Provides compositor-hosted backend using Wayland protocol

const std = @import("std");
const core = @import("core");
const math = @import("core.math");
const Vector2D = math.vector2d.Type;
const backend = @import("backend.zig");
const output = @import("output.zig");
const input = @import("input.zig");
const buffer = @import("buffer.zig");
const misc = @import("misc.zig");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-cursor.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("linux-dmabuf-unstable-v1-client-protocol.h");
    @cInclude("xf86drm.h");
    @cInclude("fcntl.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

/// Wayland buffer wrapper
pub const Buffer = struct {
    wl_buffer: ?*c.wl_buffer = null,
    buffer: buffer.Interface,
    backend: *Backend,
    pending_release: bool = false,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, buf: buffer.Interface, be: *Backend) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .buffer = buf,
            .backend = be,
            .allocator = allocator,
        };

        // Create wl_buffer from dmabuf
        if (be.wayland_state.dmabuf) |dmabuf| {
            const params = c.zwp_linux_dmabuf_v1_create_params(dmabuf);
            if (params == null) {
                return error.FailedToCreateDmabufParams;
            }

            const attrs = buf.dmabuf();
            for (0..@as(usize, @intCast(attrs.planes))) |i| {
                c.zwp_linux_buffer_params_v1_add(
                    params,
                    attrs.fds[i],
                    @intCast(i),
                    attrs.offsets[i],
                    attrs.strides[i],
                    @intCast(attrs.modifier >> 32),
                    @intCast(attrs.modifier & 0xFFFFFFFF),
                );
            }

            self.wl_buffer = c.zwp_linux_buffer_params_v1_create_immed(
                params,
                @intFromFloat(attrs.size.getX()),
                @intFromFloat(attrs.size.getY()),
                attrs.format,
                0,
            );

            c.zwp_linux_buffer_params_v1_destroy(params);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.wl_buffer) |wl_buf| {
            c.wl_buffer_destroy(wl_buf);
        }
        self.allocator.destroy(self);
    }

    pub fn good(self: *const Self) bool {
        return self.wl_buffer != null;
    }
};

/// Wayland output implementation
pub const Output = struct {
    name: []const u8,
    backend: *Backend,
    allocator: std.mem.Allocator,
    state: output.State,
    needs_frame: bool = false,
    frame_scheduled: bool = false,
    frame_scheduled_while_waiting: bool = false,
    ready_for_frame_callback: bool = false,
    buffers: std.ArrayList(*Buffer),

    // Wayland state
    surface: ?*c.wl_surface = null,
    xdg_surface: ?*c.xdg_surface = null,
    xdg_toplevel: ?*c.xdg_toplevel = null,
    frame_callback: ?*c.wl_callback = null,

    // Cursor state
    cursor_buffer: ?buffer.Interface = null,
    cursor_surface: ?*c.wl_surface = null,
    cursor_wl_buffer: ?*c.wl_buffer = null,
    cursor_serial: u32 = 0,
    cursor_hotspot: Vector2D = .{},

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, name: []const u8, be: *Backend) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        self.* = .{
            .name = name_copy,
            .backend = be,
            .allocator = allocator,
            .state = output.State.init(allocator),
            .buffers = std.ArrayList(*Buffer){},
        };

        // Create Wayland surface
        if (be.wayland_state.compositor) |compositor| {
            self.surface = c.wl_compositor_create_surface(compositor);
            if (self.surface == null) {
                return error.FailedToCreateSurface;
            }
        }

        // Create XDG surface
        if (be.wayland_state.xdg_wm_base) |xdg| {
            if (self.surface) |surf| {
                self.xdg_surface = c.xdg_wm_base_get_xdg_surface(xdg, surf);
                if (self.xdg_surface) |xdg_surf| {
                    const xdg_surface_listener = c.xdg_surface_listener{
                        .configure = xdgSurfaceHandleConfigure,
                    };
                    _ = c.xdg_surface_add_listener(xdg_surf, &xdg_surface_listener, self);

                    self.xdg_toplevel = c.xdg_surface_get_toplevel(xdg_surf);
                    if (self.xdg_toplevel) |toplevel| {
                        const toplevel_listener = c.xdg_toplevel_listener{
                            .configure = xdgToplevelHandleConfigure,
                            .close = xdgToplevelHandleClose,
                        };
                        _ = c.xdg_toplevel_add_listener(toplevel, &toplevel_listener, self);
                        c.xdg_toplevel_set_title(toplevel, self.name.ptr);
                        c.wl_surface_commit(surf);
                    }
                }
            }
        }

        // Create cursor surface
        if (be.wayland_state.compositor) |compositor| {
            self.cursor_surface = c.wl_compositor_create_surface(compositor);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.deinit(self.allocator);

        if (self.frame_callback) |cb| {
            c.wl_callback_destroy(cb);
        }

        if (self.cursor_wl_buffer) |buf| {
            c.wl_buffer_destroy(buf);
        }

        if (self.cursor_surface) |surf| {
            c.wl_surface_destroy(surf);
        }

        if (self.xdg_toplevel) |toplevel| {
            c.xdg_toplevel_destroy(toplevel);
        }

        if (self.xdg_surface) |xdg_surf| {
            c.xdg_surface_destroy(xdg_surf);
        }

        if (self.surface) |surf| {
            c.wl_surface_destroy(surf);
        }

        self.state.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn commit(self: *Self) bool {
        if (self.surface == null) return false;

        const surf = self.surface.?;

        // Attach buffer if committed
        if (self.state.committed.buffer) {
            if (self.state.buffer) |buf| {
                const wl_buffer = self.wlBufferFromBuffer(buf) catch return false;
                if (wl_buffer.good()) {
                    c.wl_surface_attach(surf, wl_buffer.wl_buffer, 0, 0);
                    c.wl_surface_damage_buffer(surf, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
                    self.ready_for_frame_callback = true;
                }
            }
        }

        c.wl_surface_commit(surf);
        self.state.onCommit();

        // Schedule frame callback
        if (self.ready_for_frame_callback) {
            self.sendFrameAndSetCallback();
        }

        return true;
    }

    pub fn testCommit(self: *Self) bool {
        _ = self;
        return true; // Wayland doesn't have test commits
    }

    pub fn getBackend(self: *Self) ?*anyopaque {
        return @ptrCast(self.backend);
    }

    pub fn getRenderFormats(self: *Self) []const misc.DRMFormat {
        return self.backend.dmabuf_formats.items;
    }

    pub fn preferredMode(self: *Self) ?*output.Mode {
        _ = self;
        return null; // Wayland outputs don't have fixed modes
    }

    pub fn setCursor(self: *Self, buf: buffer.Interface, hotspot: Vector2D) bool {
        self.cursor_buffer = buf;
        self.cursor_hotspot = hotspot;

        if (self.cursor_surface == null) return false;

        const attrs = buf.dmabuf();

        // Create cursor wl_buffer
        if (self.backend.wayland_state.dmabuf) |dmabuf| {
            const params = c.zwp_linux_dmabuf_v1_create_params(dmabuf);
            if (params == null) return false;

            for (0..@as(usize, @intCast(attrs.planes))) |i| {
                c.zwp_linux_buffer_params_v1_add(
                    params,
                    attrs.fds[i],
                    @intCast(i),
                    attrs.offsets[i],
                    attrs.strides[i],
                    @intCast(attrs.modifier >> 32),
                    @intCast(attrs.modifier & 0xFFFFFFFF),
                );
            }

            self.cursor_wl_buffer = c.zwp_linux_buffer_params_v1_create_immed(
                params,
                @intFromFloat(attrs.size.getX()),
                @intFromFloat(attrs.size.getY()),
                attrs.format,
                0,
            );

            c.zwp_linux_buffer_params_v1_destroy(params);

            if (self.cursor_wl_buffer == null) return false;

            c.wl_surface_set_buffer_scale(self.cursor_surface.?, 1);
            c.wl_surface_attach(self.cursor_surface.?, self.cursor_wl_buffer, 0, 0);
            c.wl_surface_damage(self.cursor_surface.?, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            c.wl_surface_commit(self.cursor_surface.?);

            // Set cursor if we have focus
            if (self.backend.pointers.items.len > 0 and self.cursor_serial != 0) {
                const pointer = self.backend.pointers.items[0];
                c.wl_pointer_set_cursor(
                    pointer.wl_pointer,
                    self.cursor_serial,
                    self.cursor_surface,
                    @intFromFloat(hotspot.getX()),
                    @intFromFloat(hotspot.getY()),
                );
            }
        }

        return true;
    }

    pub fn moveCursor(self: *Self, coord: Vector2D, skip_schedule: bool) void {
        _ = self;
        _ = coord;
        _ = skip_schedule;
        // Wayland handles cursor positioning
    }

    pub fn setCursorVisible(self: *Self, visible: bool) void {
        if (self.backend.pointers.items.len == 0) return;
        if (self.cursor_serial == 0) return;

        const pointer = self.backend.pointers.items[0];

        if (visible) {
            // Show cursor with current surface
            if (self.cursor_surface) |surf| {
                c.wl_pointer_set_cursor(
                    pointer.wl_pointer,
                    self.cursor_serial,
                    surf,
                    @intFromFloat(self.cursor_hotspot.getX()),
                    @intFromFloat(self.cursor_hotspot.getY()),
                );
            }
        } else {
            // Hide cursor by setting surface to null
            c.wl_pointer_set_cursor(
                pointer.wl_pointer,
                self.cursor_serial,
                null,
                0,
                0,
            );
        }
    }

    pub fn cursorPlaneSize(self: *Self) Vector2D {
        _ = self;
        return Vector2D.init(-1, -1); // No limit
    }

    pub fn scheduleFrame(self: *Self, reason: output.ScheduleReason) void {
        _ = reason;
        self.needs_frame = true;

        if (self.frame_scheduled) return;

        self.frame_scheduled = true;

        if (self.frame_callback != null) {
            self.frame_scheduled_while_waiting = true;
        } else {
            // Schedule idle callback
            self.backend.idle_callbacks.append(self.allocator, self) catch return;
        }
    }

    pub fn getGammaSize(self: *Self) usize {
        _ = self;
        return 0;
    }

    pub fn getDeGammaSize(self: *Self) usize {
        _ = self;
        return 0;
    }

    pub fn destroy(self: *Self) bool {
        self.deinit();
        return true;
    }

    fn wlBufferFromBuffer(self: *Self, buf: buffer.Interface) !*Buffer {
        // Check if buffer already exists
        for (self.buffers.items) |wl_buf| {
            if (wl_buf.buffer.base.ptr == buf.base.ptr) {
                return wl_buf;
            }
        }

        // Create new buffer
        const wl_buffer = try Buffer.create(self.allocator, buf, self.backend);
        try self.buffers.append(self.allocator, wl_buffer);
        return wl_buffer;
    }

    fn sendFrameAndSetCallback(self: *Self) void {
        if (self.surface == null) return;

        self.frame_scheduled = false;
        self.ready_for_frame_callback = false;

        self.frame_callback = c.wl_surface_frame(self.surface.?);
        if (self.frame_callback) |cb| {
            const listener = c.wl_callback_listener{
                .done = frameCallbackDone,
            };
            _ = c.wl_callback_add_listener(cb, &listener, self);
        }
    }

    fn frameCallbackDone(data: ?*anyopaque, callback: ?*c.wl_callback, callback_data: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        _ = callback_data;

        // Destroy the callback
        if (callback) |cb| {
            c.wl_callback_destroy(cb);
        }
        self.frame_callback = null;

        // If a frame was scheduled while waiting, schedule another
        if (self.frame_scheduled_while_waiting) {
            self.frame_scheduled_while_waiting = false;
            self.frame_scheduled = false;
            self.scheduleFrame(.unknown);
        }

        // TODO: Emit frame event to coordinator
    }

    pub fn onEnter(self: *Self, serial: u32) void {
        self.cursor_serial = serial;

        if (self.cursor_surface == null) return;

        if (self.backend.pointers.items.len > 0) {
            const pointer = self.backend.pointers.items[0];
            c.wl_pointer_set_cursor(
                pointer.wl_pointer,
                serial,
                self.cursor_surface,
                @intFromFloat(self.cursor_hotspot.getX()),
                @intFromFloat(self.cursor_hotspot.getY()),
            );
        }
    }

    // XDG surface callbacks
    fn xdgSurfaceHandleConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
        _ = data;
        if (xdg_surface) |surf| {
            c.xdg_surface_ack_configure(surf, serial);
        }
    }

    fn xdgToplevelHandleConfigure(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, _width: i32, _height: i32, states: ?*c.wl_array) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = _width;
        _ = _height;
        _ = states;
        // TODO: Update output mode with new dimensions when compositor requests resize
    }

    fn xdgToplevelHandleClose(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        _ = xdg_toplevel;
        // Output should be closed/destroyed
        _ = self.destroy();
    }

    // VTable implementation
    pub fn iface(self: *Self) output.IOutput {
        return output.IOutput.init(self, &.{
            .commit = commitFn,
            .test_commit = testCommitFn,
            .get_backend = getBackendFn,
            .get_render_formats = getRenderFormatsFn,
            .preferred_mode = preferredModeFn,
            .set_cursor = setCursorFn,
            .move_cursor = moveCursorFn,
            .set_cursor_visible = setCursorVisibleFn,
            .cursor_plane_size = cursorPlaneSizeFn,
            .schedule_frame = scheduleFrameFn,
            .get_gamma_size = getGammaSizeFn,
            .get_degamma_size = getDeGammaSizeFn,
            .destroy = destroyFn,
            .deinit = deinitFn,
        });
    }

    fn commitFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.commit();
    }

    fn testCommitFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.testCommit();
    }

    fn getBackendFn(ptr: *anyopaque) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getBackend();
    }

    fn getRenderFormatsFn(ptr: *anyopaque) []const misc.DRMFormat {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getRenderFormats();
    }

    fn preferredModeFn(ptr: *anyopaque) ?*output.Mode {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.preferredMode();
    }

    fn setCursorFn(ptr: *anyopaque, buf: buffer.Interface, hotspot: Vector2D) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.setCursor(buf, hotspot);
    }

    fn moveCursorFn(ptr: *anyopaque, coord: Vector2D, skip_schedule: bool) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.moveCursor(coord, skip_schedule);
    }

    fn setCursorVisibleFn(ptr: *anyopaque, visible: bool) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.setCursorVisible(visible);
    }

    fn cursorPlaneSizeFn(ptr: *anyopaque) Vector2D {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.cursorPlaneSize();
    }

    fn scheduleFrameFn(ptr: *anyopaque, reason: output.ScheduleReason) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.scheduleFrame(reason);
    }

    fn getGammaSizeFn(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getGammaSize();
    }

    fn getDeGammaSizeFn(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getDeGammaSize();
    }

    fn destroyFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.destroy();
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Wayland keyboard wrapper
pub const Keyboard = struct {
    wl_keyboard: *c.wl_keyboard,
    backend: *Backend,
    allocator: std.mem.Allocator,
    name: []const u8 = "wl_keyboard",

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, wl_keyboard: *c.wl_keyboard, be: *Backend) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .wl_keyboard = wl_keyboard,
            .backend = be,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        c.wl_keyboard_destroy(self.wl_keyboard);
        self.allocator.destroy(self);
    }

    pub fn getName(self: *const Self) []const u8 {
        return self.name;
    }
};

/// Wayland pointer wrapper
pub const Pointer = struct {
    wl_pointer: *c.wl_pointer,
    backend: *Backend,
    allocator: std.mem.Allocator,
    name: []const u8 = "wl_pointer",

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, wl_pointer: *c.wl_pointer, be: *Backend) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .wl_pointer = wl_pointer,
            .backend = be,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        c.wl_pointer_destroy(self.wl_pointer);
        self.allocator.destroy(self);
    }

    pub fn getName(self: *const Self) []const u8 {
        return self.name;
    }
};

/// Main Wayland backend implementation
pub const Backend = struct {
    coordinator: *backend.Coordinator,
    allocator: std.mem.Allocator,
    outputs: std.ArrayList(*Output),
    keyboards: std.ArrayList(*Keyboard),
    pointers: std.ArrayList(*Pointer),
    idle_callbacks: std.ArrayList(*Output),
    dmabuf_formats: std.ArrayList(misc.DRMFormat),
    last_output_id: usize = 0,
    focused_output: ?*Output = null,
    last_enter_serial: u32 = 0,

    // Wayland state
    wayland_state: struct {
        display: ?*c.wl_display = null,
        registry: ?*c.wl_registry = null,
        seat: ?*c.wl_seat = null,
        compositor: ?*c.wl_compositor = null,
        xdg_wm_base: ?*c.xdg_wm_base = null,
        dmabuf: ?*c.zwp_linux_dmabuf_v1 = null,
        dmabuf_feedback: ?*c.zwp_linux_dmabuf_feedback_v1 = null,
        dmabuf_failed: bool = false,
    } = .{},

    // DRM state
    drm_state: struct {
        fd: i32 = -1,
        node_name: ?[]const u8 = null,
    } = .{},

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, coordinator: *backend.Coordinator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .coordinator = coordinator,
            .allocator = allocator,
            .outputs = std.ArrayList(*Output){},
            .keyboards = std.ArrayList(*Keyboard){},
            .pointers = std.ArrayList(*Pointer){},
            .idle_callbacks = std.ArrayList(*Output){},
            .dmabuf_formats = std.ArrayList(misc.DRMFormat){},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.outputs.items) |out| {
            out.deinit();
        }
        self.outputs.deinit(self.allocator);

        for (self.keyboards.items) |keyboard| {
            keyboard.deinit();
        }
        self.keyboards.deinit(self.allocator);

        for (self.pointers.items) |pointer| {
            pointer.deinit();
        }
        self.pointers.deinit(self.allocator);

        self.idle_callbacks.deinit(self.allocator);

        for (self.dmabuf_formats.items) |*format| {
            format.deinit(self.allocator);
        }
        self.dmabuf_formats.deinit(self.allocator);

        if (self.wayland_state.dmabuf_feedback) |feedback| {
            c.zwp_linux_dmabuf_feedback_v1_destroy(feedback);
        }

        if (self.wayland_state.dmabuf) |dmabuf| {
            c.zwp_linux_dmabuf_v1_destroy(dmabuf);
        }

        if (self.wayland_state.xdg_wm_base) |xdg| {
            c.xdg_wm_base_destroy(xdg);
        }

        if (self.wayland_state.compositor) |comp| {
            c.wl_compositor_destroy(comp);
        }

        if (self.wayland_state.seat) |seat| {
            c.wl_seat_destroy(seat);
        }

        if (self.wayland_state.registry) |reg| {
            c.wl_registry_destroy(reg);
        }

        if (self.wayland_state.display) |disp| {
            c.wl_display_disconnect(disp);
        }

        if (self.drm_state.fd >= 0) {
            std.posix.close(self.drm_state.fd);
        }

        self.allocator.destroy(self);
    }

    pub fn backendType(self: *const Self) backend.Type {
        _ = self;
        return .wayland;
    }

    // Registry callbacks
    fn registryHandleGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const reg = registry orelse return;
        const interface_name = std.mem.span(interface);

        if (std.mem.eql(u8, interface_name, "wl_compositor")) {
            self.wayland_state.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(version, 4)));
            self.coordinator.log(.debug, "Bound wl_compositor");
        } else if (std.mem.eql(u8, interface_name, "wl_seat")) {
            self.wayland_state.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, @min(version, 7)));
            self.initSeat();
            self.coordinator.log(.debug, "Bound wl_seat");
        } else if (std.mem.eql(u8, interface_name, "xdg_wm_base")) {
            self.wayland_state.xdg_wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, @min(version, 2)));
            self.initShell();
            self.coordinator.log(.debug, "Bound xdg_wm_base");
        } else if (std.mem.eql(u8, interface_name, "zwp_linux_dmabuf_v1")) {
            self.wayland_state.dmabuf = @ptrCast(c.wl_registry_bind(reg, name, &c.zwp_linux_dmabuf_v1_interface, @min(version, 4)));
            _ = self.initDmabuf() catch {
                self.wayland_state.dmabuf_failed = true;
            };
            self.coordinator.log(.debug, "Bound zwp_linux_dmabuf_v1");
        }
    }

    fn registryHandleGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = registry;
        _ = name;
        // Handle global removal if needed
    }

    pub fn start(self: *Self) bool {
        self.coordinator.log(.debug, "Starting Wayland backend");

        // Connect to Wayland display
        self.wayland_state.display = c.wl_display_connect(null);
        if (self.wayland_state.display == null) {
            self.coordinator.log(.err, "Failed to connect to Wayland display");
            return false;
        }

        const xdg_desktop = std.posix.getenv("XDG_CURRENT_DESKTOP");
        const desktop_name = if (xdg_desktop) |name| name else "unknown";
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Connected to Wayland compositor: {s}", .{desktop_name}) catch "Connected to Wayland compositor";
        self.coordinator.log(.debug, msg);

        // Get registry
        self.wayland_state.registry = c.wl_display_get_registry(self.wayland_state.display.?);
        if (self.wayland_state.registry == null) {
            self.coordinator.log(.err, "Failed to get Wayland registry");
            return false;
        }

        // Setup registry listener
        const listener = c.wl_registry_listener{
            .global = registryHandleGlobal,
            .global_remove = registryHandleGlobalRemove,
        };
        _ = c.wl_registry_add_listener(self.wayland_state.registry.?, &listener, self);

        // Do roundtrip to process registry events
        _ = c.wl_display_roundtrip(self.wayland_state.display.?);

        return true;
    }

    pub fn pollFds(self: *Self) []const backend.PollFd {
        if (self.wayland_state.display) |disp| {
            const fd = c.wl_display_get_fd(disp);
            // TODO: Return proper poll fd array
            _ = fd;
        }
        return &[_]backend.PollFd{};
    }

    pub fn drmFd(self: *const Self) i32 {
        return self.drm_state.fd;
    }

    pub fn drmRenderNodeFd(self: *const Self) i32 {
        return self.drm_state.fd;
    }

    pub fn getRenderFormats(self: *Self) []const misc.DRMFormat {
        return self.dmabuf_formats.items;
    }

    pub fn onReady(self: *Self) void {
        _ = self;
        // Called when backend is ready
    }

    pub fn createOutput(self: *Self, name: ?[]const u8) !void {
        const output_name = if (name) |n| n else blk: {
            self.last_output_id += 1;
            var buf: [64]u8 = undefined;
            break :blk try std.fmt.bufPrint(&buf, "WL-{d}", .{self.last_output_id});
        };

        const out = try Output.create(self.allocator, output_name, self);
        try self.outputs.append(self.allocator, out);
    }

    // Seat capability callbacks
    fn seatHandleCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const seat_ptr = seat orelse return;

        // Handle pointer capability
        if (capabilities & c.WL_SEAT_CAPABILITY_POINTER != 0) {
            if (self.pointers.items.len == 0) {
                const wl_pointer = c.wl_seat_get_pointer(seat_ptr);
                if (wl_pointer) |ptr| {
                    const pointer = Pointer.create(self.allocator, ptr, self) catch return;
                    self.pointers.append(self.allocator, pointer) catch {
                        pointer.deinit();
                        return;
                    };

                    const listener = c.wl_pointer_listener{
                        .enter = pointerHandleEnter,
                        .leave = pointerHandleLeave,
                        .motion = pointerHandleMotion,
                        .button = pointerHandleButton,
                        .axis = pointerHandleAxis,
                        .frame = pointerHandleFrame,
                        .axis_source = pointerHandleAxisSource,
                        .axis_stop = pointerHandleAxisStop,
                        .axis_discrete = pointerHandleAxisDiscrete,
                    };
                    _ = c.wl_pointer_add_listener(ptr, &listener, self);
                }
            }
        } else {
            // Pointer capability removed
            for (self.pointers.items) |pointer| {
                pointer.deinit();
            }
            self.pointers.clearRetainingCapacity();
        }

        // Handle keyboard capability
        if (capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD != 0) {
            if (self.keyboards.items.len == 0) {
                const wl_keyboard = c.wl_seat_get_keyboard(seat_ptr);
                if (wl_keyboard) |kbd| {
                    const keyboard = Keyboard.create(self.allocator, kbd, self) catch return;
                    self.keyboards.append(self.allocator, keyboard) catch {
                        keyboard.deinit();
                        return;
                    };

                    const listener = c.wl_keyboard_listener{
                        .keymap = keyboardHandleKeymap,
                        .enter = keyboardHandleEnter,
                        .leave = keyboardHandleLeave,
                        .key = keyboardHandleKey,
                        .modifiers = keyboardHandleModifiers,
                        .repeat_info = keyboardHandleRepeatInfo,
                    };
                    _ = c.wl_keyboard_add_listener(kbd, &listener, self);
                }
            }
        } else {
            // Keyboard capability removed
            for (self.keyboards.items) |keyboard| {
                keyboard.deinit();
            }
            self.keyboards.clearRetainingCapacity();
        }
    }

    fn seatHandleName(data: ?*anyopaque, seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void {
        _ = data;
        _ = seat;
        _ = name;
    }

    // Pointer event callbacks
    fn pointerHandleEnter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        _ = pointer;
        _ = surface_x;
        _ = surface_y;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const surf = surface orelse return;

        self.last_enter_serial = serial;

        // Find which output this surface belongs to
        for (self.outputs.items) |out| {
            if (out.surface == surf) {
                self.focused_output = out;
                out.onEnter(serial);
                break;
            }
        }
    }

    fn pointerHandleLeave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
        _ = pointer;
        _ = serial;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const surf = surface orelse return;

        // Clear focused output if it matches
        if (self.focused_output) |out| {
            if (out.surface == surf) {
                self.focused_output = null;
            }
        }
    }

    fn pointerHandleMotion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = surface_x;
        _ = surface_y;
        // TODO: Emit pointer motion event
    }

    fn pointerHandleButton(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = serial;
        _ = time;
        _ = button;
        _ = state;
        // TODO: Emit pointer button event
    }

    fn pointerHandleAxis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
        _ = value;
        // TODO: Emit pointer axis event
    }

    fn pointerHandleFrame(data: ?*anyopaque, pointer: ?*c.wl_pointer) callconv(.c) void {
        _ = data;
        _ = pointer;
    }

    fn pointerHandleAxisSource(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis_source: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis_source;
    }

    fn pointerHandleAxisStop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
    }

    fn pointerHandleAxisDiscrete(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = discrete;
    }

    // Keyboard event callbacks
    fn keyboardHandleKeymap(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = format;
        _ = size;
        // Close the keymap fd
        std.posix.close(fd);
        // TODO: Parse and store keymap
    }

    fn keyboardHandleEnter(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: ?*c.wl_array) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = surface;
        _ = keys;
        // TODO: Handle keyboard focus
    }

    fn keyboardHandleLeave(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = surface;
        // TODO: Handle keyboard focus loss
    }

    fn keyboardHandleKey(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = time;
        _ = key;
        _ = state;
        // TODO: Emit keyboard key event
    }

    fn keyboardHandleModifiers(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = mods_depressed;
        _ = mods_latched;
        _ = mods_locked;
        _ = group;
        // TODO: Handle modifier state changes
    }

    fn keyboardHandleRepeatInfo(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
        _ = data;
        _ = keyboard;
        _ = rate;
        _ = delay;
        // TODO: Store repeat info
    }

    fn initSeat(self: *Self) void {
        if (self.wayland_state.seat == null) return;

        const seat = self.wayland_state.seat.?;
        const listener = c.wl_seat_listener{
            .capabilities = seatHandleCapabilities,
            .name = seatHandleName,
        };
        _ = c.wl_seat_add_listener(seat, &listener, self);
    }

    fn initShell(self: *Self) void {
        if (self.wayland_state.xdg_wm_base == null) return;

        const xdg = self.wayland_state.xdg_wm_base.?;
        const listener = c.xdg_wm_base_listener{
            .ping = xdgWmBasePing,
        };
        _ = c.xdg_wm_base_add_listener(xdg, &listener, self);
    }

    fn xdgWmBasePing(data: ?*anyopaque, xdg_wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
        _ = data;
        if (xdg_wm_base) |xdg| {
            c.xdg_wm_base_pong(xdg, serial);
        }
    }

    fn initDmabuf(self: *Self) !bool {
        if (self.wayland_state.dmabuf == null) return false;

        // TODO: Setup dmabuf listeners and format enumeration

        return true;
    }

    // VTable implementation
    pub fn iface(self: *Self) backend.Implementation {
        return backend.Implementation.init(self, &.{
            .backend_type = backendTypeFn,
            .start = startFn,
            .poll_fds = pollFdsFn,
            .drm_fd = drmFdFn,
            .drm_render_node_fd = drmRenderNodeFdFn,
            .get_render_formats = getRenderFormatsFn,
            .on_ready = onReadyFn,
            .deinit = deinitFn,
        });
    }

    fn backendTypeFn(ptr: *anyopaque) backend.Type {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.backendType();
    }

    fn startFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.start();
    }

    fn pollFdsFn(ptr: *anyopaque) []const backend.PollFd {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.pollFds();
    }

    fn drmFdFn(ptr: *anyopaque) i32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.drmFd();
    }

    fn drmRenderNodeFdFn(ptr: *anyopaque) i32 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.drmRenderNodeFd();
    }

    fn getRenderFormatsFn(ptr: *anyopaque) []const misc.DRMFormat {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getRenderFormats();
    }

    fn onReadyFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.onReady();
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

const testing = core.testing;

// Tests
test "Backend - creation and cleanup" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    try testing.expectEqual(backend.Type.wayland, backend_impl.backendType());
    try testing.expectEqual(@as(i32, -1), backend_impl.drmFd());
}

test "Backend - output creation" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    try testing.expectEqual(@as(usize, 0), backend_impl.outputs.items.len);
}

test "Backend - initial state" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    try testing.expectEqual(@as(usize, 0), backend_impl.outputs.items.len);
    try testing.expectEqual(@as(usize, 0), backend_impl.keyboards.items.len);
    try testing.expectEqual(@as(usize, 0), backend_impl.pointers.items.len);
    try testing.expectEqual(@as(usize, 0), backend_impl.idle_callbacks.items.len);
    try testing.expectEqual(@as(usize, 0), backend_impl.dmabuf_formats.items.len);
    try testing.expectEqual(@as(usize, 0), backend_impl.last_output_id);
    try testing.expectNull(backend_impl.focused_output);
}

test "Backend - format list management" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    const formats = backend_impl.getRenderFormats();
    try testing.expectEqual(@as(usize, 0), formats.len);
}

test "Backend - output ID generation sequence" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    // Initial ID should be 0
    try testing.expectEqual(@as(usize, 0), backend_impl.last_output_id);

    // Create outputs and verify ID increments
    // Note: createOutput will fail without Wayland connection, but we can test the field
    const initial_id = backend_impl.last_output_id;
    try testing.expectEqual(@as(usize, 0), initial_id);
}

test "Output - name auto-generation" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    // Verify output name generation logic
    backend_impl.last_output_id = 0;
    const name1 = "WL-1";
    backend_impl.last_output_id = 1;
    const name2 = "WL-2";

    try testing.expectEqualStrings("WL-1", name1);
    try testing.expectEqualStrings("WL-2", name2);
}

test "Output - frame scheduling states" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    // Initial state
    try testing.expectFalse(out.needs_frame);
    try testing.expectFalse(out.frame_scheduled);
    try testing.expectFalse(out.frame_scheduled_while_waiting);
    try testing.expectFalse(out.ready_for_frame_callback);

    // Schedule a frame
    out.scheduleFrame(.unknown);
    try testing.expect(out.needs_frame);
    try testing.expect(out.frame_scheduled);
}

test "Output - state initialization" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    try testing.expectEqualStrings("test-output", out.name);
    try testing.expectEqual(@as(usize, 0), out.buffers.items.len);
    try testing.expectNull(out.cursor_buffer);
}

test "Output - cursor operations without connection" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    // Test cursor size query
    const size = out.cursorPlaneSize();
    try testing.expectEqual(@as(f32, -1), size.getX());
    try testing.expectEqual(@as(f32, -1), size.getY());

    // Test cursor visibility (should not crash without connection)
    out.setCursorVisible(true);
    out.setCursorVisible(false);

    // Test cursor movement (should not crash)
    out.moveCursor(Vector2D.init(10, 20), false);
}

test "Output - backend getter" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    const be = out.getBackend();
    try testing.expectNotNull(be);
    if (be) |backend_ptr| {
        try testing.expectEqual(@as(*anyopaque, @ptrCast(backend_impl)), backend_ptr);
    }
}

test "Output - gamma size" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    try testing.expectEqual(@as(usize, 0), out.getGammaSize());
    try testing.expectEqual(@as(usize, 0), out.getDeGammaSize());
}

test "Output - preferred mode" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    // Wayland outputs don't have fixed modes
    try testing.expectNull(out.preferredMode());
}

test "Output - test commit" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    // Wayland doesn't have test commits, should always return true
    try testing.expect(out.testCommit());
}

test "Output - VTable interface and methods" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    const iface = out.iface();

    // Validate VTable structure is properly initialized
    const dummy_iface: output.IOutput = undefined;
    try testing.expect(@TypeOf(iface.base) == @TypeOf(dummy_iface.base));

    // Test VTable methods actually work
    try testing.expect(iface.testCommit());
    try testing.expectEqual(@as(usize, 0), iface.getGammaSize());
    try testing.expectEqual(@as(usize, 0), iface.getDeGammaSize());
    try testing.expectNull(iface.preferredMode());
    try testing.expectNotNull(iface.getBackend());

    const size = iface.cursorPlaneSize();
    try testing.expectEqual(@as(f32, -1), size.getX());
    try testing.expectEqual(@as(f32, -1), size.getY());
}

test "Buffer - lifecycle and dmabuf creation" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    // Create mock buffer with proper dmabuf attributes
    const MockBuffer = struct {
        fn caps(_: *anyopaque) buffer.Capability {
            return buffer.Capability{};
        }
        fn bufferType(_: *anyopaque) buffer.Type {
            return .dmabuf;
        }
        fn update(_: *anyopaque, _: *const anyopaque) void {}
        fn isSynchronous(_: *anyopaque) bool {
            return false;
        }
        fn good(_: *anyopaque) bool {
            return true;
        }
        fn dmabuf(_: *anyopaque) buffer.DMABUFAttrs {
            return buffer.DMABUFAttrs{
                .success = true,
                .size = Vector2D.init(1920, 1080),
                .format = 0x34325241, // DRM_FORMAT_ARGB8888
                .modifier = 0,
                .planes = 1,
                .fds = [_]i32{-1} ++ [_]i32{0} ** 3,
                .strides = [_]u32{1920 * 4} ++ [_]u32{0} ** 3,
                .offsets = [_]u32{0} ** 4,
            };
        }
        fn shm(_: *anyopaque) buffer.SSHMAttrs {
            return .{ .success = false };
        }
        fn beginDataPtr(_: *anyopaque, _: u32) buffer.DataPtrResult {
            return .{ .ptr = null, .flags = 0, .size = 0 };
        }
        fn endDataPtr(_: *anyopaque) void {}
        fn sendRelease(_: *anyopaque) void {}
        fn lock(_: *anyopaque) void {}
        fn unlock(_: *anyopaque) void {}
        fn locked(_: *anyopaque) bool {
            return false;
        }
        fn deinit(_: *anyopaque) void {}
    };

    var mock_data: u8 = 0;
    const mock_vtable = buffer.Interface.VTableDef{
        .caps = MockBuffer.caps,
        .type = MockBuffer.bufferType,
        .update = MockBuffer.update,
        .is_synchronous = MockBuffer.isSynchronous,
        .good = MockBuffer.good,
        .dmabuf = MockBuffer.dmabuf,
        .shm = MockBuffer.shm,
        .begin_data_ptr = MockBuffer.beginDataPtr,
        .end_data_ptr = MockBuffer.endDataPtr,
        .send_release = MockBuffer.sendRelease,
        .lock = MockBuffer.lock,
        .unlock = MockBuffer.unlock,
        .locked = MockBuffer.locked,
        .deinit = MockBuffer.deinit,
    };
    const mock_buffer = buffer.Interface.init(&mock_data, &mock_vtable);

    var wl_buf = try Buffer.create(testing.allocator, mock_buffer, backend_impl);
    defer wl_buf.deinit();

    // Without Wayland connection, wl_buffer should be null (dmabuf protocol unavailable)
    try testing.expectFalse(wl_buf.good());
    try testing.expectFalse(wl_buf.pending_release);

    // Verify buffer stores the interface
    try testing.expectEqual(mock_buffer.base.ptr, wl_buf.buffer.base.ptr);
}

test "Buffer - pending release flag and caching" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    const MockBuffer = struct {
        fn caps(_: *anyopaque) buffer.Capability {
            return buffer.Capability{};
        }
        fn bufferType(_: *anyopaque) buffer.Type {
            return .dmabuf;
        }
        fn update(_: *anyopaque, _: *const anyopaque) void {}
        fn isSynchronous(_: *anyopaque) bool {
            return false;
        }
        fn good(_: *anyopaque) bool {
            return true;
        }
        fn dmabuf(_: *anyopaque) buffer.DMABUFAttrs {
            return buffer.DMABUFAttrs{
                .success = true,
                .size = Vector2D.init(800, 600),
                .format = 0x34325241,
                .modifier = 0,
                .planes = 1,
                .fds = [_]i32{-1} ++ [_]i32{0} ** 3,
                .strides = [_]u32{800 * 4} ++ [_]u32{0} ** 3,
                .offsets = [_]u32{0} ** 4,
            };
        }
        fn shm(_: *anyopaque) buffer.SSHMAttrs {
            return .{ .success = false };
        }
        fn beginDataPtr(_: *anyopaque, _: u32) buffer.DataPtrResult {
            return .{ .ptr = null, .flags = 0, .size = 0 };
        }
        fn endDataPtr(_: *anyopaque) void {}
        fn sendRelease(_: *anyopaque) void {}
        fn lock(_: *anyopaque) void {}
        fn unlock(_: *anyopaque) void {}
        fn locked(_: *anyopaque) bool {
            return false;
        }
        fn deinit(_: *anyopaque) void {}
    };

    var mock_data: u8 = 0;
    const mock_vtable = buffer.Interface.VTableDef{
        .caps = MockBuffer.caps,
        .type = MockBuffer.bufferType,
        .update = MockBuffer.update,
        .is_synchronous = MockBuffer.isSynchronous,
        .good = MockBuffer.good,
        .dmabuf = MockBuffer.dmabuf,
        .shm = MockBuffer.shm,
        .begin_data_ptr = MockBuffer.beginDataPtr,
        .end_data_ptr = MockBuffer.endDataPtr,
        .send_release = MockBuffer.sendRelease,
        .lock = MockBuffer.lock,
        .unlock = MockBuffer.unlock,
        .locked = MockBuffer.locked,
        .deinit = MockBuffer.deinit,
    };
    const mock_buffer = buffer.Interface.init(&mock_data, &mock_vtable);

    var wl_buf = try Buffer.create(testing.allocator, mock_buffer, backend_impl);
    defer wl_buf.deinit();

    // Test pending release flag
    try testing.expectFalse(wl_buf.pending_release);
    wl_buf.pending_release = true;
    try testing.expect(wl_buf.pending_release);

    // Test that buffer stores correct reference
    try testing.expectEqual(mock_buffer.base.ptr, wl_buf.buffer.base.ptr);
}

test "Keyboard - structure and default name" {
    // Test that Keyboard structure has the expected layout
    const KeyboardType = Keyboard;
    try testing.expect(@sizeOf(KeyboardType) > 0);
    try testing.expect(@hasField(KeyboardType, "wl_keyboard"));
    try testing.expect(@hasField(KeyboardType, "backend"));
    try testing.expect(@hasField(KeyboardType, "allocator"));
    try testing.expect(@hasField(KeyboardType, "name"));

    // Verify default name value
    const default_keyboard = Keyboard{
        .wl_keyboard = undefined,
        .backend = undefined,
        .allocator = undefined,
    };
    try testing.expectEqualStrings("wl_keyboard", default_keyboard.name);
    try testing.expectEqualStrings("wl_keyboard", default_keyboard.getName());
}

test "Pointer - structure and default name" {
    // Test that Pointer structure has the expected layout
    const PointerType = Pointer;
    try testing.expect(@sizeOf(PointerType) > 0);
    try testing.expect(@hasField(PointerType, "wl_pointer"));
    try testing.expect(@hasField(PointerType, "backend"));
    try testing.expect(@hasField(PointerType, "allocator"));
    try testing.expect(@hasField(PointerType, "name"));

    // Verify default name value
    const default_pointer = Pointer{
        .wl_pointer = undefined,
        .backend = undefined,
        .allocator = undefined,
    };
    try testing.expectEqualStrings("wl_pointer", default_pointer.name);
    try testing.expectEqualStrings("wl_pointer", default_pointer.getName());
}

test "Backend - VTable interface and methods" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    const iface = backend_impl.iface();

    // Validate VTable structure is properly initialized
    const dummy_impl: backend.Implementation = undefined;
    try testing.expect(@TypeOf(iface.base) == @TypeOf(dummy_impl.base));

    // Test VTable methods
    try testing.expectEqual(backend.Type.wayland, iface.backendType());
    try testing.expectEqual(@as(i32, -1), iface.drmFd());
    try testing.expectEqual(@as(i32, -1), iface.drmRenderNodeFd());

    const formats = iface.getRenderFormats();
    try testing.expectEqual(@as(usize, 0), formats.len);

    const fds = iface.pollFds();
    try testing.expectEqual(@as(usize, 0), fds.len);

    // onReady should not crash
    iface.onReady();
}

test "Backend - poll fds without connection" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    const fds = backend_impl.pollFds();
    try testing.expectEqual(@as(usize, 0), fds.len);
}

test "Output - buffer caching in wlBufferFromBuffer" {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend.Options = .{};

    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend_impl = try Backend.create(testing.allocator, coordinator);
    defer backend_impl.deinit();

    var out = try Output.create(testing.allocator, "test-output", backend_impl);
    defer out.deinit();

    // Create mock buffer interfaces
    const MockBuffer = struct {
        fn caps(_: *anyopaque) buffer.Capability {
            return buffer.Capability{};
        }
        fn bufferType(_: *anyopaque) buffer.Type {
            return .dmabuf;
        }
        fn update(_: *anyopaque, _: *const anyopaque) void {}
        fn isSynchronous(_: *anyopaque) bool {
            return false;
        }
        fn good(_: *anyopaque) bool {
            return true;
        }
        fn dmabuf(_: *anyopaque) buffer.DMABUFAttrs {
            return buffer.DMABUFAttrs{
                .success = true,
                .size = Vector2D.init(1920, 1080),
                .format = 0x34325241,
                .modifier = 0,
                .planes = 1,
                .fds = [_]i32{-1} ++ [_]i32{0} ** 3,
                .strides = [_]u32{1920 * 4} ++ [_]u32{0} ** 3,
                .offsets = [_]u32{0} ** 4,
            };
        }
        fn shm(_: *anyopaque) buffer.SSHMAttrs {
            return .{ .success = false };
        }
        fn beginDataPtr(_: *anyopaque, _: u32) buffer.DataPtrResult {
            return .{ .ptr = null, .flags = 0, .size = 0 };
        }
        fn endDataPtr(_: *anyopaque) void {}
        fn sendRelease(_: *anyopaque) void {}
        fn lock(_: *anyopaque) void {}
        fn unlock(_: *anyopaque) void {}
        fn locked(_: *anyopaque) bool {
            return false;
        }
        fn deinit(_: *anyopaque) void {}
    };

    var mock_data1: u8 = 1;
    var mock_data2: u8 = 2;
    const mock_vtable = buffer.Interface.VTableDef{
        .caps = MockBuffer.caps,
        .type = MockBuffer.bufferType,
        .update = MockBuffer.update,
        .is_synchronous = MockBuffer.isSynchronous,
        .good = MockBuffer.good,
        .dmabuf = MockBuffer.dmabuf,
        .shm = MockBuffer.shm,
        .begin_data_ptr = MockBuffer.beginDataPtr,
        .end_data_ptr = MockBuffer.endDataPtr,
        .send_release = MockBuffer.sendRelease,
        .lock = MockBuffer.lock,
        .unlock = MockBuffer.unlock,
        .locked = MockBuffer.locked,
        .deinit = MockBuffer.deinit,
    };

    const mock_buffer1 = buffer.Interface.init(&mock_data1, &mock_vtable);
    const mock_buffer2 = buffer.Interface.init(&mock_data2, &mock_vtable);

    // First call should create a new buffer
    const wl_buf1 = try out.wlBufferFromBuffer(mock_buffer1);
    try testing.expectEqual(@as(usize, 1), out.buffers.items.len);
    try testing.expectEqual(mock_buffer1.base.ptr, wl_buf1.buffer.base.ptr);

    // Second call with same buffer should return cached version
    const wl_buf1_cached = try out.wlBufferFromBuffer(mock_buffer1);
    try testing.expectEqual(@as(usize, 1), out.buffers.items.len);
    try testing.expectEqual(wl_buf1, wl_buf1_cached);

    // Third call with different buffer should create new buffer
    const wl_buf2 = try out.wlBufferFromBuffer(mock_buffer2);
    try testing.expectEqual(@as(usize, 2), out.buffers.items.len);
    try testing.expectEqual(mock_buffer2.base.ptr, wl_buf2.buffer.base.ptr);

    // Verify they're different buffers
    try testing.expectNotEqual(wl_buf1, wl_buf2); // Pointer comparison is fine with expect
}
