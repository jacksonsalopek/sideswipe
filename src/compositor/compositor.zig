//! Main compositor state and management
//! Coordinates surfaces, backends, and protocol implementations

const std = @import("std");
const string = @import("core.string").string;
const wayland = @import("wayland");
const backend = @import("backend");
const core = @import("core");
const cli = @import("core.cli");

const Surface = @import("surface.zig").Surface;
const Output = @import("output.zig").Type;
const seat_mod = @import("input/seat.zig");
const Seat = seat_mod.Type;
const gesture = @import("input/gesture.zig");
const ring_geometry = @import("ring_geometry.zig");
const strip = @import("layout/strip.zig");
const sheet = @import("layout/sheet.zig");
const overrides = @import("layout/overrides.zig");
const anim = @import("layout/anim.zig");
const linux_dmabuf = @import("protocols/linux_dmabuf.zig");
const sideswipe_shell = @import("protocols/sideswipe_shell.zig");
const lock = @import("lock.zig");
const log_overlay = @import("log_overlay.zig");

extern "c" fn fork() c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

/// Main compositor state
pub const Compositor = struct {
    allocator: std.mem.Allocator,
    server: *wayland.Server,
    coordinator: ?*backend.Coordinator,
    surfaces: std.ArrayList(*Surface),
    outputs: std.ArrayList(*Output),
    next_surface_id: u32,
    logger: *cli.Logger,
    seat: Seat,
    activation_tokens: std.AutoHashMap(u64, void),
    session_input_listener: ?core.events.Listener = null,
    session_device_change_listener: ?core.events.Listener = null,
    session_seat_disable_listener: ?core.events.Listener = null,
    session_seat_enable_listener: ?core.events.Listener = null,
    session_event_sources: std.ArrayList(*wayland.c.wl_event_source) = .empty,
    runtime_event_userdata: ?*anyopaque = null,
    runtime_event_handler: ?*const fn (?*anyopaque, backend.input.Event) void = null,
    side_button_devices: usize = 0,
    extra_button_devices: usize = 0,
    next_activation_token: u64 = 1,
    toplevels: std.ArrayList(Toplevel) = .empty,
    focused_column: ?usize = null,
    /// Last focused column surface, kept across a dialog mapping as a column.
    sheet_host: ?*Surface = null,
    viewport_x: f64 = 0,
    drag_direction: ?gesture.Direction = null,
    drag_progress: f64 = 0,
    fallback_ring: ?FallbackRing = null,
    pointer_constraints_suspended: bool = false,
    relative_pointer_suspended: bool = false,
    input_suspension_userdata: ?*anyopaque = null,
    input_suspension_handler: ?*const fn (?*anyopaque, bool, bool) void = null,
    destroying_clients: bool = false,
    output_binds: std.ArrayList(*wayland.c.wl_resource) = .empty,
    window_rules: overrides.Table,
    last_frame_ns: u64 = 0,
    shell: ?*sideswipe_shell.Host = null,
    session_lock: lock.Machine = .{},
    next_image_description: u32 = 0,
    onscreen_log: bool = false,
    painting_log: bool = false,
    log_overlay: ?*log_overlay.Overlay = null,

    pub const FallbackAction = enum {
        launch_terminal,
        next_column,
        close,
        previous_column,
    };

    pub const FallbackRing = struct {
        center: ring_geometry.Point,
        target_surface: ?*Surface,
        output: ?*Output,
        hover: ?u8 = null,
        focus_visible: bool = false,
    };

    pub const ToplevelHints = struct {
        parent: ?*Surface = null,
        is_dialog: bool = false,
        modal: bool = false,
        app_id: ?string = null,
        title: ?string = null,
        min_size: strip.Size = .{ .width = 0, .height = 0 },
        max_size: strip.Size = .{ .width = 0, .height = 0 },
        window_geometry: ?strip.Geometry = null,
        maximized: bool = false,
        fullscreen: bool = false,
    };

    pub const Toplevel = struct {
        surface: *Surface,
        context: *anyopaque,
        configure: *const fn (*anyopaque, i32, i32, u32) void,
        x: i32 = 0,
        y: i32 = 0,
        width: i32 = 0,
        height: i32 = 0,
        kind: sheet.Kind = .column,
        parent: ?*Surface = null,
        is_dialog: bool = false,
        modal: bool = false,
        app_id: ?string = null,
        title: ?string = null,
        min_size: strip.Size = .{ .width = 0, .height = 0 },
        max_size: strip.Size = .{ .width = 0, .height = 0 },
        window_geometry: ?strip.Geometry = null,
        maximized: bool = false,
        fullscreen: bool = false,
        column_width: strip.Width = .full,
        ssd: bool = false,
        ssd_override: ?bool = null,
        handle: ?strip.Geometry = null,
        motion: anim.State = .{},
        target: strip.Geometry = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        needs_configure: bool = true,
        closing: bool = false,
    };

    const Self = @This();

    pub const Error = error{
        InitFailed,
        OutOfMemory,
        BackendError,
        CreateFailed,
        XkbContextFailed,
        XkbKeymapFailed,
        XkbStateFailed,
        XkbSerializeFailed,
        EventLoopUnavailable,
        GestureTimerFailed,
    };

    /// Creates a new compositor instance
    pub fn init(allocator: std.mem.Allocator, server: *wayland.Server, logger: *cli.Logger) Error!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var seat = try Seat.init(allocator, server.getDisplay());
        errdefer seat.deinit();

        self.* = .{
            .allocator = allocator,
            .server = server,
            .coordinator = null,
            .surfaces = std.ArrayList(*Surface).empty,
            .outputs = std.ArrayList(*Output).empty,
            .next_surface_id = 1,
            .logger = logger,
            .seat = seat,
            .activation_tokens = std.AutoHashMap(u64, void).init(allocator),
            .window_rules = overrides.load(allocator),
        };
        try self.seat.attachGestureTimer();
        self.seat.setGestureHandler(self, gestureInput);
        self.seat.setFocusSyncHandler(self, focusInput);
        self.seat.setConstraintControl(.{
            .userdata = self,
            .pause = pauseConstrainedInput,
            .restore = restoreConstrainedInput,
        });

        return self;
    }

    /// Destroys connected clients while compositor callback state is alive.
    pub fn destroyClients(self: *Self) void {
        const clients = wayland.c.wl_display_get_client_list(self.server.getDisplay());
        if (wayland.c.wl_list_empty(clients) != 0) return;
        self.destroying_clients = true;
        defer self.destroying_clients = false;
        wayland.c.wl_display_destroy_clients(self.server.getDisplay());
    }

    /// Destroys the compositor and frees all resources
    pub fn deinit(self: *Self) void {
        if (self.shell) |host| host.deinit();
        self.disableOnscreenLog();
        self.detachSessionListeners();
        self.session_event_sources.deinit(self.allocator);
        self.seat.deinit();
        self.activation_tokens.deinit();
        self.window_rules.deinit();
        self.toplevels.deinit(self.allocator);
        self.output_binds.deinit(self.allocator);

        // Surface teardown may schedule repaint while destroying roles.
        for (self.surfaces.items) |surface| {
            surface.deinit();
        }
        self.surfaces.deinit(self.allocator);

        self.neutralizeBackendCallbacks();
        for (self.outputs.items) |output| {
            output.deinit();
        }
        self.outputs.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Attaches a backend coordinator to the compositor
    pub fn attachBackend(self: *Self, coord: *backend.Coordinator) Error!void {
        self.coordinator = coord;
        errdefer self.detachBackend();
        try self.attachSessionInput(coord);
        for (coord.implementations.items) |impl| {
            try self.connectBackendOutputs(impl);
        }
        if (hasLiveDrm(coord)) self.enableOnscreenLog();
    }

    fn connectBackendOutputs(self: *Self, impl: backend.Implementation) Error!void {
        switch (impl.backendType()) {
            .wayland => try self.connectWaylandOutputs(impl),
            .drm => try self.connectDrmOutputs(impl),
            else => {},
        }
    }

    fn detachBackend(self: *Self) void {
        self.disableOnscreenLog();
        self.detachSessionListeners();
        self.neutralizeBackendCallbacks();
        for (self.outputs.items) |output| {
            output.deinit();
        }
        self.outputs.clearRetainingCapacity();
        self.coordinator = null;
    }

    fn hasLiveDrm(coord: *backend.Coordinator) bool {
        for (coord.implementations.items) |impl| {
            if (impl.backendType() != .drm) continue;
            const drm_backend: *backend.drm.Backend = @ptrCast(@alignCast(impl.base.ptr));
            if (drm_backend.drm_fd >= 0) return true;
        }
        return false;
    }

    fn enableOnscreenLog(self: *Self) void {
        if (self.log_overlay != null) {
            self.onscreen_log = true;
            return;
        }
        const overlay = log_overlay.Overlay.init(self.allocator) catch {
            self.logger.warn("On-screen log: no system monospace font", .{});
            return;
        };
        self.log_overlay = overlay;
        self.onscreen_log = true;
        self.logger.setEnableRolling(true);
        cli.enableGlobalRolling();
        self.logger.setAppendSink(onLogAppend, self);
        cli.setGlobalAppendSink(onLogAppend, self);
    }

    fn disableOnscreenLog(self: *Self) void {
        self.logger.setAppendSink(null, null);
        cli.setGlobalAppendSink(null, null);
        self.onscreen_log = false;
        if (self.log_overlay) |overlay| {
            overlay.deinit();
            self.log_overlay = null;
        }
    }

    fn onLogAppend(userdata: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return));
        if (!self.onscreen_log or self.painting_log) return;
        for (self.outputs.items) |output| {
            if (output.frame_pending) continue;
            output.scheduleFrame();
        }
    }

    fn detachSessionListeners(self: *Self) void {
        deinitOptionalListener(&self.session_input_listener);
        deinitOptionalListener(&self.session_device_change_listener);
        deinitOptionalListener(&self.session_seat_disable_listener);
        deinitOptionalListener(&self.session_seat_enable_listener);
        for (self.session_event_sources.items) |source| {
            _ = wayland.c.wl_event_source_remove(source);
        }
        self.session_event_sources.clearRetainingCapacity();
    }

    fn neutralizeBackendCallbacks(self: *Self) void {
        for (self.outputs.items) |output| {
            output.backend_output.clearCallbacks();
        }
    }

    fn attachSessionInput(self: *Self, coord: *backend.Coordinator) Error!void {
        const sess = coord.session orelse return;
        try self.listenSessionSignals(sess);
        const event_loop = wayland.c.wl_display_get_event_loop(self.server.getDisplay()) orelse
            return error.EventLoopUnavailable;
        const fds = sess.pollFds(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(fds);
        for (fds) |fd| {
            try self.addSessionFdSource(event_loop, fd.fd, sess);
        }
    }

    fn listenSessionSignals(self: *Self, sess: *backend.session.Type) Error!void {
        self.session_input_listener = sess.signal_input_event.listen(runtimeInputEvent, self) catch
            return error.OutOfMemory;
        self.session_device_change_listener = sess.signal_device_change.listen(sessionDeviceChange, self) catch
            return error.OutOfMemory;
        if (comptime hasSeatLifecycleSignals()) {
            self.session_seat_disable_listener = sess.signal_seat_disable.listen(onSeatDisable, self) catch
                return error.OutOfMemory;
            self.session_seat_enable_listener = sess.signal_seat_enable.listen(onSeatEnable, self) catch {
                deinitOptionalListener(&self.session_seat_disable_listener);
                return error.OutOfMemory;
            };
        }
    }

    fn addSessionFdSource(
        self: *Self,
        event_loop: anytype,
        fd: i32,
        sess: *backend.session.Type,
    ) Error!void {
        const source = wayland.c.wl_event_loop_add_fd(
            event_loop,
            fd,
            wayland.c.WL_EVENT_READABLE,
            sessionFdReady,
            sess,
        ) orelse return error.EventLoopUnavailable;
        self.session_event_sources.append(self.allocator, source) catch {
            _ = wayland.c.wl_event_source_remove(source);
            return error.OutOfMemory;
        };
    }

    pub fn setRuntimeEventHandler(
        self: *Self,
        userdata: ?*anyopaque,
        handler: *const fn (?*anyopaque, backend.input.Event) void,
    ) void {
        self.runtime_event_userdata = userdata;
        self.runtime_event_handler = handler;
    }

    pub fn setInputSuspensionHandler(
        self: *Self,
        userdata: ?*anyopaque,
        handler: *const fn (?*anyopaque, bool, bool) void,
    ) void {
        self.input_suspension_userdata = userdata;
        self.input_suspension_handler = handler;
    }

    fn setConstrainedInputSuspended(self: *Self, suspended: bool) void {
        self.pointer_constraints_suspended = suspended;
        self.relative_pointer_suspended = suspended;
        if (self.input_suspension_handler) |handler| {
            handler(self.input_suspension_userdata, suspended, suspended);
        }
    }

    pub fn dispatchRuntimeInput(self: *Self, event: backend.input.Event) void {
        const viewport = self.viewportSize();
        self.seat.setViewport(
            @floatFromInt(@max(viewport.width, 1)),
            @floatFromInt(@max(viewport.height, 1)),
        );
        if (self.runtime_event_handler) |handler| handler(self.runtime_event_userdata, event);
        switch (event) {
            .device_added => |value| self.updateInputCapabilities(value.device, true),
            .device_removed => |value| self.updateInputCapabilities(value.device, false),
            .pointer_motion => |value| {
                const point = self.clampPointer(
                    self.seat.pointer_x + value.delta_x,
                    self.seat.pointer_y + value.delta_y,
                );
                self.seat.motionAbsolute(
                    self.surfaces.items,
                    timestampMsec(value.time_usec),
                    point.x,
                    point.y,
                );
                self.repaintPointer();
            },
            .pointer_motion_absolute => |value| {
                self.seat.motionAbsolute(
                    self.surfaces.items,
                    timestampMsec(value.time_usec),
                    value.x * @as(f64, @floatFromInt(self.viewportSize().width)),
                    value.y * @as(f64, @floatFromInt(self.viewportSize().height)),
                );
                self.repaintPointer();
            },
            .pointer_button => |value| {
                self.seat.button(
                    timestampMsec(value.time_usec),
                    value.button,
                    @enumFromInt(@intFromEnum(value.state)),
                );
                self.repaintPointer();
            },
            .pointer_axis => |value| self.seat.axis(
                timestampMsec(value.time_usec),
                @enumFromInt(@intFromEnum(value.source)),
                @enumFromInt(@intFromEnum(value.axis)),
                value.value,
                value.value_discrete,
                self.pointerOverTileGap(),
            ),
            .keyboard_key => |value| self.handleKey(
                timestampMsec(value.time_usec),
                value.key,
                @enumFromInt(@intFromEnum(value.state)),
            ),
            .touch_down => |value| self.seat.touchDown(
                self.surfaces.items,
                timestampMsec(value.time_usec),
                value.slot,
                value.x * @as(f64, @floatFromInt(self.viewportSize().width)),
                value.y * @as(f64, @floatFromInt(self.viewportSize().height)),
            ),
            .touch_up => |value| self.seat.touchUp(timestampMsec(value.time_usec), value.slot),
            .touch_motion => |value| self.seat.touchMotion(
                timestampMsec(value.time_usec),
                value.slot,
                value.x * @as(f64, @floatFromInt(self.viewportSize().width)),
                value.y * @as(f64, @floatFromInt(self.viewportSize().height)),
            ),
            .touch_frame => self.seat.touchFrame(),
            .touch_cancel => self.seat.touchCancel(),
            .gesture_swipe_begin => |value| self.seat.trackpadSwipeBegin(
                timestampMsec(value.time_usec),
                value.fingers,
            ),
            .gesture_swipe_update => |value| self.seat.trackpadSwipeUpdate(
                timestampMsec(value.time_usec),
                value.delta_x,
                value.delta_y,
            ),
            .gesture_swipe_end => |value| self.seat.trackpadSwipeEnd(
                timestampMsec(value.time_usec),
                value.cancelled,
            ),
            .gesture_pinch_begin => |value| self.seat.trackpadPinchBegin(
                timestampMsec(value.time_usec),
                value.scale,
            ),
            .gesture_pinch_update => |value| self.seat.trackpadPinchUpdate(
                timestampMsec(value.time_usec),
                value.scale,
            ),
            .gesture_pinch_end => |value| self.seat.trackpadPinchEnd(
                timestampMsec(value.time_usec),
                value.cancelled,
            ),
            .gesture_hold_begin => |value| self.seat.trackpadHoldBegin(
                timestampMsec(value.time_usec),
                value.fingers,
            ),
            .gesture_hold_end => |value| self.seat.trackpadHoldEnd(
                timestampMsec(value.time_usec),
                value.cancelled,
            ),
            else => {},
        }
    }

    fn updateInputCapabilities(self: *Self, device: *backend.input.Device, added: bool) void {
        if (device.has_side_button) updateCount(&self.side_button_devices, added);
        if (device.has_extra_button) updateCount(&self.extra_button_devices, added);
        self.seat.selectShellButton(self.side_button_devices > 0, self.extra_button_devices > 0);
    }

    fn connectWaylandOutputs(self: *Self, impl: backend.Implementation) Error!void {
        const backend_ptr = impl.base.ptr;

        // Cast to Wayland Backend
        const wl_backend: *backend.wayland.Backend = @ptrCast(@alignCast(backend_ptr));
        wl_backend.setInputHandler(self, .{
            .pointer_motion_absolute = inputPointerMotion,
            .pointer_button = inputPointerButton,
            .pointer_axis = inputPointerAxis,
            .pointer_frame = inputPointerFrame,
            .keyboard_key = inputKeyboardKey,
            .keyboard_modifiers = inputKeyboardModifiers,
            .touch_down = inputTouchDown,
            .touch_up = inputTouchUp,
            .touch_motion = inputTouchMotion,
            .touch_frame = inputTouchFrame,
            .touch_cancel = inputTouchCancel,
        });

        // Register backend with server event loop for automatic dispatch
        var display = wayland.Display{ .handle = self.server.getDisplay() };
        const event_loop_handle = try display.getEventLoop();

        self.logger.debug("About to register backend with event loop (backend_display={})", .{wl_backend.state.display != null});
        wl_backend.registerWithEventLoop(@ptrCast(event_loop_handle));
        self.logger.debug("Finished registering backend with event loop", .{});

        if (wl_backend.outputs.items.len == 0) {
            self.logger.warn("No backend outputs available to connect", .{});
            return;
        }

        // For each output in the backend, create a compositor output
        for (wl_backend.outputs.items) |wl_output| {
            // Get the IOutput interface by value (not a pointer to stack!)
            const backend_output = wl_output.iface();
            const comp_output = try self.createOutput(backend_output, wl_output.name);

            // Register frame callback
            wl_output.setFrameCallback(outputFrameCallback, comp_output);
            wl_output.setDestroyCallback(outputDestroyCallback, comp_output);
            wl_output.setConfigureCallback(outputConfigureCallback, comp_output);
            const size = wl_output.logicalSize();
            _ = comp_output.applyGeometry(size.width, size.height, wl_backend.host_scale);
            if (self.toplevels.items.len > 0) self.relayoutToplevels();
            comp_output.scheduleFrame();

            self.logger.info(
                "Connected compositor output to backend output: {s} ({}x{} @{d:.2})",
                .{ wl_output.name, comp_output.logical_width, comp_output.logical_height, comp_output.fractional_scale },
            );
        }
    }

    fn connectDrmOutputs(self: *Self, impl: backend.Implementation) Error!void {
        const drm_backend: *backend.drm.Backend = @ptrCast(@alignCast(impl.base.ptr));
        try self.registerDrmEvents(drm_backend);
        if (drm_backend.outputs.items.len == 0) {
            self.logger.warn("No DRM outputs available to connect", .{});
            return;
        }

        for (drm_backend.outputs.items) |drm_output| {
            try self.connectDrmOutput(drm_output);
        }
    }

    fn handleDrmHotplug(self: *Self, connector_id: u32) void {
        const coord = self.coordinator orelse return;
        for (coord.implementations.items) |impl| {
            self.rescanDrmImplementation(impl, connector_id);
        }
    }

    fn rescanDrmImplementation(self: *Self, impl: backend.Implementation, connector_id: u32) void {
        if (impl.backendType() != .drm) return;
        const drm_backend: *backend.drm.Backend = @ptrCast(@alignCast(impl.base.ptr));
        drm_backend.rescanHotplug(connector_id) catch {
            self.logger.err("Failed to rescan DRM connectors", .{});
            return;
        };
        self.syncDrmOutputs(drm_backend);
    }

    fn syncDrmOutputs(self: *Self, drm_backend: *backend.drm.Backend) void {
        for (drm_backend.outputs.items) |drm_output| {
            if (self.hasBackendOutput(drm_output)) continue;
            self.connectDrmOutput(drm_output) catch {
                self.logger.err("Failed to connect DRM output {s}", .{drm_output.name});
            };
        }
    }

    fn hasBackendOutput(self: *const Self, drm_output: *backend.drm.Output) bool {
        const ptr: *anyopaque = @ptrCast(drm_output);
        for (self.outputs.items) |output| {
            if (output.backend_output.base.ptr == ptr) return true;
        }
        return false;
    }

    fn connectDrmOutput(self: *Self, drm_output: *backend.drm.Output) Error!void {
        const backend_output = drm_output.iface();
        const comp_output = try self.createOutput(backend_output, drm_output.name);
        drm_output.setFrameCallback(outputFrameCallback, comp_output);
        drm_output.setDestroyCallback(outputDestroyCallback, comp_output);
        const size = drm_output.logicalSize();
        comp_output.scale_locked = false;
        _ = comp_output.applyGeometry(size.width, size.height, 1);
        comp_output.fractional_scale = 1;
        comp_output.software_cursor = true;
        comp_output.hdr_caps = .{
            .hdr10 = drm_output.connector.hdr.hdr10,
            .hlg = drm_output.connector.hdr.hlg,
            .bt2020 = drm_output.connector.hdr.bt2020,
            .max_luminance_cdm2 = drm_output.connector.hdr.max_luminance_cdm2,
            .max_frame_avg_luminance_cdm2 = drm_output.connector.hdr.max_frame_avg_luminance_cdm2,
            .min_luminance_cdm2 = drm_output.connector.hdr.min_luminance_cdm2,
        };
        self.centerPointerIfUnset(comp_output);
        if (self.toplevels.items.len > 0) self.relayoutToplevels();
        if (drm_output.backend.drm_fd >= 0) self.enableOnscreenLog();
        comp_output.scheduleFrame();
        self.logger.info(
            "Connected compositor output to DRM output: {s} ({}x{})",
            .{ drm_output.name, comp_output.logical_width, comp_output.logical_height },
        );
    }

    fn registerDrmEvents(self: *Self, drm_backend: *backend.drm.Backend) Error!void {
        if (drm_backend.drm_fd < 0) return;
        const event_loop = wayland.c.wl_display_get_event_loop(self.server.getDisplay()) orelse
            return error.EventLoopUnavailable;
        const source = wayland.c.wl_event_loop_add_fd(
            event_loop,
            drm_backend.drm_fd,
            wayland.c.WL_EVENT_READABLE,
            drmFdReady,
            drm_backend,
        ) orelse return error.EventLoopUnavailable;
        self.session_event_sources.append(self.allocator, source) catch {
            _ = wayland.c.wl_event_source_remove(source);
            return error.OutOfMemory;
        };
    }

    /// Creates a new surface and registers it with the compositor
    pub fn createSurface(self: *Self) Error!*Surface {
        const id = self.next_surface_id;
        self.next_surface_id += 1;

        self.logger.debug("Compositor: Creating surface {d}", .{id});
        const surface = try Surface.init(self.allocator, self, id);
        errdefer surface.deinit();

        try self.surfaces.append(self.allocator, surface);
        self.logger.debug("Compositor: Surface {d} registered (total surfaces: {d})", .{ id, self.surfaces.items.len });
        return surface;
    }

    /// Removes and destroys a surface. Logs the reason for debugging.
    pub fn destroySurface(self: *Self, surface: *Surface, reason: string) void {
        self.logger.debug("Destroyed surface {d}: {s}", .{ surface.id, reason });
        if (self.shell) |host| host.forgetSurface(surface);
        self.seat.surfaceDestroyed(surface);

        // Find and remove from list
        for (self.surfaces.items, 0..) |s, i| {
            if (s == surface) {
                _ = self.surfaces.swapRemove(i);
                break;
            }
        }

        surface.deinit();
    }

    /// Gets the next serial number from the display
    pub fn nextSerial(self: *Self) u32 {
        return wayland.c.wl_display_next_serial(self.server.getDisplay());
    }

    pub fn preferredScale(self: *const Self) f32 {
        if (self.outputs.items.len == 0) return 1;
        return self.outputs.items[0].fractional_scale;
    }

    pub fn announceGeometry(self: *Self) void {
        @import("protocols/output.zig").broadcast(self);
        const preferred = self.preferredScale();
        for (self.surfaces.items) |surface| {
            @import("protocols/hidpi.zig").sendPreferred(surface, preferred);
        }
    }

    pub fn mapToplevel(
        self: *Self,
        surface: *Surface,
        context: *anyopaque,
        configure: *const fn (*anyopaque, i32, i32, u32) void,
    ) void {
        self.mapToplevelWithHints(surface, context, configure, .{});
    }

    pub fn mapToplevelWithHints(
        self: *Self,
        surface: *Surface,
        context: *anyopaque,
        configure: *const fn (*anyopaque, i32, i32, u32) void,
        hints: ToplevelHints,
    ) void {
        self.retainSheetHost();
        for (self.toplevels.items) |entry| {
            if (entry.surface == surface) return;
        }
        self.toplevels.append(self.allocator, .{
            .surface = surface,
            .context = context,
            .configure = configure,
        }) catch return;
        const entry = self.lastToplevel().?;
        applyHints(entry, hints);
        self.classifyEntry(entry);
        self.focusMapped(surface);
        self.relayoutToplevels();
        self.seat.activate(surface);
    }

    pub fn unmapToplevel(self: *Self, surface: *Surface) void {
        if (self.sheet_host == surface) self.sheet_host = null;
        self.closeSheetsOf(surface);
        const removed_column = self.columnIndexOf(surface);
        for (self.toplevels.items, 0..) |entry, index| {
            if (entry.surface != surface) continue;
            if (self.fallback_ring) |ring| {
                if (ring.target_surface == surface) self.closeFallbackRing();
            }
            _ = self.toplevels.orderedRemove(index);
            self.adjustFocusedColumn(removed_column);
            self.relayoutToplevels();
            self.seat.surfaceUnmapped(surface);
            return;
        }
        self.seat.surfaceUnmapped(surface);
    }

    pub fn findToplevel(self: *Self, surface: *Surface) ?*Toplevel {
        for (self.toplevels.items) |*entry| {
            if (entry.surface == surface) return entry;
        }
        return null;
    }

    pub fn refreshToplevel(self: *Self, surface: *Surface, hints: ToplevelHints) void {
        const entry = self.findToplevel(surface) orelse return;
        applyHints(entry, hints);
        self.classifyEntry(entry);
        entry.needs_configure = true;
        const fullscreen = entry.fullscreen;
        if (fullscreen) self.raiseOverlay(surface);
        self.syncFocusAfterClassify(surface);
        self.relayoutToplevels();
    }

    pub fn setToplevelDialog(self: *Self, surface: *Surface, is_dialog: bool, modal: bool) void {
        const entry = self.findToplevel(surface) orelse return;
        entry.is_dialog = is_dialog;
        entry.modal = modal;
        self.classifyEntry(entry);
        self.syncFocusAfterClassify(surface);
        entry.needs_configure = true;
        self.relayoutToplevels();
    }

    pub fn tickLayout(self: *Self, dt: f32) bool {
        var moving = false;
        for (self.toplevels.items) |*entry| {
            if (entry.closing) continue;
            if (self.stepMotion(entry, dt)) moving = true;
            self.applyDisplay(entry);
        }
        return moving;
    }

    fn relayoutToplevels(self: *Self) void {
        self.refreshClassification();
        const viewport = self.viewportSize();
        self.assignColumnTargets(viewport) catch return;
        self.assignSheetTargets() catch return;
        self.assignOverlayTargets(viewport);
        self.applyMotionAndConfigure();
        self.applyModalInput();
        self.scheduleFrame();
    }

    fn targetViewportX(self: *const Self, column_width: i32) f64 {
        const focused = self.focused_column orelse return 0;
        const base = self.columnOffset(focused);
        const direction = self.drag_direction orelse return base;
        if (adjacentIndex(focused, self.columnCount(), direction) == focused) return base;
        const offset = self.drag_progress * @as(f64, @floatFromInt(column_width));
        return switch (direction) {
            .left => base + offset,
            .right => base - offset,
            else => base,
        };
    }

    fn adjustFocusedColumn(self: *Self, removed_column: ?usize) void {
        const focused = self.focused_column orelse return;
        if (self.columnCount() == 0) {
            self.focused_column = null;
            return;
        }
        const removed = removed_column orelse return;
        if (removed < focused or focused >= self.columnCount())
            self.focused_column = focused - 1;
    }

    fn handleGesture(self: *Self, primitive: gesture.Primitive) void {
        switch (primitive) {
            .hold => |event| self.openFallbackRing(event.point),
            .hover => |event| self.hoverFallbackRing(event.point),
            .drag => |event| self.updateColumnDrag(event),
            .flick => |event| self.handleFlick(event.direction),
            .release => self.finishGesture(),
            .back => self.handleBack(),
            .forward => {},
            .zoom => |event| self.applyZoom(event.delta),
        }
    }

    fn openFallbackRing(self: *Self, point: gesture.Point) void {
        sideswipe_shell.dismissPopups(self);
        const origin: gesture.Point = if (self.seat.ring_focus_visible)
            .{ .x = self.seat.pointer_x, .y = self.seat.pointer_y }
        else
            point;
        self.seat.claimOverlay();
        var ring = self.captureFallbackRing(origin);
        if (self.seat.ring_focus_visible) {
            ring.focus_visible = true;
            ring.hover = 0;
            self.seat.ring_focus_visible = false;
        }
        self.fallback_ring = ring;
        self.renderFallbackRing();
        sideswipe_shell.onHold(self, origin);
    }

    fn captureFallbackRing(self: *Self, point: gesture.Point) FallbackRing {
        return .{
            .center = .{ .x = point.x, .y = point.y },
            .target_surface = self.contextualSurface(),
            .output = self.outputAt(point) orelse self.primaryOutput(),
        };
    }

    fn hoverFallbackRing(self: *Self, point: gesture.Point) void {
        const ring = if (self.fallback_ring) |*active| active else return;
        ring.hover = ring_geometry.hit(.{}, ring.center, .{ .x = point.x, .y = point.y }, sideswipe_shell.sliceCount(self)) catch null;
        self.renderFallbackRing();
        sideswipe_shell.onHover(self, ring.hover);
    }

    /// Redraws compositor placeholder quads while a ring grab is live.
    pub fn refreshFallbackRing(self: *Self) void {
        self.renderFallbackRing();
    }

    fn renderFallbackRing(self: *Self) void {
        const ring = self.fallback_ring orelse return;
        const quads = ring_geometry.quadsWithSelection(
            .{},
            ring.center,
            sideswipe_shell.sliceCount(self),
            .fallback,
            ring.hover,
            ring.focus_visible,
        ) catch return;
        self.paintFallbackQuads(ring.output, quads.slice());
    }

    fn paintFallbackQuads(self: *Self, owner: ?*Output, quads: []const ring_geometry.Quad) void {
        for (self.outputs.items) |output| {
            if (owner != null and output != owner) {
                output.scene.clearShellQuads();
                continue;
            }
            output.scene.setShellQuads(self.allocator, quads) catch return;
        }
        const target = owner orelse self.primaryOutput() orelse return;
        target.scheduleFrame();
    }

    fn primaryOutput(self: *const Self) ?*Output {
        if (self.outputs.items.len == 0) return null;
        return self.outputs.items[0];
    }

    fn handleBack(self: *Self) void {
        if (self.fallback_ring != null) {
            self.closeFallbackRing();
            return;
        }
        self.exitFullscreenOverlay();
    }

    fn exitFullscreenOverlay(self: *Self) void {
        var index = self.toplevels.items.len;
        while (index > 0) {
            index -= 1;
            const entry = &self.toplevels.items[index];
            if (!entry.fullscreen or entry.closing) continue;
            entry.fullscreen = false;
            entry.needs_configure = true;
            self.relayoutToplevels();
            return;
        }
    }

    fn closeFallbackRing(self: *Self) void {
        sideswipe_shell.onRingClose(self);
        const owner = if (self.fallback_ring) |ring| ring.output else null;
        self.fallback_ring = null;
        for (self.outputs.items) |output| output.scene.clearShellQuads();
        if (owner) |output| output.scheduleFrame();
        self.seat.releaseOverlay();
    }

    fn updateColumnDrag(self: *Self, event: gesture.Primitive.Drag) void {
        sideswipe_shell.onDrag(self, event);
        if (event.direction != .left and event.direction != .right) return;
        self.drag_direction = event.direction;
        self.drag_progress = event.progress;
        self.slideViewport();
    }

    /// S5/I7: horizontal flick switches the strip (flick right = previous column).
    /// Vertical flick is S1's no-draw ring shortcut (up launch, down close).
    /// S1's horizontal slices are the opposite mapping (right slice = next column).
    fn handleFlick(self: *Self, direction: gesture.Direction) void {
        if (direction == .left or direction == .right) {
            self.switchAdjacent(direction);
            return;
        }
        self.activateFallbackSlice(self.captureFallbackRing(.{
            .x = self.seat.pointer_x,
            .y = self.seat.pointer_y,
        }), sliceForDirection(direction));
    }

    fn finishGesture(self: *Self) void {
        const ring = self.fallback_ring;
        const selected = if (ring) |active| active.hover else null;
        self.closeFallbackRing();
        sideswipe_shell.onRelease(self);
        if (selected) |slice| self.activateFallbackSlice(ring.?, slice);
        const direction = self.drag_direction;
        const should_switch = shouldCommitDrag(self.drag_progress);
        self.drag_direction = null;
        self.drag_progress = 0;
        if (should_switch and direction != null) {
            self.switchAdjacent(direction.?);
            return;
        }
        self.relayoutToplevels();
    }

    fn switchAdjacent(self: *Self, direction: gesture.Direction) void {
        const current = self.focused_column orelse return;
        const adjacent = adjacentIndex(current, self.columnCount(), direction);
        if (adjacent == current) {
            self.drag_direction = null;
            self.drag_progress = 0;
            self.relayoutToplevels();
            return;
        }
        self.focused_column = adjacent;
        self.retainSheetHost();
        self.drag_direction = null;
        self.drag_progress = 0;
        const focused = self.focused_column orelse return;
        self.relayoutToplevels();
        if (self.nthColumn(focused)) |entry| self.seat.activate(entry.surface);
    }

    fn syncColumnToSurface(self: *Self, surface: *Surface) void {
        const column = self.columnIndexOf(surface) orelse self.columnIndexOfParent(surface) orelse return;
        self.focused_column = column;
        self.retainSheetHost();
        self.relayoutToplevels();
    }

    pub fn issueActivationToken(self: *Self) !u64 {
        const token = self.next_activation_token;
        self.next_activation_token +%= 1;
        try self.activation_tokens.put(token, {});
        return token;
    }

    pub fn activateWithToken(self: *Self, token: u64, surface: *Surface) void {
        if (!self.activation_tokens.remove(token)) return;
        if (self.columnIndexOf(surface) orelse self.columnIndexOfParent(surface)) |index| {
            self.focused_column = index;
            self.retainSheetHost();
            self.relayoutToplevels();
        }
        self.seat.activate(surface);
    }

    /// Keeps the compositor placeholder while a ring grab is live.
    /// `commit_surface` is not a visual replacement: the shell stub may map an
    /// empty overlay, and S1/P3 fallback quads stay until the grab ends.
    pub fn replacePlaceholderRing(self: *Self) void {
        self.renderFallbackRing();
    }

    pub const shell_overlay_slots = sideswipe_shell.overlay_slots;

    pub fn shellOverlay(self: *const Self, index: usize) ?*Surface {
        const host = self.shell orelse return null;
        return host.overlayAt(index);
    }

    pub fn activateFallbackSlice(self: *Self, ring: FallbackRing, slice: u8) void {
        const action: FallbackAction = switch (slice) {
            0 => .launch_terminal,
            1 => .next_column,
            2 => .close,
            3 => .previous_column,
            else => return,
        };
        switch (action) {
            .launch_terminal => self.launchTerminal(),
            .next_column => self.switchAdjacentFrom(ring.target_surface, .left),
            .previous_column => self.switchAdjacentFrom(ring.target_surface, .right),
            .close => {
                const target = ring.target_surface orelse return;
                target.requestClose();
            },
        }
    }

    fn switchAdjacentFrom(
        self: *Self,
        surface: ?*Surface,
        direction: gesture.Direction,
    ) void {
        if (surface) |target| self.syncColumnToSurface(target);
        self.switchAdjacent(direction);
    }

    fn applyZoom(self: *Self, delta: f64) void {
        const entry = self.hoverColumn() orelse return;
        const next = entry.column_width.adjust(strip.Width.stepsFromZoom(delta));
        if (next.ratio == entry.column_width.ratio) return;
        entry.column_width = next;
        self.relayoutToplevels();
    }

    fn hoverColumn(self: *Self) ?*Toplevel {
        const x = self.seat.pointer_x;
        const y = self.seat.pointer_y;
        var nearest: ?*Toplevel = null;
        var nearest_dist = std.math.inf(f64);
        for (self.toplevels.items) |*entry| {
            if (!self.isColumn(entry.*)) continue;
            if (containsPoint(entry.*, x, y)) return entry;
            const dist = distanceToRect(entry.*, x, y);
            if (dist >= nearest_dist) continue;
            nearest_dist = dist;
            nearest = entry;
        }
        return nearest;
    }

    /// True on the shared edge between two tiles, including `tile_gap_slop`
    /// so a flush strip seam is hittable. Empty space is not a gap.
    fn pointerOverTileGap(self: *const Self) bool {
        const x = self.seat.pointer_x;
        const y = self.seat.pointer_y;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        for (self.toplevels.items, 0..) |left, index| {
            if (!tileVisible(left)) continue;
            for (self.toplevels.items[index + 1 ..]) |right| {
                if (!tileVisible(right)) continue;
                if (overSeam(left, right, x, y)) return true;
            }
        }
        return false;
    }

    fn slideViewport(self: *Self) void {
        const focused_width = self.focusedColumnWidth(self.viewportSize().width);
        const next = self.targetViewportX(focused_width);
        const delta = @as(i32, @intFromFloat(@round(next))) - @as(i32, @intFromFloat(@round(self.viewport_x)));
        self.viewport_x = next;
        if (delta == 0) return;
        const shift = @as(f32, @floatFromInt(delta));
        for (self.toplevels.items) |*entry| {
            entry.target.x -= delta;
            entry.motion.current.x -= shift;
            entry.motion.target.x -= shift;
            self.applyDisplay(entry);
        }
        self.scheduleFrame();
    }

    fn contextualSurface(self: *const Self) ?*Surface {
        if (self.seat.pointer_focus) |surface| return surface;
        const focused = self.focused_column orelse return null;
        return self.columnSurface(focused);
    }

    fn outputAt(self: *const Self, point: gesture.Point) ?*Output {
        for (self.outputs.items) |output| {
            if (point.x < @as(f64, @floatFromInt(output.logical_x)) or
                point.y < @as(f64, @floatFromInt(output.logical_y)))
                continue;
            if (point.x >= @as(f64, @floatFromInt(output.logical_x + output.logical_width)) or
                point.y >= @as(f64, @floatFromInt(output.logical_y + output.logical_height)))
                continue;
            return output;
        }
        return null;
    }

    fn launchTerminal(self: *Self) void {
        const binary = core.env.get("SIDESWIPE_TERMINAL") orelse "foot";
        const binary_z = self.allocator.dupeZ(u8, binary) catch return;
        defer self.allocator.free(binary_z);
        const child = fork();
        if (child < 0) return;
        if (child == 0) {
            const grandchild = fork();
            if (grandchild < 0) _exit(1);
            if (grandchild != 0) _exit(0);
            const argv = [_:null]?[*:0]const u8{ binary_z.ptr, null };
            _ = execvp(binary_z.ptr, &argv);
            _exit(1);
        }
        _ = waitpid(child, null, 0);
    }

    /// Creates a compositor output from a backend output
    pub fn createOutput(self: *Self, backend_output: backend.output.IOutput, name: string) Error!*Output {
        const output = try Output.init(self.allocator, self, backend_output, name);
        errdefer output.deinit();

        try self.outputs.append(self.allocator, output);
        output.logical_x = @as(i32, @intCast(self.outputs.items.len - 1)) * output.logical_width;
        return output;
    }

    fn destroyOutput(self: *Self, removed: *Output) void {
        for (self.outputs.items, 0..) |output, index| {
            if (output != removed) continue;
            _ = self.outputs.swapRemove(index);
            removed.deinit();
            return;
        }
    }

    pub fn viewportSize(self: *const Self) strip.Size {
        if (self.outputs.items.len == 0) return .{ .width = 1920, .height = 1080 };
        const output = self.outputs.items[0];
        return .{
            .width = @max(1, output.logical_width),
            .height = @max(1, output.logical_height),
        };
    }

    fn clampPointer(self: *const Self, x: f64, y: f64) gesture.Point {
        const bounds = self.viewportSize();
        const max_x = @as(f64, @floatFromInt(@max(bounds.width, 1))) - 1;
        const max_y = @as(f64, @floatFromInt(@max(bounds.height, 1))) - 1;
        return .{
            .x = std.math.clamp(x, 0, max_x),
            .y = std.math.clamp(y, 0, max_y),
        };
    }

    fn handleKey(self: *Self, time: u32, key_code: u32, state: seat_mod.KeyState) void {
        switch (self.seat.key(time, key_code, state)) {
            .quit => self.quitSession(),
            .forwarded, .ignored => {},
        }
    }

    fn quitSession(self: *Self) void {
        self.logger.info("Super+Shift+Q — leaving compositor session", .{});
        self.server.terminate();
    }

    fn centerPointerIfUnset(self: *Self, output: *Output) void {
        if (self.seat.pointer_x != 0 or self.seat.pointer_y != 0) return;
        const width = @as(f64, @floatFromInt(@max(output.logical_width, 1)));
        const height = @as(f64, @floatFromInt(@max(output.logical_height, 1)));
        self.seat.pointer_x = @as(f64, @floatFromInt(output.logical_x)) + width / 2;
        self.seat.pointer_y = @as(f64, @floatFromInt(output.logical_y)) + height / 2;
    }

    fn usesSoftwareCursor(self: *const Self) bool {
        for (self.outputs.items) |output| {
            if (output.software_cursor) return true;
        }
        return false;
    }

    fn repaintPointer(self: *Self) void {
        if (!self.usesSoftwareCursor()) return;
        self.scheduleFrame();
    }

    /// Schedules a frame on all outputs
    pub fn scheduleFrame(self: *Self) void {
        self.logger.debug("Compositor: Scheduling frame on {d} output(s)", .{self.outputs.items.len});
        for (self.outputs.items) |output| {
            output.scheduleFrame();
        }
    }

    fn lastToplevel(self: *Self) ?*Toplevel {
        if (self.toplevels.items.len == 0) return null;
        return &self.toplevels.items[self.toplevels.items.len - 1];
    }

    fn focusMapped(self: *Self, surface: *Surface) void {
        if (self.columnIndexOf(surface)) |index| {
            self.focused_column = index;
            return;
        }
        if (self.columnIndexOfParent(surface)) |index| self.focused_column = index;
    }

    fn refreshClassification(self: *Self) void {
        for (self.toplevels.items) |*entry| self.classifyEntry(entry);
    }

    fn classifyEntry(self: *Self, entry: *Toplevel) void {
        if (entry.closing) return;
        const rule = self.window_rules.lookup(entry.app_id orelse "", entry.title);
        var override_sheet: ?bool = null;
        entry.ssd_override = null;
        if (rule) |matched| {
            if (matched.placement) |placement| override_sheet = placement == .sheet;
            if (matched.column_width) |width| entry.column_width = width;
            if (matched.ssd) |ssd| entry.ssd_override = ssd;
        }
        entry.kind = sheet.classify(.{
            .has_parent = entry.parent != null and self.findToplevel(entry.parent.?) != null,
            .is_dialog = entry.is_dialog,
            .override_sheet = override_sheet,
        });
        entry.ssd = entry.ssd_override orelse (entry.kind == .sheet);
        self.attachOrphanSheet(entry);
    }

    fn retainSheetHost(self: *Self) void {
        if (self.focused_column) |index| {
            if (self.columnSurface(index)) |host| self.sheet_host = host;
        }
    }

    fn attachOrphanSheet(self: *Self, entry: *Toplevel) void {
        if (entry.kind != .sheet or entry.parent != null) return;
        if (self.sheetHost(entry.surface)) |host| {
            entry.parent = host;
            return;
        }
        entry.kind = .column;
        entry.ssd = entry.ssd_override orelse false;
    }

    fn sheetHost(self: *const Self, surface: *Surface) ?*Surface {
        if (self.liveHost(self.focusedColumnSurface(), surface)) |host| return host;
        if (self.liveHost(self.sheet_host, surface)) |host| return host;
        for (self.toplevels.items) |item| {
            if (!self.isColumn(item) or item.surface == surface) continue;
            return item.surface;
        }
        return null;
    }

    fn focusedColumnSurface(self: *const Self) ?*Surface {
        const index = self.focused_column orelse return null;
        return self.columnSurface(index);
    }

    fn liveHost(self: *const Self, candidate: ?*Surface, exclude: *Surface) ?*Surface {
        const host = candidate orelse return null;
        if (host == exclude) return null;
        for (self.toplevels.items) |item| {
            if (item.surface != host) continue;
            if (!self.isColumn(item)) return null;
            return host;
        }
        return null;
    }

    fn syncFocusAfterClassify(self: *Self, surface: *Surface) void {
        if (self.columnIndexOf(surface)) |index| {
            self.focused_column = index;
            return;
        }
        if (self.columnIndexOfParent(surface)) |index| {
            self.focused_column = index;
            return;
        }
        const count = self.columnCount();
        if (count == 0) {
            self.focused_column = null;
            return;
        }
        const focused = self.focused_column orelse return;
        if (focused >= count) self.focused_column = count - 1;
    }

    fn assignColumnTargets(self: *Self, viewport: strip.Size) !void {
        const count = self.columnCount();
        if (count == 0) {
            self.viewport_x = 0;
            return;
        }
        const tiles = try self.allocator.alloc(strip.Tile, count);
        defer self.allocator.free(tiles);
        const columns = try self.allocator.alloc(strip.Column, count);
        defer self.allocator.free(columns);
        self.fillColumnStrip(tiles, columns);

        var result = try strip.compute(self.allocator, .{
            .viewport = viewport,
            .scale = self.preferredScale(),
            .workspace = .{
                .id = 1,
                .columns = columns,
                .focused_column = self.focused_column,
            },
        }, 1);
        defer result.deinit(self.allocator);

        const focused_width = self.focusedColumnWidth(viewport.width);
        self.viewport_x = self.targetViewportX(focused_width);
        self.applyColumnPlacements(result.placements.items);
    }

    fn fillColumnStrip(self: *Self, tiles: []strip.Tile, columns: []strip.Column) void {
        var index: usize = 0;
        for (self.toplevels.items) |entry| {
            if (!self.isColumn(entry)) continue;
            tiles[index] = .{
                .id = entry.surface.id,
                .min_size = if (entry.maximized)
                    .{ .width = 0, .height = 0 }
                else
                    entry.min_size,
            };
            columns[index] = .{
                .id = @intCast(index + 1),
                .width = entry.column_width,
                .tiles = tiles[index .. index + 1],
            };
            index += 1;
        }
    }

    fn applyColumnPlacements(self: *Self, placements: []const strip.Placement) void {
        const scroll = @as(i32, @intFromFloat(@round(self.viewport_x)));
        for (placements) |placement| {
            const entry = self.toplevelById(placement.tile_id) orelse continue;
            entry.target = .{
                .x = placement.geometry.x - scroll,
                .y = placement.geometry.y,
                .width = placement.geometry.width,
                .height = placement.geometry.height,
            };
        }
    }

    fn assignSheetTargets(self: *Self) !void {
        for (self.toplevels.items) |*parent_entry| {
            if (!self.isColumn(parent_entry.*)) continue;
            try self.placeSheetsOn(parent_entry);
        }
        for (self.toplevels.items) |*parent_entry| {
            if (parent_entry.kind != .sheet or parent_entry.fullscreen or parent_entry.closing) continue;
            try self.placeSheetsOn(parent_entry);
        }
    }

    fn placeSheetsOn(self: *Self, parent_entry: *Toplevel) !void {
        var requests = std.ArrayList(sheet.Request).empty;
        defer requests.deinit(self.allocator);
        for (self.toplevels.items) |entry| {
            if (entry.kind != .sheet or entry.fullscreen or entry.closing) continue;
            if (entry.parent != parent_entry.surface) continue;
            try requests.append(self.allocator, .{
                .id = entry.surface.id,
                .height = sheet.resolveHeight(.{
                    .parent_height = parent_entry.target.height,
                    .window_geometry_height = if (entry.window_geometry) |geo| geo.height else null,
                    .min_height = entry.min_size.height,
                    .max_height = entry.max_size.height,
                }),
            });
        }
        if (requests.items.len == 0) return;

        var result = try sheet.place(self.allocator, parent_entry.target, requests.items);
        defer result.deinit(self.allocator);
        parent_entry.target = result.parent;
        for (result.sheets.items) |placed| {
            const child = self.toplevelById(placed.id) orelse continue;
            child.target = placed.geometry;
            child.handle = placed.handle;
        }
    }

    fn assignOverlayTargets(self: *Self, viewport: strip.Size) void {
        for (self.toplevels.items) |*entry| {
            if (!entry.fullscreen or entry.closing) continue;
            entry.target = .{
                .x = 0,
                .y = 0,
                .width = viewport.width,
                .height = viewport.height,
            };
        }
    }

    fn applyMotionAndConfigure(self: *Self) void {
        for (self.toplevels.items) |*entry| {
            if (entry.closing) continue;
            anim.retarget(&entry.motion, entry.target);
            if (committedLogicalSize(entry.surface) == null) {
                entry.motion.current = entry.motion.target;
                entry.motion.velocity = .{};
            }
            self.maybeConfigure(entry);
            if (committedLogicalSize(entry.surface)) |size| {
                _ = anim.earlySwap(&entry.motion, size);
            }
            self.applyDisplay(entry);
        }
    }

    fn maybeConfigure(self: *Self, entry: *Toplevel) void {
        const target = entry.motion.targetGeometry();
        const size_changed = entry.motion.configured.width != target.width or
            entry.motion.configured.height != target.height;
        if (!size_changed and !entry.needs_configure) return;
        entry.motion.configured = .{ .width = target.width, .height = target.height };
        entry.needs_configure = false;
        entry.configure(entry.context, target.width, target.height, self.nextSerial());
    }

    fn stepMotion(self: *Self, entry: *Toplevel, dt: f32) bool {
        _ = self;
        if (committedLogicalSize(entry.surface)) |size| {
            if (anim.earlySwap(&entry.motion, size)) return false;
            return anim.tick(&entry.motion, dt);
        }
        entry.motion.current = entry.motion.target;
        entry.motion.velocity = .{};
        return false;
    }

    fn applyDisplay(_: *Self, entry: *Toplevel) void {
        const geometry = entry.motion.display();
        entry.x = geometry.x;
        entry.y = geometry.y;
        entry.width = geometry.width;
        entry.height = geometry.height;
        entry.surface.scene_geometry = .{
            .x = geometry.x,
            .y = geometry.y,
            .width = geometry.width,
            .height = geometry.height,
        };
        if (entry.ssd) {
            entry.handle = .{
                .x = geometry.x,
                .y = geometry.y,
                .width = geometry.width,
                .height = @min(sheet.HANDLE_HEIGHT, geometry.height),
            };
        } else {
            entry.handle = null;
        }
    }

    fn closeSheetsOf(self: *Self, parent: *Surface) void {
        for (self.toplevels.items) |*entry| {
            if (entry.closing) continue;
            if (!self.isSheetOf(entry.*, parent)) continue;
            entry.closing = true;
            entry.handle = null;
            entry.surface.scene_geometry = null;
            entry.surface.input_inert = false;
            entry.surface.requestClose();
        }
    }

    fn isSheetOf(self: *Self, entry: Toplevel, ancestor: *Surface) bool {
        var current = entry.parent;
        var depth: usize = 0;
        while (current) |parent| {
            if (parent == ancestor) return true;
            if (depth >= 32) return false;
            depth += 1;
            const parent_entry = self.findToplevel(parent) orelse return false;
            current = parent_entry.parent;
        }
        return false;
    }

    fn applyModalInput(self: *Self) void {
        for (self.toplevels.items) |entry| entry.surface.input_inert = false;
        for (self.toplevels.items) |entry| {
            if (!self.blocksParent(entry)) continue;
            const parent = entry.parent orelse continue;
            parent.input_inert = true;
        }
        self.seat.repickIfInert(self.surfaces.items);
        self.refocusIfInert();
    }

    fn blocksParent(self: *const Self, entry: Toplevel) bool {
        _ = self;
        return entry.modal and entry.kind == .sheet and !entry.closing and !entry.fullscreen;
    }

    fn refocusIfInert(self: *Self) void {
        const focus = self.seat.keyboard_focus orelse return;
        if (!focus.input_inert) return;
        if (self.modalSheetOf(focus)) |sheet_entry| {
            self.seat.activate(sheet_entry.surface);
        }
    }

    fn modalSheetOf(self: *Self, parent: *Surface) ?*Toplevel {
        for (self.toplevels.items) |*entry| {
            if (!self.blocksParent(entry.*) or entry.parent != parent) continue;
            return entry;
        }
        return null;
    }

    fn raiseOverlay(self: *Self, surface: *Surface) void {
        const index = self.arrayIndexOf(surface) orelse return;
        const last = self.toplevels.items.len - 1;
        if (index == last) return;
        const entry = self.toplevels.orderedRemove(index);
        self.toplevels.append(self.allocator, entry) catch {
            self.toplevels.insert(self.allocator, index, entry) catch {};
        };
    }

    fn isColumn(self: *const Self, entry: Toplevel) bool {
        _ = self;
        return entry.kind == .column and !entry.fullscreen and !entry.closing;
    }

    fn columnCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.toplevels.items) |entry| {
            if (self.isColumn(entry)) count += 1;
        }
        return count;
    }

    fn nthColumn(self: *Self, index: usize) ?*Toplevel {
        var current: usize = 0;
        for (self.toplevels.items) |*entry| {
            if (!self.isColumn(entry.*)) continue;
            if (current == index) return entry;
            current += 1;
        }
        return null;
    }

    fn columnSurface(self: *const Self, index: usize) ?*Surface {
        var current: usize = 0;
        for (self.toplevels.items) |entry| {
            if (!self.isColumn(entry)) continue;
            if (current == index) return entry.surface;
            current += 1;
        }
        return null;
    }

    fn columnIndexOf(self: *const Self, surface: *Surface) ?usize {
        var index: usize = 0;
        for (self.toplevels.items) |entry| {
            if (!self.isColumn(entry)) continue;
            if (entry.surface == surface) return index;
            index += 1;
        }
        return null;
    }

    fn columnIndexOfParent(self: *const Self, surface: *Surface) ?usize {
        const entry = for (self.toplevels.items) |item| {
            if (item.surface == surface) break item;
        } else return null;
        const parent = entry.parent orelse return null;
        return self.columnIndexOf(parent);
    }

    fn columnOffset(self: *const Self, column_index: usize) f64 {
        const viewport_width = self.viewportSize().width;
        var x: i32 = 0;
        var index: usize = 0;
        for (self.toplevels.items) |entry| {
            if (!self.isColumn(entry)) continue;
            if (index == column_index) return @floatFromInt(x);
            x += entry.column_width.pixels(viewport_width);
            index += 1;
        }
        return @floatFromInt(x);
    }

    fn focusedColumnWidth(self: *const Self, viewport_width: i32) i32 {
        const focused = self.focused_column orelse return strip.Width.full.pixels(viewport_width);
        var index: usize = 0;
        for (self.toplevels.items) |entry| {
            if (!self.isColumn(entry)) continue;
            if (index == focused) return entry.column_width.pixels(viewport_width);
            index += 1;
        }
        return strip.Width.full.pixels(viewport_width);
    }

    fn toplevelById(self: *Self, id: u32) ?*Toplevel {
        for (self.toplevels.items) |*entry| {
            if (entry.surface.id == id) return entry;
        }
        return null;
    }

    fn arrayIndexOf(self: *const Self, surface: *Surface) ?usize {
        for (self.toplevels.items, 0..) |entry, index| {
            if (entry.surface == surface) return index;
        }
        return null;
    }
};

fn applyHints(entry: *Compositor.Toplevel, hints: Compositor.ToplevelHints) void {
    entry.parent = hints.parent;
    entry.is_dialog = hints.is_dialog;
    entry.modal = hints.modal;
    entry.app_id = hints.app_id;
    entry.title = hints.title;
    entry.min_size = hints.min_size;
    entry.max_size = hints.max_size;
    entry.window_geometry = hints.window_geometry;
    entry.maximized = hints.maximized;
    entry.fullscreen = hints.fullscreen;
}

fn committedLogicalSize(surface: *Surface) ?strip.Size {
    if (surface.current.viewport.destination) |dest| {
        return .{ .width = dest.width, .height = dest.height };
    }
    const resource = surface.current.buffer.buffer orelse return null;
    return bufferLogicalSize(resource, @max(1, surface.current.buffer.scale));
}

fn bufferLogicalSize(resource: *wayland.c.wl_resource, scale: i32) ?strip.Size {
    if (wayland.c.wl_shm_buffer_get(resource)) |shm| {
        return .{
            .width = @divTrunc(wayland.c.wl_shm_buffer_get_width(shm), scale),
            .height = @divTrunc(wayland.c.wl_shm_buffer_get_height(shm), scale),
        };
    }
    if (!linux_dmabuf.isBuffer(resource)) return null;
    const data: *linux_dmabuf.BufferData = @ptrCast(@alignCast(wayland.c.wl_resource_get_user_data(resource)));
    return .{
        .width = @divTrunc(data.params_data.width, scale),
        .height = @divTrunc(data.params_data.height, scale),
    };
}

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = @intCast(@max(ts.sec, 0));
    const nsec: u64 = @intCast(@max(ts.nsec, 0));
    return sec * std.time.ns_per_s + nsec;
}

fn frameDelta(previous: u64, now: u64) f32 {
    if (previous == 0 or now <= previous) return 1.0 / 60.0;
    const delta_ns = now - previous;
    return @as(f32, @floatFromInt(delta_ns)) / @as(f32, std.time.ns_per_s);
}

fn hasSeatLifecycleSignals() bool {
    return @hasField(backend.session.Type, "signal_seat_disable") and
        @hasField(backend.session.Type, "signal_seat_enable");
}

fn deinitOptionalListener(listener: *?core.events.Listener) void {
    const active = if (listener.*) |*item| item else return;
    active.deinit();
    listener.* = null;
}

fn fromUserdata(userdata: ?*anyopaque) ?*Compositor {
    return @ptrCast(@alignCast(userdata orelse return null));
}

fn pauseConstrainedInput(userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    self.setConstrainedInputSuspended(true);
}

fn restoreConstrainedInput(userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    self.setConstrainedInputSuspended(false);
}

fn runtimeInputEvent(event: backend.input.Event, userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    self.dispatchRuntimeInput(event);
}

fn sessionDeviceChange(event: backend.session.ChangeEvent, userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    if (event.event_type != .hotplug) return;
    self.handleDrmHotplug(event.hotplug.connector_id);
}

fn onSeatDisable(userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    const coord = self.coordinator orelse return;
    coord.pausePhysicalSession();
}

fn onSeatEnable(userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    const coord = self.coordinator orelse return;
    coord.resumePhysicalSession();
}

fn sessionFdReady(_: i32, _: u32, userdata: ?*anyopaque) callconv(.c) i32 {
    const session: *backend.session.Type = @ptrCast(@alignCast(userdata orelse return 0));
    session.dispatchPendingEventsAsync();
    return 0;
}

fn drmFdReady(_: i32, _: u32, userdata: ?*anyopaque) callconv(.c) i32 {
    const drm_backend: *backend.drm.Backend = @ptrCast(@alignCast(userdata orelse return 0));
    drm_backend.dispatchEvents();
    return 0;
}

fn timestampMsec(time_usec: u64) u32 {
    return @truncate(time_usec / std.time.us_per_ms);
}

fn updateCount(count: *usize, added: bool) void {
    if (added) {
        count.* += 1;
    } else {
        count.* -|= 1;
    }
}

fn inputPointerMotion(userdata: ?*anyopaque, event: backend.wayland.input_signals.PointerMotionAbsoluteEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.motionAbsolute(self.surfaces.items, event.time_msec, event.x, event.y);
}

fn inputPointerButton(userdata: ?*anyopaque, event: backend.wayland.input_signals.PointerButtonEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.button(event.time_msec, event.button, @enumFromInt(@intFromEnum(event.state)));
}

fn inputPointerAxis(userdata: ?*anyopaque, event: backend.wayland.input_signals.PointerAxisEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.axis(
        event.time_msec,
        @enumFromInt(@intFromEnum(event.source)),
        @enumFromInt(@intFromEnum(event.orientation)),
        event.delta,
        event.delta_discrete,
        self.pointerOverTileGap(),
    );
}

fn inputPointerFrame(_: ?*anyopaque) void {}

fn inputKeyboardKey(userdata: ?*anyopaque, event: backend.wayland.input_signals.KeyboardKeyEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.handleKey(event.time_msec, event.key, @enumFromInt(@intFromEnum(event.state)));
}

fn inputKeyboardModifiers(userdata: ?*anyopaque, event: backend.wayland.input_signals.KeyboardModifiersEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.modifiers(event.depressed, event.latched, event.locked, event.group);
}

fn inputTouchDown(userdata: ?*anyopaque, event: backend.wayland.input_signals.TouchDownEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.touchDown(self.surfaces.items, event.time_msec, event.touch_id, event.x, event.y);
}

fn inputTouchUp(userdata: ?*anyopaque, event: backend.wayland.input_signals.TouchUpEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.touchUp(event.time_msec, event.touch_id);
}

fn inputTouchMotion(userdata: ?*anyopaque, event: backend.wayland.input_signals.TouchMotionEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.touchMotion(event.time_msec, event.touch_id, event.x, event.y);
}

fn inputTouchFrame(userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.touchFrame();
}

fn inputTouchCancel(userdata: ?*anyopaque) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.touchCancel();
}

fn gestureInput(userdata: ?*anyopaque, primitive: gesture.Primitive) void {
    const self = fromUserdata(userdata) orelse return;
    self.handleGesture(primitive);
}

fn focusInput(userdata: ?*anyopaque, surface: *Surface) void {
    const self = fromUserdata(userdata) orelse return;
    self.syncColumnToSurface(surface);
}

const tile_gap_slop: f64 = 8;

fn containsPoint(entry: Compositor.Toplevel, x: f64, y: f64) bool {
    return containsRect(entry.target, x, y);
}

fn containsRect(rect: strip.Geometry, x: f64, y: f64) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    if (rect.width <= 0 or rect.height <= 0) return false;
    const left = @as(f64, @floatFromInt(rect.x));
    const top = @as(f64, @floatFromInt(rect.y));
    const right = @as(f64, @floatFromInt(rect.x + rect.width));
    const bottom = @as(f64, @floatFromInt(rect.y + rect.height));
    return x >= left and y >= top and x < right and y < bottom;
}

fn tileVisible(entry: Compositor.Toplevel) bool {
    return entry.target.width > 0 and entry.target.height > 0 and !entry.fullscreen;
}

fn overSeam(a: Compositor.Toplevel, b: Compositor.Toplevel, x: f64, y: f64) bool {
    if (overVerticalSeam(a, b, x, y)) return true;
    return overHorizontalSeam(a, b, x, y);
}

fn overVerticalSeam(a: Compositor.Toplevel, b: Compositor.Toplevel, x: f64, y: f64) bool {
    const seam = verticalSeam(a.target, b.target) orelse return false;
    if (@abs(x - seam) > tile_gap_slop) return false;
    return rangeContains(a.target.y, a.target.height, b.target.y, b.target.height, y);
}

fn overHorizontalSeam(a: Compositor.Toplevel, b: Compositor.Toplevel, x: f64, y: f64) bool {
    const seam = horizontalSeam(a.target, b.target) orelse return false;
    if (@abs(y - seam) > tile_gap_slop) return false;
    return rangeContains(a.target.x, a.target.width, b.target.x, b.target.width, x);
}

fn verticalSeam(a: strip.Geometry, b: strip.Geometry) ?f64 {
    const a_right = @as(f64, @floatFromInt(a.x + a.width));
    const b_left = @as(f64, @floatFromInt(b.x));
    if (@abs(a_right - b_left) <= 1) return a_right;
    const b_right = @as(f64, @floatFromInt(b.x + b.width));
    const a_left = @as(f64, @floatFromInt(a.x));
    if (@abs(b_right - a_left) <= 1) return b_right;
    return null;
}

fn horizontalSeam(a: strip.Geometry, b: strip.Geometry) ?f64 {
    const a_bottom = @as(f64, @floatFromInt(a.y + a.height));
    const b_top = @as(f64, @floatFromInt(b.y));
    if (@abs(a_bottom - b_top) <= 1) return a_bottom;
    const b_bottom = @as(f64, @floatFromInt(b.y + b.height));
    const a_top = @as(f64, @floatFromInt(a.y));
    if (@abs(b_bottom - a_top) <= 1) return b_bottom;
    return null;
}

fn rangeContains(a_origin: i32, a_span: i32, b_origin: i32, b_span: i32, value: f64) bool {
    const start = @as(f64, @floatFromInt(@max(a_origin, b_origin)));
    const end = @as(f64, @floatFromInt(@min(a_origin + a_span, b_origin + b_span)));
    return value >= start and value < end;
}

fn distanceToRect(entry: Compositor.Toplevel, x: f64, y: f64) f64 {
    const left = @as(f64, @floatFromInt(entry.target.x));
    const top = @as(f64, @floatFromInt(entry.target.y));
    const right = @as(f64, @floatFromInt(entry.target.x + entry.target.width));
    const bottom = @as(f64, @floatFromInt(entry.target.y + entry.target.height));
    const dx = if (x < left) left - x else if (x >= right) x - right else 0;
    const dy = if (y < top) top - y else if (y >= bottom) y - bottom else 0;
    return std.math.hypot(dx, dy);
}

fn adjacentIndex(current: usize, count: usize, direction: gesture.Direction) usize {
    if (count == 0) return 0;
    return switch (direction) {
        .left => @min(current + 1, count - 1),
        .right => current -| 1,
        else => current,
    };
}

fn shouldCommitDrag(progress: f64) bool {
    return std.math.isFinite(progress) and progress >= 0.35;
}

fn sliceForDirection(direction: gesture.Direction) u8 {
    return switch (direction) {
        .up => 0,
        .right => 1,
        .down => 2,
        .left => 3,
    };
}

/// Frame callback from backend output
fn outputFrameCallback(userdata: ?*anyopaque) void {
    const output: *Output = @ptrCast(@alignCast(userdata orelse return));
    output.compositor.painting_log = true;
    defer output.compositor.painting_log = false;

    output.compositor.logger.debug("Compositor: Frame callback triggered for output {s}", .{output.name});

    const now = monotonicNs();
    const dt = frameDelta(output.compositor.last_frame_ns, now);
    output.compositor.last_frame_ns = now;
    const moving = output.compositor.tickLayout(dt);

    output.render() catch |err| {
        output.compositor.logger.err("Compositor: Failed to render frame on output {s}: {}", .{ output.name, err });
    };
    if (moving) output.scheduleFrame();
}

fn outputDestroyCallback(userdata: ?*anyopaque) void {
    const output: *Output = @ptrCast(@alignCast(userdata orelse return));
    output.compositor.destroyOutput(output);
}

fn outputConfigureCallback(userdata: ?*anyopaque, width: i32, height: i32, scale: f32) void {
    const output: *Output = @ptrCast(@alignCast(userdata orelse return));
    if (!output.applyGeometry(width, height, scale)) return;
    output.compositor.logger.info(
        "Output {s}: host configure {}x{} @{d:.2}",
        .{ output.name, output.logical_width, output.logical_height, output.fractional_scale },
    );
    output.compositor.announceGeometry();
    output.compositor.relayoutToplevels();
}

const TeardownProbe = struct {
    allocator: std.mem.Allocator,
    destroyed: *bool,
};

fn destroyTeardownProbe(resource: ?*wayland.c.wl_resource) callconv(.c) void {
    const probe: *TeardownProbe = @ptrCast(@alignCast(
        wayland.c.wl_resource_get_user_data(resource),
    ));
    probe.destroyed.* = true;
    probe.allocator.destroy(probe);
}

fn ignoreConfigure(_: *anyopaque, _: i32, _: i32, _: u32) void {}

// Tests
const testing = core.testing;

/// Test fixture for setting up compositor test environment
const TestFixture = struct {
    allocator: std.mem.Allocator,
    runtime: wayland.test_setup.RuntimeDir,
    server: wayland.Server,
    logger: cli.Logger,
    compositor: *Compositor,

    fn setup(allocator: std.mem.Allocator) !*TestFixture {
        var runtime = try wayland.test_setup.RuntimeDir.setup(allocator);
        errdefer runtime.cleanup();

        var server = try wayland.Server.init(allocator, null);
        errdefer server.deinit();

        const fixture = try allocator.create(TestFixture);
        errdefer allocator.destroy(fixture);
        fixture.* = .{
            .allocator = allocator,
            .runtime = runtime,
            .server = server,
            .logger = cli.Logger.init(allocator),
            .compositor = undefined,
        };

        fixture.logger.setLogLevel(.err); // Disable debug/info/warn logging in tests
        fixture.logger.setEnableStdout(false);
        errdefer fixture.logger.deinit();

        fixture.compositor = try Compositor.init(allocator, &fixture.server, &fixture.logger);
        errdefer fixture.compositor.deinit();

        return fixture;
    }

    fn cleanup(self: *TestFixture) void {
        self.compositor.deinit();
        self.logger.deinit();
        self.server.deinit();
        self.runtime.cleanup();
        self.allocator.destroy(self);
    }
};

test "Compositor - init and deinit" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    try testing.expectEqual(@as(u32, 1), fixture.compositor.next_surface_id);
    try testing.expectEqual(@as(usize, 0), fixture.compositor.surfaces.items.len);
    try testing.expectNull(fixture.compositor.coordinator);
}

fn testSessionFactory(alloc: std.mem.Allocator) !*backend.session.Type {
    return backend.session.Type.init(alloc);
}

fn testCoordinatorWithSession() !*backend.Coordinator {
    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    return backend.Coordinator.create(testing.allocator, &backends, .{
        .physical_input = true,
        .session_factory = testSessionFactory,
    });
}

test "Compositor - attachBackend with no implementations leaves no event sources" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    const backends = [_]backend.ImplementationOptions{
        .{ .backend_type = .null, .request_mode = .if_available },
    };
    var coordinator = try backend.Coordinator.create(testing.allocator, &backends, .{});
    defer coordinator.deinit();

    try fixture.compositor.attachBackend(coordinator);
    defer fixture.compositor.detachBackend();
    try testing.expect(fixture.compositor.coordinator != null);
    try testing.expectEqual(@as(usize, 0), fixture.compositor.session_event_sources.items.len);
}

test "Compositor - attachBackend and detachBackend install and remove session listeners" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var coordinator = try testCoordinatorWithSession();
    defer coordinator.deinit();

    try fixture.compositor.attachBackend(coordinator);
    defer fixture.compositor.detachBackend();
    try testing.expect(fixture.compositor.session_input_listener != null);
    try testing.expect(fixture.compositor.session_device_change_listener != null);
    if (comptime hasSeatLifecycleSignals()) {
        try testing.expect(fixture.compositor.session_seat_disable_listener != null);
        try testing.expect(fixture.compositor.session_seat_enable_listener != null);
    }

    fixture.compositor.detachBackend();
    try testing.expect(fixture.compositor.session_input_listener == null);
    try testing.expect(fixture.compositor.session_device_change_listener == null);
    try testing.expect(fixture.compositor.session_seat_disable_listener == null);
    try testing.expect(fixture.compositor.session_seat_enable_listener == null);
    try testing.expectEqual(@as(usize, 0), fixture.compositor.session_event_sources.items.len);
}

fn markProbeFlag(userdata: ?*anyopaque) void {
    const flag: *bool = @ptrCast(@alignCast(userdata orelse return));
    flag.* = true;
}

fn emitDummyHotplug(sess: *backend.session.Type) void {
    sess.signal_device_change.emit(.{
        .event_type = .hotplug,
        .hotplug = .{ .connector_id = 0, .prop_id = 0 },
    });
}

test "Compositor - dummy device_change does not change outputs" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var coordinator = try testCoordinatorWithSession();
    defer coordinator.deinit();

    try fixture.compositor.attachBackend(coordinator);
    defer fixture.compositor.detachBackend();
    const before = fixture.compositor.outputs.items.len;
    const sess = coordinator.session orelse return error.TestUnexpectedResult;
    emitDummyHotplug(sess);
    try testing.expectEqual(before, fixture.compositor.outputs.items.len);
}

test "Compositor - detachBackend clears backend output callbacks" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var coordinator = try testCoordinatorWithSession();
    defer coordinator.deinit();
    try fixture.compositor.attachBackend(coordinator);

    var be = try backend.drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", null, null);
    defer be.deinit();
    var connector = backend.drm.Connector{
        .id = 1,
        .name = "eDP-1",
        .type = 0,
        .type_id = 1,
        .status = .connected,
        .modes = std.ArrayList(backend.output.Mode).empty,
        .allocator = testing.allocator,
        .be = be,
    };
    const drm_output = try backend.drm.Output.create(testing.allocator, be, &connector);
    defer drm_output.deinit();
    _ = try fixture.compositor.createOutput(drm_output.iface(), drm_output.name);

    var fired = false;
    drm_output.setFrameCallback(markProbeFlag, &fired);
    drm_output.setDestroyCallback(markProbeFlag, &fired);
    fixture.compositor.detachBackend();
    drm_output.invokeFrame();
    try testing.expect(drm_output.iface().destroy());
    try testing.expect(!fired);
}

test "Compositor - device_change rescans DRM without duplicating outputs" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var coordinator = try testCoordinatorWithSession();
    defer coordinator.deinit();
    const be = try backend.drm.Backend.fromGpu(testing.allocator, "/dev/dri/card0", coordinator, null);
    try coordinator.implementations.append(testing.allocator, be.asInterface());
    var crtc = backend.drm.CRTC{ .id = 1, .legacy_crtc_idx = 0, .allocator = testing.allocator };
    var connector = backend.drm.Connector{
        .id = 4,
        .name = "DP-1",
        .type = 0,
        .type_id = 1,
        .status = .connected,
        .modes = std.ArrayList(backend.output.Mode).empty,
        .crtc = &crtc,
        .allocator = testing.allocator,
        .be = be,
    };
    try be.connectors.append(be.allocator, &connector);
    defer be.connectors.clearRetainingCapacity();

    try fixture.compositor.attachBackend(coordinator);
    defer fixture.compositor.detachBackend();
    try testing.expect(!fixture.compositor.onscreen_log);
    const sess = coordinator.session orelse return error.TestUnexpectedResult;
    emitDummyHotplug(sess);
    try testing.expectEqual(@as(usize, 1), fixture.compositor.outputs.items.len);
    emitDummyHotplug(sess);
    try testing.expectEqual(@as(usize, 1), fixture.compositor.outputs.items.len);

    connector.status = .disconnected;
    emitDummyHotplug(sess);
    try testing.expectEqual(@as(usize, 0), fixture.compositor.outputs.items.len);
    try testing.expectEqual(@as(usize, 0), be.outputs.items.len);
}

test "Compositor - seat disable and enable toggle coordinator session_paused" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var coordinator = try testCoordinatorWithSession();
    defer coordinator.deinit();

    try fixture.compositor.attachBackend(coordinator);
    defer fixture.compositor.detachBackend();
    if (comptime hasSeatLifecycleSignals()) {
        const sess = coordinator.session orelse return error.TestUnexpectedResult;
        sess.signal_seat_disable.emit({});
        try testing.expect(coordinator.session_paused);
        sess.signal_seat_enable.emit({});
        try testing.expectFalse(coordinator.session_paused);
    } else {
        coordinator.pausePhysicalSession();
        try testing.expect(coordinator.session_paused);
        coordinator.resumePhysicalSession();
        try testing.expectFalse(coordinator.session_paused);
    }
}

test "Compositor - create and destroy surface" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    const surface = try fixture.compositor.createSurface();
    try testing.expectEqual(@as(usize, 1), fixture.compositor.surfaces.items.len);
    try testing.expectEqual(@as(u32, 1), surface.id);

    fixture.compositor.destroySurface(surface, "test teardown");
    try testing.expectEqual(@as(usize, 0), fixture.compositor.surfaces.items.len);
}

test "Compositor - multiple surfaces" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    const s1 = try fixture.compositor.createSurface();
    const s2 = try fixture.compositor.createSurface();
    const s3 = try fixture.compositor.createSurface();

    try testing.expectEqual(@as(usize, 3), fixture.compositor.surfaces.items.len);
    try testing.expectEqual(@as(u32, 1), s1.id);
    try testing.expectEqual(@as(u32, 2), s2.id);
    try testing.expectEqual(@as(u32, 3), s3.id);
}

test "Compositor - activation tokens are single use" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    const surface = try fixture.compositor.createSurface();
    const token = try fixture.compositor.issueActivationToken();
    fixture.compositor.activateWithToken(token, surface);
    try testing.expectEqual(@as(?*Surface, surface), fixture.compositor.seat.keyboard_focus);

    const other = try fixture.compositor.createSurface();
    fixture.compositor.activateWithToken(token, other);
    try testing.expectEqual(@as(?*Surface, surface), fixture.compositor.seat.keyboard_focus);
}

test "Compositor - adjacent column direction clamps at strip edges" {
    try testing.expectEqual(@as(usize, 1), adjacentIndex(0, 3, .left));
    try testing.expectEqual(@as(usize, 2), adjacentIndex(2, 3, .left));
    try testing.expectEqual(@as(usize, 1), adjacentIndex(2, 3, .right));
    try testing.expectEqual(@as(usize, 0), adjacentIndex(0, 3, .right));
    try testing.expectEqual(@as(usize, 1), adjacentIndex(1, 3, .up));
    try testing.expectEqual(@as(usize, 0), adjacentIndex(0, 0, .left));
}

test "Compositor - column drag commits at threshold" {
    try testing.expectFalse(shouldCommitDrag(0.3499));
    try testing.expect(shouldCommitDrag(0.35));
    try testing.expect(shouldCommitDrag(1));
    try testing.expectFalse(shouldCommitDrag(std.math.nan(f64)));
}

test "Compositor - horizontal flick switches adjacent column" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    try testing.expectEqual(@as(?usize, 1), fixture.compositor.focused_column);

    fixture.compositor.handleFlick(.right);
    try testing.expectEqual(@as(?usize, 0), fixture.compositor.focused_column);
    try testing.expectEqual(@as(?*Surface, first), fixture.compositor.seat.keyboard_focus);
    fixture.compositor.handleFlick(.left);
    try testing.expectEqual(@as(?usize, 1), fixture.compositor.focused_column);
    try testing.expectEqual(@as(?*Surface, second), fixture.compositor.seat.keyboard_focus);
}

test "Compositor - pointer over tile gap is the strip seam" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    try testing.expectFalse(fixture.compositor.pointerOverTileGap());
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    fixture.compositor.toplevels.items[0].column_width = .half;
    fixture.compositor.toplevels.items[1].column_width = .half;
    fixture.compositor.focused_column = 0;
    fixture.compositor.relayoutToplevels();

    fixture.compositor.seat.pointer_x = 960;
    fixture.compositor.seat.pointer_y = 100;
    try testing.expect(fixture.compositor.pointerOverTileGap());
    fixture.compositor.seat.pointer_x = 10;
    fixture.compositor.seat.pointer_y = 10;
    try testing.expectFalse(fixture.compositor.pointerOverTileGap());
    fixture.compositor.seat.pointer_x = 4000;
    try testing.expectFalse(fixture.compositor.pointerOverTileGap());
}

test "Compositor - slow drag release navigates without click replay" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);

    fixture.compositor.seat.button(0, gesture.Button.middle, .pressed);
    fixture.compositor.seat.motionAbsolute(fixture.compositor.surfaces.items, 10, 120, 0);
    fixture.compositor.seat.button(400, gesture.Button.middle, .released);

    try testing.expectEqual(@as(?usize, 0), fixture.compositor.focused_column);
    try testing.expectEqual(@as(f64, 0), fixture.compositor.viewport_x);
    try testing.expectEqual(@as(?*Surface, first), fixture.compositor.seat.keyboard_focus);
}

test "Compositor - activation synchronizes viewport before focus history" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    try testing.expectEqual(@as(?usize, 1), fixture.compositor.focused_column);

    const token = try fixture.compositor.issueActivationToken();
    fixture.compositor.activateWithToken(token, first);
    try testing.expectEqual(@as(?usize, 0), fixture.compositor.focused_column);
    try testing.expectEqual(@as(f64, 0), fixture.compositor.viewport_x);
    try testing.expectEqual(@as(?*Surface, first), fixture.compositor.seat.keyboard_focus);
}

test "Compositor - unmap removes current focus and history entry" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    fixture.compositor.seat.activate(first);
    fixture.compositor.unmapToplevel(first);

    try testing.expectEqual(@as(?*Surface, second), fixture.compositor.seat.keyboard_focus);
    for (fixture.compositor.seat.focus_stack.entries.items) |entry|
        try testing.expect(entry != first);
}

test "Compositor - removing focused middle preserves history and synchronizes viewport" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const middle = try fixture.compositor.createSurface();
    const last = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(middle, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(last, &context, ignoreConfigure);
    fixture.compositor.focused_column = 1;
    fixture.compositor.relayoutToplevels();
    fixture.compositor.seat.activate(middle);

    fixture.compositor.unmapToplevel(middle);

    try testing.expectEqual(@as(?*Surface, last), fixture.compositor.seat.keyboard_focus);
    try testing.expectEqual(@as(?usize, 1), fixture.compositor.focused_column);
    try testing.expectEqual(@as(f64, 1920), fixture.compositor.viewport_x);
    fixture.compositor.seat.back();
    try testing.expectEqual(@as(?*Surface, first), fixture.compositor.seat.keyboard_focus);
    fixture.compositor.seat.forward();
    try testing.expectEqual(@as(?*Surface, last), fixture.compositor.seat.keyboard_focus);
}

test "Compositor - edge drags clamp and cancel without history mutation" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    const history_len = fixture.compositor.seat.focus_stack.entries.items.len;

    fixture.compositor.updateColumnDrag(.{
        .time_usec = 1,
        .direction = .left,
        .progress = 1,
    });
    try testing.expectEqual(@as(f64, 0), fixture.compositor.viewport_x);
    fixture.compositor.finishGesture();
    try testing.expectEqual(@as(?usize, 0), fixture.compositor.focused_column);
    try testing.expectEqual(history_len, fixture.compositor.seat.focus_stack.entries.items.len);
}

test "Compositor - fallback ring hover activates and center release cancels" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    fixture.compositor.focused_column = 0;

    fixture.compositor.openFallbackRing(.{ .x = 100, .y = 100 });
    fixture.compositor.hoverFallbackRing(.{ .x = 172, .y = 100 });
    try testing.expectEqual(@as(?u8, 1), fixture.compositor.fallback_ring.?.hover);
    fixture.compositor.finishGesture();
    try testing.expectEqual(@as(?usize, 1), fixture.compositor.focused_column);
    try testing.expectNull(fixture.compositor.fallback_ring);

    fixture.compositor.openFallbackRing(.{ .x = 100, .y = 100 });
    fixture.compositor.hoverFallbackRing(.{ .x = 100, .y = 100 });
    fixture.compositor.finishGesture();
    try testing.expectEqual(@as(?usize, 1), fixture.compositor.focused_column);
}

test "Compositor - fallback close action sends close without unmapping" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    const Probe = struct {
        var close_count: usize = 0;
        fn close(_: *anyopaque) void {
            close_count += 1;
        }
    };
    Probe.close_count = 0;
    surface.close_context = &context;
    surface.close_handler = Probe.close;
    const ring = fixture.compositor.captureFallbackRing(.{});
    fixture.compositor.activateFallbackSlice(ring, 2);

    try testing.expectEqual(@as(usize, 1), Probe.close_count);
    try testing.expectEqual(@as(usize, 1), fixture.compositor.toplevels.items.len);
    try testing.expectEqual(@as(?*Surface, surface), fixture.compositor.seat.keyboard_focus);
}

test "Compositor - vertical flick maps to frozen close target" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    const Probe = struct {
        var closed: ?*Surface = null;
        fn close(userdata: *anyopaque) void {
            closed = @ptrCast(@alignCast(userdata));
        }
    };
    Probe.closed = null;
    first.close_context = first;
    first.close_handler = Probe.close;
    fixture.compositor.seat.pointer_focus = first;
    const ring = fixture.compositor.captureFallbackRing(.{});
    fixture.compositor.seat.pointer_focus = second;
    fixture.compositor.activateFallbackSlice(ring, sliceForDirection(.down));

    try testing.expectEqual(@as(?*Surface, first), Probe.closed);
    try testing.expectEqual(@as(u8, 0), sliceForDirection(.up));
}

test "Compositor - viewport and columns follow output geometry" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var hosted: Output = undefined;
    hosted.logical_x = 0;
    hosted.logical_y = 0;
    hosted.logical_width = 1280;
    hosted.logical_height = 800;
    hosted.fractional_scale = 1.5;
    try fixture.compositor.outputs.append(testing.allocator, &hosted);
    defer fixture.compositor.outputs.clearRetainingCapacity();

    try testing.expectEqual(@as(i32, 1280), fixture.compositor.viewportSize().width);
    try testing.expectEqual(@as(i32, 800), fixture.compositor.viewportSize().height);
    const point = fixture.compositor.clampPointer(4000, -10);
    try testing.expectEqual(@as(f64, 1279), point.x);
    try testing.expectEqual(@as(f64, 0), point.y);
    try testing.expectEqual(@as(i32, 1280), strip.Width.full.pixels(hosted.logical_width));
    fixture.compositor.announceGeometry();
}

test "Compositor - single toplevel fills the default viewport" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    try testing.expectEqual(@as(i32, 1920), fixture.compositor.toplevels.items[0].width);
    try testing.expectEqual(@as(i32, 1080), fixture.compositor.toplevels.items[0].height);
}

test "Compositor - fallback ring captures owning output" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var first: Output = undefined;
    first.logical_x = 0;
    first.logical_y = 0;
    first.logical_width = 1920;
    first.logical_height = 1080;
    var second: Output = undefined;
    second.logical_x = 1920;
    second.logical_y = 0;
    second.logical_width = 1920;
    second.logical_height = 1080;
    try fixture.compositor.outputs.append(testing.allocator, &first);
    try fixture.compositor.outputs.append(testing.allocator, &second);
    defer fixture.compositor.outputs.clearRetainingCapacity();

    const ring = fixture.compositor.captureFallbackRing(.{ .x = 2000, .y = 100 });
    try testing.expectEqual(@as(?*Output, &second), ring.output);
}

test "Compositor - grab callbacks pause and resume constraint streams" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const Probe = struct {
        var transitions: [2]bool = undefined;
        var count: usize = 0;
        fn changed(_: ?*anyopaque, constraints: bool, relative: bool) void {
            transitions[count] = constraints and relative;
            count += 1;
        }
    };
    Probe.count = 0;
    fixture.compositor.setInputSuspensionHandler(null, Probe.changed);

    fixture.compositor.seat.button(0, gesture.Button.middle, .pressed);
    fixture.compositor.seat.motionAbsolute(&.{}, 301, 120, 0);
    try testing.expect(fixture.compositor.pointer_constraints_suspended);
    try testing.expect(fixture.compositor.relative_pointer_suspended);
    fixture.compositor.seat.button(302, gesture.Button.middle, .released);

    try testing.expectFalse(fixture.compositor.pointer_constraints_suspended);
    try testing.expectFalse(fixture.compositor.relative_pointer_suspended);
    try testing.expectEqual(@as(usize, 2), Probe.count);
    try testing.expectEqualSlices(bool, &.{ true, false }, &Probe.transitions);
}

test "Compositor - accelerator ring dismisses idle shell click without replay" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    const focus = fixture.compositor.seat.keyboard_focus;
    fixture.compositor.seat.pointer_focus = second;
    fixture.compositor.seat.pointer_x = 80;
    fixture.compositor.seat.pointer_y = 80;
    fixture.compositor.seat.ring_focus_visible = true;

    fixture.compositor.handleGesture(.{ .hold = .{
        .time_usec = 1,
        .point = .{ .x = 0, .y = 0 },
    } });
    try testing.expect(fixture.compositor.fallback_ring != null);
    try testing.expect(fixture.compositor.seat.grab.active);
    try testing.expectFalse(fixture.compositor.seat.mouse.recognizer.active());

    fixture.compositor.seat.button(10, gesture.Button.middle, .pressed);
    fixture.compositor.seat.button(11, gesture.Button.middle, .released);

    try testing.expectNull(fixture.compositor.fallback_ring);
    try testing.expectFalse(fixture.compositor.seat.grab.active);
    try testing.expectEqual(focus, fixture.compositor.seat.keyboard_focus);
    try testing.expectEqual(@as(?*Surface, second), focus);
}

test "Compositor - accelerator hold uses pointer position" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    fixture.compositor.seat.pointer_x = 250;
    fixture.compositor.seat.pointer_y = 80;
    fixture.compositor.seat.ring_focus_visible = true;
    fixture.compositor.handleGesture(.{ .hold = .{
        .time_usec = 1,
        .point = .{ .x = 0, .y = 0 },
    } });
    try testing.expectEqual(@as(f64, 250), fixture.compositor.fallback_ring.?.center.x);
    try testing.expectEqual(@as(f64, 80), fixture.compositor.fallback_ring.?.center.y);
    try testing.expect(fixture.compositor.fallback_ring.?.focus_visible);
    try testing.expect(fixture.compositor.seat.grab.active);
}

test "Compositor - hold opens the fallback ring" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    fixture.compositor.handleGesture(.{ .hold = .{
        .time_usec = 400_000,
        .point = .{ .x = 100, .y = 100 },
    } });
    try testing.expect(fixture.compositor.fallback_ring != null);
    try testing.expectEqual(@as(f64, 100), fixture.compositor.fallback_ring.?.center.x);
    try testing.expect(fixture.compositor.seat.grab.active);
}

test "Compositor - middle hold summons without replaying to the client" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    const focus = fixture.compositor.seat.keyboard_focus;
    fixture.compositor.seat.pointer_focus = second;
    fixture.compositor.seat.pointer_x = 80;
    fixture.compositor.seat.pointer_y = 80;

    fixture.compositor.seat.button(0, gesture.Button.middle, .pressed);
    try testing.expect(fixture.compositor.seat.mouse.recognizer.active());
    try testing.expectEqual(focus, fixture.compositor.seat.keyboard_focus);
    try testing.expectEqual(@as(?*Surface, second), fixture.compositor.seat.deferred_target);

    const translated = try fixture.compositor.seat.mouse.tick(250_000);
    fixture.compositor.handleGesture(translated.primitive.?);
    try testing.expect(fixture.compositor.fallback_ring != null);
    try testing.expect(fixture.compositor.seat.overlay_held);
    try testing.expectEqual(focus, fixture.compositor.seat.keyboard_focus);

    fixture.compositor.seat.button(500, gesture.Button.middle, .released);
    try testing.expectEqual(focus, fixture.compositor.seat.keyboard_focus);
    try testing.expectNull(fixture.compositor.seat.deferred_target);
}

test "Compositor - shell attach without a ring overlay still opens fallback" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    try sideswipe_shell.register(fixture.compositor);
    fixture.compositor.handleGesture(.{ .hold = .{
        .time_usec = 400_000,
        .point = .{ .x = 100, .y = 100 },
    } });
    try testing.expect(fixture.compositor.fallback_ring != null);
    try testing.expect(!sideswipe_shell.ringReplaced(fixture.compositor));
}

test "Compositor - slice release activates while a shell ring overlay is mapped" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    try sideswipe_shell.register(fixture.compositor);
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    fixture.compositor.focused_column = 0;
    const overlay = try fixture.compositor.createSurface();
    overlay.mapped = true;
    overlay.scene_geometry = .{ .x = 0, .y = 0, .width = 200, .height = 200 };
    fixture.compositor.shell.?.overlays[0] = overlay;
    fixture.compositor.shell.?.replaced_ring = true;

    fixture.compositor.openFallbackRing(.{ .x = 100, .y = 100 });
    fixture.compositor.hoverFallbackRing(.{ .x = 172, .y = 100 });
    try testing.expect(sideswipe_shell.ringReplaced(fixture.compositor));
    fixture.compositor.finishGesture();
    try testing.expectEqual(@as(?usize, 1), fixture.compositor.focused_column);
}

test "Compositor - wheel notch zooms the column at a tile gap" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    fixture.compositor.toplevels.items[0].column_width = .half;
    fixture.compositor.toplevels.items[1].column_width = .half;
    fixture.compositor.focused_column = 0;
    fixture.compositor.relayoutToplevels();
    fixture.compositor.seat.pointer_x = 960;
    fixture.compositor.seat.pointer_y = 100;
    try testing.expect(fixture.compositor.pointerOverTileGap());

    const evdev_left_ctrl: u32 = 29;
    _ = fixture.compositor.seat.key(1, evdev_left_ctrl, .pressed);
    fixture.compositor.seat.axis(2, .wheel, .vertical, 15, 0, true);
    try testing.expectEqual(strip.Width.half.adjust(1), fixture.compositor.toplevels.items[1].column_width);

    fixture.compositor.seat.axis(3, .wheel, .vertical, 7, 0, true);
    try testing.expectEqual(strip.Width.half.adjust(1), fixture.compositor.toplevels.items[1].column_width);
}

test "Compositor - zoom steps the hovered column width" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    fixture.compositor.toplevels.items[0].column_width = .half;
    fixture.compositor.relayoutToplevels();
    fixture.compositor.seat.pointer_x = 10;
    fixture.compositor.seat.pointer_y = 10;

    fixture.compositor.handleGesture(.{ .zoom = .{ .time_usec = 1, .delta = 120 } });
    try testing.expectEqual(strip.Width.half.adjust(1), fixture.compositor.toplevels.items[0].column_width);
    fixture.compositor.handleGesture(.{ .zoom = .{ .time_usec = 2, .delta = -240 } });
    try testing.expectEqual(strip.Width.half.adjust(1).adjust(-2), fixture.compositor.toplevels.items[0].column_width);
}

test "Compositor - overlay grab owns pointer buttons and Escape" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    const focus = fixture.compositor.seat.keyboard_focus;

    fixture.compositor.handleGesture(.{ .hold = .{
        .time_usec = 400_000,
        .point = .{ .x = 80, .y = 80 },
    } });
    try testing.expect(fixture.compositor.seat.grab.active);
    fixture.compositor.seat.button(1, gesture.Button.middle, .pressed);
    try testing.expectEqual(focus, fixture.compositor.seat.keyboard_focus);

    fixture.compositor.seat.button(2, gesture.Button.back, .pressed);
    try testing.expectNull(fixture.compositor.fallback_ring);
    try testing.expectEqual(focus, fixture.compositor.seat.keyboard_focus);
    try testing.expectEqual(@as(?*Surface, second), focus);
}

test "Compositor - Escape closes overlay without popping focus" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);

    fixture.compositor.handleGesture(.{ .hold = .{
        .time_usec = 400_000,
        .point = .{ .x = 80, .y = 80 },
    } });
    _ = fixture.compositor.seat.key(1, 1, .pressed);
    try testing.expectNull(fixture.compositor.fallback_ring);
    try testing.expectEqual(@as(?*Surface, second), fixture.compositor.seat.keyboard_focus);
}

test "Compositor - extra press does not start the default shell gesture" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var extra = backend.input.Device{
        .name = "extra",
        .sysname = "event0",
        .vendor = 1,
        .product = 1,
        .has_extra_button = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };
    fixture.compositor.dispatchRuntimeInput(.{ .device_added = .{ .device = &extra } });
    fixture.compositor.dispatchRuntimeInput(.{ .pointer_button = .{
        .device = &extra,
        .time_usec = 1_000,
        .button = gesture.Button.extra,
        .state = .pressed,
    } });
    try testing.expectFalse(fixture.compositor.seat.mouse.recognizer.active());
    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
}

test "Compositor - middle press starts the shell gesture and side does not" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var device = backend.input.Device{
        .name = "mouse",
        .sysname = "event0",
        .vendor = 1,
        .product = 1,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    fixture.compositor.dispatchRuntimeInput(.{ .pointer_button = .{
        .device = &device,
        .time_usec = 1_000,
        .button = gesture.Button.side,
        .state = .pressed,
    } });
    try testing.expectFalse(fixture.compositor.seat.mouse.recognizer.active());

    fixture.compositor.dispatchRuntimeInput(.{ .pointer_button = .{
        .device = &device,
        .time_usec = 2_000,
        .button = gesture.Button.middle,
        .state = .pressed,
    } });
    try testing.expect(fixture.compositor.seat.mouse.recognizer.active());
}

test "Compositor - Super+Shift+Q is a session quit chord" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var device = backend.input.Device{
        .name = "keyboard",
        .sysname = "event1",
        .vendor = 1,
        .product = 2,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    fixture.compositor.dispatchRuntimeInput(.{ .keyboard_key = .{
        .device = &device,
        .time_usec = 1_000,
        .key = 125,
        .state = .pressed,
    } });
    fixture.compositor.dispatchRuntimeInput(.{ .keyboard_key = .{
        .device = &device,
        .time_usec = 2_000,
        .key = 42,
        .state = .pressed,
    } });
    try testing.expectEqual(seat_mod.KeyResult.quit, fixture.compositor.seat.key(3, 16, .pressed));
}

test "Compositor - runtime device capabilities keep middle as the shell button" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var extra = backend.input.Device{
        .name = "extra",
        .sysname = "event0",
        .vendor = 1,
        .product = 1,
        .has_extra_button = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };
    var side = backend.input.Device{
        .name = "side",
        .sysname = "event1",
        .vendor = 1,
        .product = 2,
        .has_side_button = true,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };

    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
    fixture.compositor.dispatchRuntimeInput(.{ .device_added = .{ .device = &extra } });
    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
    fixture.compositor.dispatchRuntimeInput(.{ .device_added = .{ .device = &side } });
    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
    fixture.compositor.dispatchRuntimeInput(.{ .device_removed = .{ .device = &side } });
    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
    fixture.compositor.dispatchRuntimeInput(.{ .device_removed = .{ .device = &extra } });
    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
}

test "Compositor - runtime observer receives gesture tablet switch and touch frame" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    var device = backend.input.Device{
        .name = "combo",
        .sysname = "event0",
        .vendor = 1,
        .product = 2,
        .libinput_device = undefined,
        .allocator = testing.allocator,
    };
    const Probe = struct {
        var count: usize = 0;
        var last_time: u64 = 0;

        fn event(_: ?*anyopaque, input_event: backend.input.Event) void {
            count += 1;
            last_time = switch (input_event) {
                .gesture_hold_begin => |value| value.time_usec,
                .tablet_pad_button => |value| value.time_usec,
                .switch_toggle => |value| value.time_usec,
                .touch_frame => |value| value.time_usec,
                else => last_time,
            };
        }
    };
    Probe.count = 0;
    Probe.last_time = 0;
    fixture.compositor.setRuntimeEventHandler(null, Probe.event);
    fixture.compositor.dispatchRuntimeInput(.{ .gesture_hold_begin = .{
        .device = &device,
        .time_usec = 10,
        .fingers = 3,
        .cancelled = false,
    } });
    fixture.compositor.dispatchRuntimeInput(.{ .tablet_pad_button = .{
        .device = &device,
        .time_usec = 11,
        .button = 1,
        .state = .pressed,
    } });
    fixture.compositor.dispatchRuntimeInput(.{ .switch_toggle = .{
        .device = &device,
        .time_usec = 12,
        .switch_kind = .lid,
        .state = .on,
    } });
    fixture.compositor.dispatchRuntimeInput(.{ .touch_frame = .{
        .device = &device,
        .time_usec = 13,
    } });
    try testing.expectEqual(@as(usize, 4), Probe.count);
    try testing.expectEqual(@as(u64, 13), Probe.last_time);
}

test "Compositor - connected client callbacks finish before teardown" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
        return error.SocketPairFailed;
    defer core.unix.close(fds[1]);
    const client = wayland.c.wl_client_create(fixture.server.getDisplay(), fds[0]) orelse
        return error.ClientCreateFailed;
    const resource = wayland.c.wl_resource_create(
        client,
        &wayland.c.wl_callback_interface,
        1,
        1,
    ) orelse return error.ResourceCreateFailed;
    var destroyed = false;
    const probe = try testing.allocator.create(TeardownProbe);
    probe.* = .{ .allocator = testing.allocator, .destroyed = &destroyed };
    wayland.c.wl_resource_set_implementation(resource, null, probe, destroyTeardownProbe);

    fixture.compositor.destroyClients();

    try testing.expect(destroyed);
}

test "Compositor - nested output close detaches compositor and backend ownership" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const options = [_]backend.ImplementationOptions{
        .{ .backend_type = .wayland, .request_mode = .if_available },
    };
    var coordinator = try backend.Coordinator.create(testing.allocator, &options, .{});
    defer coordinator.deinit();
    const nested = try backend.wayland.Backend.create(testing.allocator, coordinator);
    defer nested.deinit();
    const backend_output = try backend.wayland.Output.create(testing.allocator, "close-integration", nested);
    try nested.outputs.append(testing.allocator, backend_output);
    try nested.idle_callbacks.append(testing.allocator, backend_output);
    nested.focused_output = backend_output;
    nested.keyboard_focused_output = backend_output;
    const compositor_output = try fixture.compositor.createOutput(backend_output.iface(), backend_output.name);
    backend_output.setFrameCallback(outputFrameCallback, compositor_output);
    backend_output.setDestroyCallback(outputDestroyCallback, compositor_output);

    try testing.expect(backend_output.destroy());

    try testing.expectEqual(@as(usize, 0), fixture.compositor.outputs.items.len);
    try testing.expectEqual(@as(usize, 0), nested.outputs.items.len);
    try testing.expectEqual(@as(usize, 0), nested.idle_callbacks.items.len);
    try testing.expectNull(nested.focused_output);
    try testing.expectNull(nested.keyboard_focused_output);
}

test "Compositor - parented toplevel becomes a bottom sheet" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const parent = try fixture.compositor.createSurface();
    const child = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(parent, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(child, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(child, .{ .parent = parent });

    const parent_entry = fixture.compositor.findToplevel(parent).?;
    const child_entry = fixture.compositor.findToplevel(child).?;
    try testing.expectEqual(sheet.Kind.sheet, child_entry.kind);
    try testing.expectEqual(sheet.Kind.column, parent_entry.kind);
    try testing.expectEqual(@as(i32, 540), parent_entry.height);
    try testing.expectEqual(@as(i32, 540), child_entry.height);
    try testing.expectEqual(@as(i32, 540), child_entry.y);
    try testing.expectEqual(@as(?usize, 0), fixture.compositor.focused_column);
}

test "Compositor - fullscreen covers the output overlay" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const second = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(second, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(second, .{ .fullscreen = true });

    const overlay = fixture.compositor.findToplevel(second).?;
    try testing.expect(overlay.fullscreen);
    try testing.expectEqual(strip.Geometry{
        .x = 0,
        .y = 0,
        .width = 1920,
        .height = 1080,
    }, overlay.motion.targetGeometry());
    try testing.expectEqual(@as(?usize, 0), fixture.compositor.focused_column);
}

test "Compositor - maximized fills the current column" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(surface, .{ .maximized = true });
    const entry = fixture.compositor.findToplevel(surface).?;
    try testing.expect(entry.maximized);
    try testing.expectEqual(@as(i32, 1920), entry.width);
    try testing.expectEqual(@as(i32, 1080), entry.height);
}

test "Compositor - W7 override can force a sheet without set_parent" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    fixture.compositor.window_rules.deinit();
    fixture.compositor.window_rules = try overrides.parse(testing.allocator,
        \\[[window_rules]]
        \\app_id = "demo"
        \\placement = "sheet"
        \\ssd = true
    );
    const parent = try fixture.compositor.createSurface();
    const child = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(parent, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(child, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(child, .{ .app_id = "demo" });

    const child_entry = fixture.compositor.findToplevel(child).?;
    try testing.expectEqual(sheet.Kind.sheet, child_entry.kind);
    try testing.expect(child_entry.ssd);
    try testing.expectEqual(parent, child_entry.parent.?);
}

test "Compositor - layout tick snaps when no buffer is committed" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    const entry = fixture.compositor.findToplevel(surface).?;
    anim.retarget(&entry.motion, .{ .x = 0, .y = 0, .width = 400, .height = 300 });
    try testing.expect(!fixture.compositor.tickLayout(1.0 / 60.0));
    try testing.expectEqual(@as(i32, 400), entry.width);
    try testing.expectEqual(@as(i32, 300), entry.height);
}

test "Compositor - dialog without parent is a sheet on the focused column" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const focused = try fixture.compositor.createSurface();
    const dialog = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(focused, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(dialog, &context, ignoreConfigure);
    fixture.compositor.setToplevelDialog(dialog, true, false);

    const child = fixture.compositor.findToplevel(dialog).?;
    try testing.expectEqual(sheet.Kind.sheet, child.kind);
    try testing.expectEqual(focused, child.parent.?);
    try testing.expect(child.parent.? != first);
    try testing.expect(child.handle != null);
}

test "Compositor - lone dialog stays a column until a host exists" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const dialog = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(dialog, &context, ignoreConfigure);
    fixture.compositor.setToplevelDialog(dialog, true, false);

    const entry = fixture.compositor.findToplevel(dialog).?;
    try testing.expectEqual(sheet.Kind.column, entry.kind);
    try testing.expectEqual(@as(?*Surface, null), entry.parent);
    try testing.expectEqual(@as(i32, 1920), entry.width);
    try testing.expectEqual(@as(i32, 1080), entry.height);
}

test "Compositor - mapToplevelWithHints dialog attaches to the live focused column" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const first = try fixture.compositor.createSurface();
    const focused = try fixture.compositor.createSurface();
    const dialog = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(first, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(focused, &context, ignoreConfigure);
    fixture.compositor.mapToplevelWithHints(dialog, &context, ignoreConfigure, .{ .is_dialog = true });

    const child = fixture.compositor.findToplevel(dialog).?;
    try testing.expectEqual(sheet.Kind.sheet, child.kind);
    try testing.expectEqual(focused, child.parent.?);
}

test "Compositor - committed last size springs toward a new target" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const parent = try fixture.compositor.createSurface();
    const child = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(parent, &context, ignoreConfigure);
    parent.current.viewport.destination = .{ .width = 1920, .height = 1080 };
    fixture.compositor.mapToplevel(child, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(child, .{ .parent = parent });

    const parent_entry = fixture.compositor.findToplevel(parent).?;
    try testing.expectEqual(@as(i32, 540), parent_entry.motion.targetGeometry().height);
    try testing.expectEqual(@as(i32, 1080), parent_entry.height);
    try testing.expect(fixture.compositor.tickLayout(1.0 / 60.0));
    try testing.expect(parent_entry.height < 1080);
    try testing.expect(parent_entry.height > 540);
}

test "Compositor - closing a parent requests close on nested sheets" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const parent = try fixture.compositor.createSurface();
    const child = try fixture.compositor.createSurface();
    const nested = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(parent, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(child, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(nested, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(child, .{ .parent = parent });
    fixture.compositor.refreshToplevel(nested, .{ .parent = child });

    const Probe = struct {
        var count: usize = 0;
        fn close(_: *anyopaque) void {
            count += 1;
        }
    };
    Probe.count = 0;
    child.close_context = &context;
    child.close_handler = Probe.close;
    nested.close_context = &context;
    nested.close_handler = Probe.close;

    fixture.compositor.unmapToplevel(parent);
    try testing.expectEqual(@as(usize, 2), Probe.count);
    try testing.expectEqual(@as(usize, 2), fixture.compositor.toplevels.items.len);
    try testing.expect(fixture.compositor.findToplevel(child).?.closing);
    try testing.expect(fixture.compositor.findToplevel(nested).?.closing);
    try testing.expectNull(child.scene_geometry);
    try testing.expectNull(nested.scene_geometry);
}

test "Compositor - modal sheet blocks parent pointer and keyboard" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const parent = try fixture.compositor.createSurface();
    const sibling = try fixture.compositor.createSurface();
    const dialog = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(parent, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(sibling, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(dialog, &context, ignoreConfigure);
    parent.mapped = true;
    sibling.mapped = true;
    dialog.mapped = true;
    fixture.compositor.seat.pointer_x = 10;
    fixture.compositor.seat.pointer_y = 10;
    fixture.compositor.seat.pointer_focus = parent;
    fixture.compositor.refreshToplevel(dialog, .{ .parent = parent, .is_dialog = true, .modal = true });

    try testing.expect(parent.input_inert);
    try testing.expect(!sibling.input_inert);
    try testing.expect(!dialog.input_inert);
    try testing.expect(fixture.compositor.seat.pointer_focus != parent);

    const parent_hit = seat_mod.hitTest(&.{ parent, sibling, dialog }, 10, 10);
    try testing.expect(parent_hit == null or parent_hit.?.surface != parent);

    const focus = fixture.compositor.seat.keyboard_focus;
    fixture.compositor.seat.activate(parent);
    try testing.expectEqual(focus, fixture.compositor.seat.keyboard_focus);
    try testing.expect(fixture.compositor.seat.keyboard_focus != parent);

    fixture.compositor.seat.pointer_focus = parent;
    fixture.compositor.seat.button(1, 0x110, .pressed);
    try testing.expect(fixture.compositor.seat.pointer_focus != parent);
    try testing.expect(fixture.compositor.seat.keyboard_focus != parent);
}

test "Compositor - back exits the fullscreen overlay" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(surface, .{ .fullscreen = true });
    try testing.expect(fixture.compositor.findToplevel(surface).?.fullscreen);

    fixture.compositor.handleGesture(.{ .back = .{ .time_usec = 1 } });
    try testing.expect(!fixture.compositor.findToplevel(surface).?.fullscreen);
}

test "Compositor - nested sheet is placed on its parent sheet" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    const parent = try fixture.compositor.createSurface();
    const child = try fixture.compositor.createSurface();
    const nested = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(parent, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(child, &context, ignoreConfigure);
    fixture.compositor.mapToplevel(nested, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(child, .{ .parent = parent });
    fixture.compositor.refreshToplevel(nested, .{ .parent = child });

    const child_entry = fixture.compositor.findToplevel(child).?;
    const nested_entry = fixture.compositor.findToplevel(nested).?;
    try testing.expect(nested_entry.height > 0);
    try testing.expect(nested_entry.y >= child_entry.y);
    try testing.expectEqual(child_entry.x, nested_entry.x);
}

test "Compositor - W7 ssd false forces client decorations" {
    var fixture = try TestFixture.setup(testing.allocator);
    defer fixture.cleanup();
    fixture.compositor.window_rules.deinit();
    fixture.compositor.window_rules = try overrides.parse(testing.allocator,
        \\[[window_rules]]
        \\app_id = "demo"
        \\ssd = false
    );
    const surface = try fixture.compositor.createSurface();
    var context: u8 = 0;
    fixture.compositor.mapToplevel(surface, &context, ignoreConfigure);
    fixture.compositor.refreshToplevel(surface, .{ .app_id = "demo", .is_dialog = true });
    const entry = fixture.compositor.findToplevel(surface).?;
    try testing.expect(!entry.ssd);
    try testing.expectEqual(@as(?bool, false), entry.ssd_override);
}
