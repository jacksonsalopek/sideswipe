//! Main compositor state and management
//! Coordinates surfaces, backends, and protocol implementations

const std = @import("std");
const wayland = @import("wayland");
const backend = @import("backend");
const core = @import("core");
const cli = @import("core.cli");

const Surface = @import("surface.zig").Surface;
const Output = @import("output.zig").Type;
const Seat = @import("input/seat.zig").Type;
const gesture = @import("input/gesture.zig");
const ring_geometry = @import("ring_geometry.zig");
const strip = @import("layout/strip.zig");

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
    session_event_sources: std.ArrayList(*wayland.c.wl_event_source) = .empty,
    runtime_event_userdata: ?*anyopaque = null,
    runtime_event_handler: ?*const fn (?*anyopaque, backend.input.Event) void = null,
    side_button_devices: usize = 0,
    extra_button_devices: usize = 0,
    next_activation_token: u64 = 1,
    toplevels: std.ArrayList(Toplevel) = .empty,
    focused_column: ?usize = null,
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

    pub const Toplevel = struct {
        surface: *Surface,
        context: *anyopaque,
        configure: *const fn (*anyopaque, i32, i32, u32) void,
        x: i32 = 0,
        y: i32 = 0,
        width: i32 = 0,
        height: i32 = 0,
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
        if (self.session_input_listener) |*listener| listener.deinit();
        for (self.session_event_sources.items) |source| _ = wayland.c.wl_event_source_remove(source);
        self.session_event_sources.deinit(self.allocator);
        self.seat.deinit();
        self.activation_tokens.deinit();
        self.toplevels.deinit(self.allocator);
        self.output_binds.deinit(self.allocator);

        // Surface teardown may schedule repaint while destroying roles.
        for (self.surfaces.items) |surface| {
            surface.deinit();
        }
        self.surfaces.deinit(self.allocator);

        for (self.outputs.items) |output| {
            output.deinit();
        }
        self.outputs.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Attaches a backend coordinator to the compositor
    pub fn attachBackend(self: *Self, coord: *backend.Coordinator) Error!void {
        self.coordinator = coord;
        try self.attachSessionInput(coord);

        // Create compositor outputs from backend implementations
        for (coord.implementations.items) |impl| {
            if (impl.backendType() == .wayland) {
                try self.connectWaylandBackendOutputs(impl);
            }
        }
    }

    fn attachSessionInput(self: *Self, coord: *backend.Coordinator) Error!void {
        const session = coord.session orelse return;
        self.session_input_listener = session.signal_input_event.listen(runtimeInputEvent, self) catch
            return error.OutOfMemory;
        const event_loop = wayland.c.wl_display_get_event_loop(self.server.getDisplay()) orelse
            return error.EventLoopUnavailable;
        const fds = session.pollFds(self.allocator) catch return error.OutOfMemory;
        defer self.allocator.free(fds);
        for (fds) |fd| {
            const source = wayland.c.wl_event_loop_add_fd(
                event_loop,
                fd.fd,
                wayland.c.WL_EVENT_READABLE,
                sessionFdReady,
                session,
            ) orelse return error.EventLoopUnavailable;
            self.session_event_sources.append(self.allocator, source) catch {
                _ = wayland.c.wl_event_source_remove(source);
                return error.OutOfMemory;
            };
        }
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
        if (self.runtime_event_handler) |handler| handler(self.runtime_event_userdata, event);
        switch (event) {
            .device_added => |value| self.updateInputCapabilities(value.device, true),
            .device_removed => |value| self.updateInputCapabilities(value.device, false),
            .pointer_motion => |value| blk: {
                const point = self.clampPointer(
                    self.seat.pointer_x + value.delta_x,
                    self.seat.pointer_y + value.delta_y,
                );
                break :blk self.seat.motionAbsolute(
                    self.surfaces.items,
                    timestampMsec(value.time_usec),
                    point.x,
                    point.y,
                );
            },
            .pointer_motion_absolute => |value| self.seat.motionAbsolute(
                self.surfaces.items,
                timestampMsec(value.time_usec),
                value.x * @as(f64, @floatFromInt(self.viewportSize().width)),
                value.y * @as(f64, @floatFromInt(self.viewportSize().height)),
            ),
            .pointer_button => |value| self.seat.button(
                timestampMsec(value.time_usec),
                value.button,
                @enumFromInt(@intFromEnum(value.state)),
            ),
            .pointer_axis => |value| self.seat.axis(
                timestampMsec(value.time_usec),
                @enumFromInt(@intFromEnum(value.source)),
                @enumFromInt(@intFromEnum(value.axis)),
                value.value,
                value.value_discrete,
            ),
            .keyboard_key => |value| self.seat.key(
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
            else => {},
        }
    }

    fn updateInputCapabilities(self: *Self, device: *backend.input.Device, added: bool) void {
        if (device.has_side_button) updateCount(&self.side_button_devices, added);
        if (device.has_extra_button) updateCount(&self.extra_button_devices, added);
        self.seat.selectShellButton(self.side_button_devices > 0, self.extra_button_devices > 0);
    }

    fn connectWaylandBackendOutputs(self: *Self, impl: backend.Implementation) Error!void {
        const backend_ptr = impl.base.ptr;

        // Cast to Wayland Backend
        const wayland_backend = @import("backend").wayland.Backend;
        const wl_backend: *wayland_backend = @ptrCast(@alignCast(backend_ptr));
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

        self.logger.debug("About to register backend with event loop (backend_display={})", .{wl_backend.wayland_state.display != null});
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
    pub fn destroySurface(self: *Self, surface: *Surface, reason: []const u8) void {
        self.logger.debug("Destroyed surface {d}: {s}", .{ surface.id, reason });
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
        const c = @import("wayland").c;
        return c.wl_display_next_serial(self.server.getDisplay());
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
        for (self.toplevels.items) |entry| {
            if (entry.surface == surface) return;
        }
        self.toplevels.append(self.allocator, .{
            .surface = surface,
            .context = context,
            .configure = configure,
        }) catch return;
        self.focused_column = self.toplevels.items.len - 1;
        self.relayoutToplevels();
        self.seat.activate(surface);
    }

    pub fn unmapToplevel(self: *Self, surface: *Surface) void {
        for (self.toplevels.items, 0..) |entry, index| {
            if (entry.surface != surface) continue;
            if (self.fallback_ring) |ring| {
                if (ring.target_surface == surface) self.closeFallbackRing();
            }
            _ = self.toplevels.orderedRemove(index);
            self.adjustFocusedColumn(index);
            self.relayoutToplevels();
            self.seat.surfaceUnmapped(surface);
            return;
        }
        self.seat.surfaceUnmapped(surface);
    }

    fn relayoutToplevels(self: *Self) void {
        const viewport = self.viewportSize();
        const viewport_width = viewport.width;
        const viewport_height = viewport.height;
        const column_width = strip.Width.full.pixels(viewport_width);
        self.viewport_x = self.targetViewportX(column_width);
        for (self.toplevels.items, 0..) |*entry, index| {
            const serial = self.nextSerial();
            entry.x = @as(i32, @intCast(index)) * column_width -
                @as(i32, @intFromFloat(@round(self.viewport_x)));
            entry.y = 0;
            entry.width = column_width;
            entry.height = viewport_height;
            entry.surface.scene_geometry = .{
                .x = entry.x,
                .y = entry.y,
                .width = entry.width,
                .height = entry.height,
            };
            entry.configure(entry.context, column_width, viewport_height, serial);
        }
        self.scheduleFrame();
    }

    fn targetViewportX(self: *const Self, column_width: i32) f64 {
        const focused = self.focused_column orelse return 0;
        const base = @as(f64, @floatFromInt(focused)) * @as(f64, @floatFromInt(column_width));
        const direction = self.drag_direction orelse return base;
        if (adjacentIndex(focused, self.toplevels.items.len, direction) == focused) return base;
        const offset = self.drag_progress * @as(f64, @floatFromInt(column_width));
        return switch (direction) {
            .left => base + offset,
            .right => base - offset,
            else => base,
        };
    }

    fn adjustFocusedColumn(self: *Self, removed: usize) void {
        const focused = self.focused_column orelse return;
        if (self.toplevels.items.len == 0) {
            self.focused_column = null;
            return;
        }
        if (removed < focused or focused >= self.toplevels.items.len)
            self.focused_column = focused - 1;
    }

    fn handleGesture(self: *Self, primitive: gesture.Primitive) void {
        switch (primitive) {
            .hold => |event| self.openFallbackRing(event.point),
            .hover => |event| self.hoverFallbackRing(event.point),
            .drag => |event| self.updateColumnDrag(event),
            .flick => |event| self.handleFlick(event.direction),
            .release => self.finishGesture(),
            .back, .forward => {},
            .zoom => {},
        }
    }

    fn openFallbackRing(self: *Self, point: gesture.Point) void {
        self.fallback_ring = self.captureFallbackRing(point);
        self.renderFallbackRing();
    }

    fn captureFallbackRing(self: *Self, point: gesture.Point) FallbackRing {
        return .{
            .center = .{ .x = point.x, .y = point.y },
            .target_surface = self.contextualSurface(),
            .output = self.outputAt(point),
        };
    }

    fn hoverFallbackRing(self: *Self, point: gesture.Point) void {
        const ring = if (self.fallback_ring) |*active| active else return;
        ring.hover = ring_geometry.hit(.{}, ring.center, .{ .x = point.x, .y = point.y }, 4) catch null;
        self.renderFallbackRing();
    }

    fn renderFallbackRing(self: *Self) void {
        const ring = self.fallback_ring orelse return;
        const quads = ring_geometry.quadsWithSelection(
            .{},
            ring.center,
            4,
            .fallback,
            ring.hover,
            ring.focus_visible,
        ) catch return;
        for (self.outputs.items) |output| {
            if (output == ring.output) {
                output.scene.setShellQuads(self.allocator, quads.slice()) catch return;
            } else {
                output.scene.clearShellQuads();
            }
        }
        if (ring.output) |output| output.scheduleFrame();
    }

    fn closeFallbackRing(self: *Self) void {
        const owner = if (self.fallback_ring) |ring| ring.output else null;
        self.fallback_ring = null;
        for (self.outputs.items) |output| output.scene.clearShellQuads();
        if (owner) |output| output.scheduleFrame();
    }

    fn updateColumnDrag(self: *Self, event: gesture.Primitive.Drag) void {
        if (event.direction != .left and event.direction != .right) return;
        self.drag_direction = event.direction;
        self.drag_progress = event.progress;
        self.relayoutToplevels();
    }

    fn handleFlick(self: *Self, direction: gesture.Direction) void {
        self.activateFallbackSlice(self.captureFallbackRing(.{
            .x = self.seat.pointer_x,
            .y = self.seat.pointer_y,
        }), sliceForDirection(direction));
    }

    fn finishGesture(self: *Self) void {
        const ring = self.fallback_ring;
        const selected = if (ring) |active| active.hover else null;
        self.closeFallbackRing();
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
        const adjacent = adjacentIndex(current, self.toplevels.items.len, direction);
        if (adjacent == current) {
            self.drag_direction = null;
            self.drag_progress = 0;
            self.relayoutToplevels();
            return;
        }
        self.focused_column = adjacent;
        self.drag_direction = null;
        self.drag_progress = 0;
        const focused = self.focused_column orelse return;
        self.relayoutToplevels();
        self.seat.activate(self.toplevels.items[focused].surface);
    }

    fn syncColumnToSurface(self: *Self, surface: *Surface) void {
        for (self.toplevels.items, 0..) |entry, index| {
            if (entry.surface != surface) continue;
            self.focused_column = index;
            self.relayoutToplevels();
            return;
        }
    }

    pub fn issueActivationToken(self: *Self) !u64 {
        const token = self.next_activation_token;
        self.next_activation_token +%= 1;
        try self.activation_tokens.put(token, {});
        return token;
    }

    pub fn activateWithToken(self: *Self, token: u64, surface: *Surface) void {
        if (!self.activation_tokens.remove(token)) return;
        for (self.toplevels.items, 0..) |entry, index| {
            if (entry.surface != surface) continue;
            self.focused_column = index;
            self.relayoutToplevels();
            break;
        }
        self.seat.activate(surface);
    }

    fn activateFallbackSlice(self: *Self, ring: FallbackRing, slice: u8) void {
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

    fn contextualSurface(self: *const Self) ?*Surface {
        if (self.seat.pointer_focus) |surface| return surface;
        const focused = self.focused_column orelse return null;
        if (focused >= self.toplevels.items.len) return null;
        return self.toplevels.items[focused].surface;
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
    pub fn createOutput(self: *Self, backend_output: backend.output.IOutput, name: []const u8) Error!*Output {
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

    /// Schedules a frame on all outputs
    pub fn scheduleFrame(self: *Self) void {
        self.logger.debug("Compositor: Scheduling frame on {d} output(s)", .{self.outputs.items.len});
        for (self.outputs.items) |output| {
            output.scheduleFrame();
        }
    }
};

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

fn sessionFdReady(_: i32, _: u32, userdata: ?*anyopaque) callconv(.c) i32 {
    const session: *backend.session.Type = @ptrCast(@alignCast(userdata orelse return 0));
    session.dispatchPendingEventsAsync();
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
    );
}

fn inputPointerFrame(_: ?*anyopaque) void {}

fn inputKeyboardKey(userdata: ?*anyopaque, event: backend.wayland.input_signals.KeyboardKeyEvent) void {
    const self = fromUserdata(userdata) orelse return;
    self.seat.key(event.time_msec, event.key, @enumFromInt(@intFromEnum(event.state)));
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

    output.compositor.logger.debug("Compositor: Frame callback triggered for output {s}", .{output.name});

    // Trigger rendering on this output
    output.render() catch |err| {
        output.compositor.logger.err("Compositor: Failed to render frame on output {s}: {}", .{ output.name, err });
    };
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

    fixture.compositor.dispatchRuntimeInput(.{ .device_added = .{ .device = &extra } });
    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
    fixture.compositor.dispatchRuntimeInput(.{ .device_added = .{ .device = &side } });
    try testing.expectEqual(gesture.Button.middle, fixture.compositor.seat.mouse.config.shell_button);
    fixture.compositor.dispatchRuntimeInput(.{ .device_removed = .{ .device = &side } });
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
