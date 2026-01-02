//! Wayland backend implementation inspired by aquamarine
//! Provides compositor-hosted backend using Wayland protocol

const std = @import("std");
const backend_mod = @import("backend.zig");
const output_mod = @import("output.zig");
const input_mod = @import("input.zig");
const buffer_mod = @import("buffer.zig");
const misc = @import("misc.zig");
const math = @import("core.math");
const Vector2D = math.Vector2D;

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
    buffer: buffer_mod.IBuffer,
    backend: *Backend,
    pending_release: bool = false,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, buf: buffer_mod.IBuffer, backend: *Backend) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .buffer = buf,
            .backend = backend,
            .allocator = allocator,
        };

        // Create wl_buffer from dmabuf
        if (backend.wayland_state.dmabuf) |dmabuf| {
            const params = c.zwp_linux_dmabuf_v1_create_params(dmabuf);
            if (params == null) {
                return error.FailedToCreateDmabufParams;
            }

            const attrs = buf.dmabuf();
            for (0..attrs.planes) |i| {
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
                @intFromFloat(attrs.size.x),
                @intFromFloat(attrs.size.y),
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
    state: output_mod.State,
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
    cursor_buffer: ?buffer_mod.IBuffer = null,
    cursor_surface: ?*c.wl_surface = null,
    cursor_wl_buffer: ?*c.wl_buffer = null,
    cursor_serial: u32 = 0,
    cursor_hotspot: Vector2D = .{},

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, name: []const u8, backend: *Backend) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        self.* = .{
            .name = name_copy,
            .backend = backend,
            .allocator = allocator,
            .state = output_mod.State.init(allocator),
            .buffers = std.ArrayList(*Buffer){},
        };

        // Create Wayland surface
        if (backend.wayland_state.compositor) |compositor| {
            self.surface = c.wl_compositor_create_surface(compositor);
            if (self.surface == null) {
                return error.FailedToCreateSurface;
            }
        }

        // Create XDG surface
        if (backend.wayland_state.xdg_wm_base) |xdg| {
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
        if (backend.wayland_state.compositor) |compositor| {
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

    pub fn preferredMode(self: *Self) ?*output_mod.Mode {
        _ = self;
        return null; // Wayland outputs don't have fixed modes
    }

    pub fn setCursor(self: *Self, buffer: buffer_mod.IBuffer, hotspot: Vector2D) bool {
        self.cursor_buffer = buffer;
        self.cursor_hotspot = hotspot;

        if (self.cursor_surface == null) return false;

        const attrs = buffer.dmabuf();

        // Create cursor wl_buffer
        if (self.backend.wayland_state.dmabuf) |dmabuf| {
            const params = c.zwp_linux_dmabuf_v1_create_params(dmabuf);
            if (params == null) return false;

            for (0..attrs.planes) |i| {
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
                @intFromFloat(attrs.size.x),
                @intFromFloat(attrs.size.y),
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
                    @intFromFloat(hotspot.x),
                    @intFromFloat(hotspot.y),
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
                    @intFromFloat(self.cursor_hotspot.x),
                    @intFromFloat(self.cursor_hotspot.y),
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

    pub fn scheduleFrame(self: *Self, reason: output_mod.ScheduleReason) void {
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

    fn wlBufferFromBuffer(self: *Self, buf: buffer_mod.IBuffer) !*Buffer {
        // Check if buffer already exists
        for (self.buffers.items) |wl_buf| {
            if (wl_buf.buffer.ptr == buf.ptr) {
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

    fn frameCallbackDone(data: ?*anyopaque, callback: ?*c.wl_callback, callback_data: u32) callconv(.C) void {
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
                @intFromFloat(self.cursor_hotspot.x),
                @intFromFloat(self.cursor_hotspot.y),
            );
        }
    }

    // XDG surface callbacks
    fn xdgSurfaceHandleConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.C) void {
        _ = data;
        if (xdg_surface) |surf| {
            c.xdg_surface_ack_configure(surf, serial);
        }
    }

    fn xdgToplevelHandleConfigure(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel, _width: i32, _height: i32, states: ?*c.wl_array) callconv(.C) void {
        _ = data;
        _ = xdg_toplevel;
        _ = _width;
        _ = _height;
        _ = states;
        // TODO: Update output mode with new dimensions when compositor requests resize
    }

    fn xdgToplevelHandleClose(data: ?*anyopaque, xdg_toplevel: ?*c.xdg_toplevel) callconv(.C) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        _ = xdg_toplevel;
        // Output should be closed/destroyed
        _ = self.destroy();
    }

    // VTable implementation
    pub fn iface(self: *Self) output_mod.IOutput {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
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
            },
        };
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

    fn preferredModeFn(ptr: *anyopaque) ?*output_mod.Mode {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.preferredMode();
    }

    fn setCursorFn(ptr: *anyopaque, buffer: buffer_mod.IBuffer, hotspot: Vector2D) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.setCursor(buffer, hotspot);
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

    fn scheduleFrameFn(ptr: *anyopaque, reason: output_mod.ScheduleReason) void {
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

    pub fn create(allocator: std.mem.Allocator, wl_keyboard: *c.wl_keyboard, backend: *Backend) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .wl_keyboard = wl_keyboard,
            .backend = backend,
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

    pub fn create(allocator: std.mem.Allocator, wl_pointer: *c.wl_pointer, backend: *Backend) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .wl_pointer = wl_pointer,
            .backend = backend,
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
    coordinator: *backend_mod.Coordinator,
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

    pub fn create(allocator: std.mem.Allocator, coordinator: *backend_mod.Coordinator) !*Self {
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
        for (self.outputs.items) |output| {
            output.deinit();
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

    pub fn backendType(self: *const Self) backend_mod.Type {
        _ = self;
        return .wayland;
    }

    // Registry callbacks
    fn registryHandleGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.C) void {
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

    fn registryHandleGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.C) void {
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

    pub fn pollFds(self: *Self) []const backend_mod.PollFd {
        if (self.wayland_state.display) |disp| {
            const fd = c.wl_display_get_fd(disp);
            // TODO: Return proper poll fd array
            _ = fd;
        }
        return &[_]backend_mod.PollFd{};
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

        const output = try Output.create(self.allocator, output_name, self);
        try self.outputs.append(self.allocator, output);
    }

    // Seat capability callbacks
    fn seatHandleCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.C) void {
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

    fn seatHandleName(data: ?*anyopaque, seat: ?*c.wl_seat, name: [*c]const u8) callconv(.C) void {
        _ = data;
        _ = seat;
        _ = name;
    }

    // Pointer event callbacks
    fn pointerHandleEnter(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.C) void {
        _ = pointer;
        _ = surface_x;
        _ = surface_y;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const surf = surface orelse return;

        self.last_enter_serial = serial;

        // Find which output this surface belongs to
        for (self.outputs.items) |output| {
            if (output.surface == surf) {
                self.focused_output = output;
                output.onEnter(serial);
                break;
            }
        }
    }

    fn pointerHandleLeave(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, surface: ?*c.wl_surface) callconv(.C) void {
        _ = pointer;
        _ = serial;
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const surf = surface orelse return;

        // Clear focused output if it matches
        if (self.focused_output) |output| {
            if (output.surface == surf) {
                self.focused_output = null;
            }
        }
    }

    fn pointerHandleMotion(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.C) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = surface_x;
        _ = surface_y;
        // TODO: Emit pointer motion event
    }

    fn pointerHandleButton(data: ?*anyopaque, pointer: ?*c.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.C) void {
        _ = data;
        _ = pointer;
        _ = serial;
        _ = time;
        _ = button;
        _ = state;
        // TODO: Emit pointer button event
    }

    fn pointerHandleAxis(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.C) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
        _ = value;
        // TODO: Emit pointer axis event
    }

    fn pointerHandleFrame(data: ?*anyopaque, pointer: ?*c.wl_pointer) callconv(.C) void {
        _ = data;
        _ = pointer;
    }

    fn pointerHandleAxisSource(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis_source: u32) callconv(.C) void {
        _ = data;
        _ = pointer;
        _ = axis_source;
    }

    fn pointerHandleAxisStop(data: ?*anyopaque, pointer: ?*c.wl_pointer, time: u32, axis: u32) callconv(.C) void {
        _ = data;
        _ = pointer;
        _ = time;
        _ = axis;
    }

    fn pointerHandleAxisDiscrete(data: ?*anyopaque, pointer: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.C) void {
        _ = data;
        _ = pointer;
        _ = axis;
        _ = discrete;
    }

    // Keyboard event callbacks
    fn keyboardHandleKeymap(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.C) void {
        _ = data;
        _ = keyboard;
        _ = format;
        _ = size;
        // Close the keymap fd
        std.posix.close(fd);
        // TODO: Parse and store keymap
    }

    fn keyboardHandleEnter(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: ?*c.wl_array) callconv(.C) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = surface;
        _ = keys;
        // TODO: Handle keyboard focus
    }

    fn keyboardHandleLeave(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.C) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = surface;
        // TODO: Handle keyboard focus loss
    }

    fn keyboardHandleKey(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.C) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = time;
        _ = key;
        _ = state;
        // TODO: Emit keyboard key event
    }

    fn keyboardHandleModifiers(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.C) void {
        _ = data;
        _ = keyboard;
        _ = serial;
        _ = mods_depressed;
        _ = mods_latched;
        _ = mods_locked;
        _ = group;
        // TODO: Handle modifier state changes
    }

    fn keyboardHandleRepeatInfo(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.C) void {
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

    fn xdgWmBasePing(data: ?*anyopaque, xdg_wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.C) void {
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
    pub fn iface(self: *Self) backend_mod.IBackendImplementation {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .backend_type = backendTypeFn,
                .start = startFn,
                .poll_fds = pollFdsFn,
                .drm_fd = drmFdFn,
                .drm_render_node_fd = drmRenderNodeFdFn,
                .get_render_formats = getRenderFormatsFn,
                .on_ready = onReadyFn,
                .deinit = deinitFn,
            },
        };
    }

    fn backendTypeFn(ptr: *anyopaque) backend_mod.Type {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.backendType();
    }

    fn startFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.start();
    }

    fn pollFdsFn(ptr: *anyopaque) []const backend_mod.PollFd {
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

// Tests
test "Backend - creation and cleanup" {
    const testing = std.testing;

    const backends = [_]backend_mod.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend_mod.Options = .{};

    var coordinator = try backend_mod.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend = try Backend.create(testing.allocator, coordinator);
    defer backend.deinit();

    try testing.expectEqual(backend_mod.Type.wayland, backend.backendType());
    try testing.expectEqual(@as(i32, -1), backend.drmFd());
}

test "Backend - output creation" {
    const testing = std.testing;

    const backends = [_]backend_mod.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    const opts: backend_mod.Options = .{};

    var coordinator = try backend_mod.Coordinator.create(testing.allocator, &backends, opts);
    defer coordinator.deinit();

    var backend = try Backend.create(testing.allocator, coordinator);
    defer backend.deinit();

    try testing.expectEqual(@as(usize, 0), backend.outputs.items.len);
}
