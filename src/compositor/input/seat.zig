const std = @import("std");
const core = @import("core");
const wayland = @import("wayland");
const c = wayland.c;
const Surface = @import("../surface.zig").Surface;
const FocusStack = @import("focus.zig").Stack(*Surface);
const gesture = @import("gesture.zig");

const xkb = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const Axis = enum(u32) {
    vertical = c.WL_POINTER_AXIS_VERTICAL_SCROLL,
    horizontal = c.WL_POINTER_AXIS_HORIZONTAL_SCROLL,
};

pub const AxisSource = enum(u32) {
    wheel = c.WL_POINTER_AXIS_SOURCE_WHEEL,
    finger = c.WL_POINTER_AXIS_SOURCE_FINGER,
    continuous = c.WL_POINTER_AXIS_SOURCE_CONTINUOUS,
    wheel_tilt = c.WL_POINTER_AXIS_SOURCE_WHEEL_TILT,
};

pub const ButtonState = enum(u32) {
    released = c.WL_POINTER_BUTTON_STATE_RELEASED,
    pressed = c.WL_POINTER_BUTTON_STATE_PRESSED,
};

pub const KeyState = enum(u32) {
    released = c.WL_KEYBOARD_KEY_STATE_RELEASED,
    pressed = c.WL_KEYBOARD_KEY_STATE_PRESSED,
};

pub const Grab = struct {
    active: bool = false,
    constraints_suspended: bool = false,

    pub fn begin(self: *Grab) void {
        self.active = true;
        self.constraints_suspended = true;
    }

    pub fn end(self: *Grab) void {
        self.active = false;
        self.constraints_suspended = false;
    }
};

pub const ConstraintControl = struct {
    userdata: ?*anyopaque = null,
    pause: ?*const fn (?*anyopaque) void = null,
    restore: ?*const fn (?*anyopaque) void = null,
};

const DeferredMotion = struct {
    time: u32,
    x: f64,
    y: f64,
};

const Timebase = struct {
    last_msec: ?u32 = null,
    extended_msec: u64 = 0,

    fn usec(self: *Timebase, time: u32) u64 {
        const previous = self.last_msec orelse {
            self.last_msec = time;
            self.extended_msec = time;
            return @as(u64, time) * std.time.us_per_ms;
        };
        self.extended_msec += @as(u32, time -% previous);
        self.last_msec = time;
        return self.extended_msec * std.time.us_per_ms;
    }
};

pub const Type = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    pointers: std.ArrayList(*PointerResource) = .empty,
    keyboards: std.ArrayList(*KeyboardResource) = .empty,
    touches: std.ArrayList(*TouchResource) = .empty,
    focus_stack: FocusStack,
    pointer_focus: ?*Surface = null,
    keyboard_focus: ?*Surface = null,
    touch_focus: ?*Surface = null,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_surface_x: f64 = 0,
    pointer_surface_y: f64 = 0,
    grab: Grab = .{},
    constraint_control: ConstraintControl = .{},
    mouse: gesture.Mouse,
    input_timebase: Timebase = .{},
    deferred_target: ?*Surface = null,
    deferred_motion: std.ArrayList(DeferredMotion) = .empty,
    gesture_timer: ?*c.wl_event_source = null,
    gesture_userdata: ?*anyopaque = null,
    gesture_handler: ?*const fn (?*anyopaque, gesture.Primitive) void = null,
    focus_sync_userdata: ?*anyopaque = null,
    focus_sync_handler: ?*const fn (?*anyopaque, *Surface) void = null,
    popup_grab: ?*c.wl_resource = null,
    xkb_context: *xkb.xkb_context,
    xkb_keymap: *xkb.xkb_keymap,
    xkb_state: *xkb.xkb_state,
    keymap_text: []u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, display: *c.wl_display) !Self {
        const context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer xkb.xkb_context_unref(context);

        const keymap = xkb.xkb_keymap_new_from_names(
            context,
            null,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapFailed;
        errdefer xkb.xkb_keymap_unref(keymap);

        const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;
        errdefer xkb.xkb_state_unref(state);

        const text_z = xkb.xkb_keymap_get_as_string(
            keymap,
            xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        ) orelse return error.XkbSerializeFailed;
        defer xkb.free(text_z);

        return .{
            .allocator = allocator,
            .display = display,
            .focus_stack = FocusStack.init(allocator),
            .mouse = .{},
            .xkb_context = context,
            .xkb_keymap = keymap,
            .xkb_state = state,
            .keymap_text = try allocator.dupe(u8, std.mem.span(text_z)),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.gesture_timer) |source| _ = c.wl_event_source_remove(source);
        while (self.pointers.items.len > 0)
            c.wl_resource_destroy(self.pointers.items[self.pointers.items.len - 1].resource);
        while (self.keyboards.items.len > 0)
            c.wl_resource_destroy(self.keyboards.items[self.keyboards.items.len - 1].resource);
        while (self.touches.items.len > 0)
            c.wl_resource_destroy(self.touches.items[self.touches.items.len - 1].resource);
        self.focus_stack.deinit();
        self.pointers.deinit(self.allocator);
        self.keyboards.deinit(self.allocator);
        self.touches.deinit(self.allocator);
        self.deferred_motion.deinit(self.allocator);
        self.allocator.free(self.keymap_text);
        xkb.xkb_state_unref(self.xkb_state);
        xkb.xkb_keymap_unref(self.xkb_keymap);
        xkb.xkb_context_unref(self.xkb_context);
    }

    pub fn addPointer(self: *Self, pointer: *PointerResource) !void {
        try self.pointers.append(self.allocator, pointer);
    }

    pub fn addKeyboard(self: *Self, keyboard: *KeyboardResource) !void {
        try self.keyboards.append(self.allocator, keyboard);
    }

    pub fn addTouch(self: *Self, touch: *TouchResource) !void {
        try self.touches.append(self.allocator, touch);
    }

    pub fn removePointer(self: *Self, pointer: *PointerResource) void {
        removeResource(PointerResource, &self.pointers, pointer);
    }

    pub fn removeKeyboard(self: *Self, keyboard: *KeyboardResource) void {
        removeResource(KeyboardResource, &self.keyboards, keyboard);
    }

    pub fn removeTouch(self: *Self, touch: *TouchResource) void {
        removeResource(TouchResource, &self.touches, touch);
    }

    pub fn sendKeymap(self: *Self, resource: *c.wl_resource) void {
        const fd = std.posix.memfd_createZ("sideswipe-keymap", 0) catch {
            c.wl_keyboard_send_keymap(resource, c.WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP, -1, 0);
            return;
        };
        defer core.unix.close(fd);

        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.allocator);
        bytes.appendSlice(self.allocator, self.keymap_text) catch return;
        bytes.append(self.allocator, 0) catch return;
        core.unix.ftruncate(fd, bytes.items.len) catch return;
        writeAll(fd, bytes.items) catch return;
        c.wl_keyboard_send_keymap(
            resource,
            c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
            fd,
            @intCast(bytes.items.len),
        );
    }

    pub fn motionAbsolute(self: *Self, surfaces: []const *Surface, time: u32, x: f64, y: f64) void {
        self.pointer_x = x;
        self.pointer_y = y;
        const translated = self.mouse.motion(self.input_timebase.usec(time), .{ .x = x, .y = y }) catch {
            self.cancelGesture();
            return;
        };
        if (translated.consumed) {
            if (!translated.claimed) {
                self.deferMotion(time, x, y);
                return;
            }
            self.claimGesture();
            self.dispatchTranslation(translated);
            return;
        }
        self.setPointerHit(hitTest(surfaces, x, y));
        const surface = self.pointer_focus orelse return;
        self.sendPointerMotion(surface, time);
    }

    pub fn button(self: *Self, time: u32, button_code: u32, state: ButtonState) void {
        const translated = self.mouse.button(
            self.input_timebase.usec(time),
            .{ .x = self.pointer_x, .y = self.pointer_y },
            button_code,
            @enumFromInt(@intFromEnum(state)),
        ) catch return;
        if (translated.consumed) {
            self.updateDeferredPress(button_code, state);
            if (translated.claimed and button_code == self.mouse.config.shell_button)
                self.claimGesture();
            self.dispatchTranslation(translated);
            if (button_code == self.mouse.config.shell_button and state == .released)
                self.finishGestureGrab();
            return;
        }
        self.deliverButton(time, button_code, state);
    }

    pub fn setGestureHandler(
        self: *Self,
        userdata: ?*anyopaque,
        handler: *const fn (?*anyopaque, gesture.Primitive) void,
    ) void {
        self.gesture_userdata = userdata;
        self.gesture_handler = handler;
    }

    pub fn setFocusSyncHandler(
        self: *Self,
        userdata: ?*anyopaque,
        handler: *const fn (?*anyopaque, *Surface) void,
    ) void {
        self.focus_sync_userdata = userdata;
        self.focus_sync_handler = handler;
    }

    pub fn setConstraintControl(self: *Self, control: ConstraintControl) void {
        self.constraint_control = control;
    }

    pub fn selectShellButton(self: *Self, has_side: bool, has_extra: bool) void {
        _ = has_side;
        _ = has_extra;
        if (self.mouse.recognizer.active()) return;
        self.mouse = gesture.Mouse.init(.{
            .shell_button = gesture.Mouse.defaultShellButton(),
            .gesture = self.mouse.config.gesture,
        });
    }

    pub fn attachGestureTimer(self: *Self) !void {
        if (self.gesture_timer != null) return;
        const event_loop = c.wl_display_get_event_loop(self.display) orelse
            return error.EventLoopUnavailable;
        self.gesture_timer = c.wl_event_loop_add_timer(event_loop, gestureTimer, self) orelse
            return error.GestureTimerFailed;
    }

    fn deliverButton(self: *Self, time: u32, button_code: u32, state: ButtonState) void {
        const surface = self.pointer_focus orelse return;
        self.deliverButtonTo(surface, time, button_code, state);
    }

    fn deliverButtonTo(self: *Self, surface: *Surface, time: u32, button_code: u32, state: ButtonState) void {
        if (state == .pressed and self.popup_grab != null and !isPopup(self.pointer_focus)) {
            c.xdg_popup_send_popup_done(self.popup_grab);
            self.popup_grab = null;
        }
        if (state == .pressed) self.activate(surface);
        const serial = c.wl_display_next_serial(self.display);
        for (self.pointers.items) |pointer| {
            if (!sameClient(pointer.resource, surface)) continue;
            c.wl_pointer_send_button(pointer.resource, serial, time, button_code, @intFromEnum(state));
            sendPointerFrame(pointer.resource);
        }
    }

    fn updateDeferredPress(self: *Self, button_code: u32, state: ButtonState) void {
        if (button_code != self.mouse.config.shell_button or state != .pressed) return;
        self.deferred_target = self.pointer_focus;
        self.deferred_motion.clearRetainingCapacity();
        if (self.gesture_timer) |source|
            _ = c.wl_event_source_timer_update(source, @intCast(self.mouse.config.gesture.hold_usec / 1000));
    }

    fn dispatchTranslation(self: *Self, translated: gesture.Translation) void {
        if (translated.replay_press != null and translated.replay_release != null)
            self.replayDeferred(translated.replay_press.?, translated.replay_release.?);
        if (translated.primitive) |primitive| self.dispatchPrimitive(primitive);
        if (translated.completion) |completion| self.dispatchPrimitive(completion);
    }

    fn dispatchPrimitive(self: *Self, primitive: gesture.Primitive) void {
        switch (primitive) {
            .back => self.back(),
            .forward => self.forward(),
            else => {},
        }
        if (self.gesture_handler) |handler| handler(self.gesture_userdata, primitive);
    }

    pub fn setPopupGrab(self: *Self, resource: *c.wl_resource) void {
        if (self.popup_grab) |previous| c.xdg_popup_send_popup_done(previous);
        self.popup_grab = resource;
    }

    pub fn clearPopupGrab(self: *Self, resource: *c.wl_resource) void {
        if (self.popup_grab == resource) self.popup_grab = null;
    }

    pub fn axis(
        self: *Self,
        time: u32,
        source: AxisSource,
        axis_kind: Axis,
        value: f64,
        discrete: i32,
    ) void {
        const translated = self.mouse.axis(
            self.input_timebase.usec(time),
            self.controlActive(),
            false,
            value,
        );
        if (translated.consumed) {
            self.dispatchTranslation(translated);
            return;
        }
        const surface = self.pointer_focus orelse return;
        for (self.pointers.items) |pointer| {
            if (!sameClient(pointer.resource, surface)) continue;
            sendAxis(pointer.resource, time, source, axis_kind, value, discrete);
        }
    }

    pub fn key(self: *Self, time: u32, key_code: u32, state: KeyState) void {
        const surface = self.keyboard_focus orelse return;
        const direction: xkb.xkb_key_direction = if (state == .pressed)
            xkb.XKB_KEY_DOWN
        else
            xkb.XKB_KEY_UP;
        _ = xkb.xkb_state_update_key(self.xkb_state, key_code + 8, direction);

        const serial = c.wl_display_next_serial(self.display);
        for (self.keyboards.items) |keyboard| {
            if (!sameClient(keyboard.resource, surface)) continue;
            c.wl_keyboard_send_key(keyboard.resource, serial, time, key_code, @intFromEnum(state));
            self.sendModifiers(keyboard.resource, serial);
        }
    }

    pub fn modifiers(
        self: *Self,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        _ = xkb.xkb_state_update_mask(
            self.xkb_state,
            depressed,
            latched,
            locked,
            0,
            0,
            group,
        );
        const surface = self.keyboard_focus orelse return;
        const serial = c.wl_display_next_serial(self.display);
        for (self.keyboards.items) |keyboard| {
            if (!sameClient(keyboard.resource, surface)) continue;
            c.wl_keyboard_send_modifiers(keyboard.resource, serial, depressed, latched, locked, group);
        }
    }

    pub fn touchDown(self: *Self, surfaces: []const *Surface, time: u32, id: i32, x: f64, y: f64) void {
        const target = hitTest(surfaces, x, y) orelse return;
        const surface = target.surface;
        self.touch_focus = surface;
        self.activate(surface);
        const serial = c.wl_display_next_serial(self.display);
        for (self.touches.items) |touch| {
            if (!sameClient(touch.resource, surface)) continue;
            c.wl_touch_send_down(
                touch.resource,
                serial,
                time,
                surface.resource,
                id,
                fixed(target.local_x),
                fixed(target.local_y),
            );
        }
    }

    pub fn touchUp(self: *Self, time: u32, id: i32) void {
        const surface = self.touch_focus orelse return;
        const serial = c.wl_display_next_serial(self.display);
        for (self.touches.items) |touch| {
            if (!sameClient(touch.resource, surface)) continue;
            c.wl_touch_send_up(touch.resource, serial, time, id);
        }
    }

    pub fn touchMotion(self: *Self, time: u32, id: i32, x: f64, y: f64) void {
        const surface = self.touch_focus orelse return;
        const local = localPoint(surface, x, y);
        for (self.touches.items) |touch| {
            if (!sameClient(touch.resource, surface)) continue;
            c.wl_touch_send_motion(touch.resource, time, id, fixed(local.x), fixed(local.y));
        }
    }

    pub fn touchFrame(self: *Self) void {
        const surface = self.touch_focus orelse return;
        for (self.touches.items) |touch| {
            if (!sameClient(touch.resource, surface)) continue;
            c.wl_touch_send_frame(touch.resource);
        }
    }

    pub fn touchCancel(self: *Self) void {
        const surface = self.touch_focus orelse return;
        for (self.touches.items) |touch| {
            if (!sameClient(touch.resource, surface)) continue;
            c.wl_touch_send_cancel(touch.resource);
        }
        self.touch_focus = null;
    }

    pub fn activate(self: *Self, surface: *Surface) void {
        self.focus_stack.push(surface) catch return;
        self.setKeyboardFocus(surface);
    }

    pub fn back(self: *Self) void {
        if (self.focus_stack.peekBack()) |target| {
            if (self.focus_sync_handler) |handler| handler(self.focus_sync_userdata, target);
        }
        self.setKeyboardFocus(self.focus_stack.back());
    }

    pub fn forward(self: *Self) void {
        if (self.focus_stack.peekForward()) |target| {
            if (self.focus_sync_handler) |handler| handler(self.focus_sync_userdata, target);
        }
        self.setKeyboardFocus(self.focus_stack.forward());
    }

    pub fn surfaceDestroyed(self: *Self, surface: *Surface) void {
        self.focus_stack.remove(surface);
        if (self.pointer_focus == surface) self.setPointerFocus(null);
        if (self.keyboard_focus == surface) {
            const replacement = self.focus_stack.current();
            if (replacement) |target| {
                if (self.focus_sync_handler) |handler| handler(self.focus_sync_userdata, target);
            }
            self.setKeyboardFocus(replacement);
        }
        if (self.touch_focus == surface) self.touchCancel();
        if (self.deferred_target == surface) self.cancelGesture();
    }

    pub fn surfaceUnmapped(self: *Self, surface: *Surface) void {
        self.surfaceDestroyed(surface);
    }

    fn setPointerFocus(self: *Self, next: ?*Surface) void {
        if (self.pointer_focus == next) return;
        if (self.pointer_focus) |old| self.sendPointerLeave(old);
        self.pointer_focus = next;
        if (next) |surface| self.sendPointerEnter(surface);
    }

    fn setPointerHit(self: *Self, hit: ?Hit) void {
        const target = if (hit) |result| result.surface else null;
        if (hit) |result| {
            self.pointer_surface_x = result.local_x;
            self.pointer_surface_y = result.local_y;
        }
        self.setPointerFocus(target);
    }

    fn setKeyboardFocus(self: *Self, next: ?*Surface) void {
        if (self.keyboard_focus == next) return;
        if (self.keyboard_focus) |old| self.sendKeyboardLeave(old);
        self.keyboard_focus = next;
        if (next) |surface| self.sendKeyboardEnter(surface);
    }

    fn sendPointerEnter(self: *Self, surface: *Surface) void {
        const serial = c.wl_display_next_serial(self.display);
        for (self.pointers.items) |pointer| {
            if (!sameClient(pointer.resource, surface)) continue;
            c.wl_pointer_send_enter(
                pointer.resource,
                serial,
                surface.resource,
                fixed(self.pointer_surface_x),
                fixed(self.pointer_surface_y),
            );
        }
    }

    fn sendPointerLeave(self: *Self, surface: *Surface) void {
        const serial = c.wl_display_next_serial(self.display);
        for (self.pointers.items) |pointer| {
            if (!sameClient(pointer.resource, surface)) continue;
            c.wl_pointer_send_leave(pointer.resource, serial, surface.resource);
        }
    }

    fn sendPointerMotion(self: *Self, surface: *Surface, time: u32) void {
        for (self.pointers.items) |pointer| {
            if (!sameClient(pointer.resource, surface)) continue;
            c.wl_pointer_send_motion(pointer.resource, time, fixed(self.pointer_surface_x), fixed(self.pointer_surface_y));
            sendPointerFrame(pointer.resource);
        }
    }

    fn sendKeyboardEnter(self: *Self, surface: *Surface) void {
        var keys = c.wl_array{ .size = 0, .alloc = 0, .data = null };
        const serial = c.wl_display_next_serial(self.display);
        for (self.keyboards.items) |keyboard| {
            if (!sameClient(keyboard.resource, surface)) continue;
            c.wl_keyboard_send_enter(keyboard.resource, serial, surface.resource, &keys);
            self.sendModifiers(keyboard.resource, serial);
        }
    }

    fn sendKeyboardLeave(self: *Self, surface: *Surface) void {
        const serial = c.wl_display_next_serial(self.display);
        for (self.keyboards.items) |keyboard| {
            if (!sameClient(keyboard.resource, surface)) continue;
            c.wl_keyboard_send_leave(keyboard.resource, serial, surface.resource);
        }
    }

    fn sendModifiers(self: *Self, resource: *c.wl_resource, serial: u32) void {
        const depressed = xkb.xkb_state_serialize_mods(self.xkb_state, xkb.XKB_STATE_MODS_DEPRESSED);
        const latched = xkb.xkb_state_serialize_mods(self.xkb_state, xkb.XKB_STATE_MODS_LATCHED);
        const locked = xkb.xkb_state_serialize_mods(self.xkb_state, xkb.XKB_STATE_MODS_LOCKED);
        const group = xkb.xkb_state_serialize_layout(self.xkb_state, xkb.XKB_STATE_LAYOUT_EFFECTIVE);
        c.wl_keyboard_send_modifiers(resource, serial, depressed, latched, locked, group);
    }

    fn controlActive(self: *const Self) bool {
        return xkb.xkb_state_mod_name_is_active(
            self.xkb_state,
            xkb.XKB_MOD_NAME_CTRL,
            xkb.XKB_STATE_MODS_EFFECTIVE,
        ) > 0;
    }

    fn deferMotion(self: *Self, time: u32, x: f64, y: f64) void {
        self.deferred_motion.append(self.allocator, .{ .time = time, .x = x, .y = y }) catch {
            const press = self.mouse.deferred_press orelse {
                self.cancelGesture();
                return;
            };
            self.replayPressAndMotion(self.deferred_target, press, time, x, y);
            self.cancelGesture();
        };
    }

    fn replayPressAndMotion(
        self: *Self,
        target: ?*Surface,
        press: gesture.ButtonEvent,
        time: u32,
        x: f64,
        y: f64,
    ) void {
        const surface = target orelse return;
        self.deliverButtonTo(surface, toMsec(press.time_usec), press.button, .pressed);
        for (self.deferred_motion.items) |motion|
            self.sendPointerMotionAt(surface, motion.time, motion.x, motion.y);
        self.sendPointerMotionAt(surface, time, x, y);
    }

    fn replayDeferred(
        self: *Self,
        press: gesture.ButtonEvent,
        release: gesture.ButtonEvent,
    ) void {
        const surface = self.deferred_target orelse {
            self.clearDeferred();
            return;
        };
        self.deliverButtonTo(surface, toMsec(press.time_usec), press.button, .pressed);
        for (self.deferred_motion.items) |motion|
            self.sendPointerMotionAt(surface, motion.time, motion.x, motion.y);
        self.deliverButtonTo(surface, toMsec(release.time_usec), release.button, .released);
        self.clearDeferred();
    }

    fn sendPointerMotionAt(self: *Self, surface: *Surface, time: u32, x: f64, y: f64) void {
        const local = localPoint(surface, x, y);
        for (self.pointers.items) |pointer| {
            if (!sameClient(pointer.resource, surface)) continue;
            c.wl_pointer_send_motion(pointer.resource, time, fixed(local.x), fixed(local.y));
            sendPointerFrame(pointer.resource);
        }
    }

    fn claimGesture(self: *Self) void {
        if (self.grab.active) return;
        self.grab.begin();
        self.deferred_motion.clearRetainingCapacity();
        self.deferred_target = null;
        if (self.constraint_control.pause) |pause| pause(self.constraint_control.userdata);
    }

    fn finishGestureGrab(self: *Self) void {
        if (self.gesture_timer) |source| _ = c.wl_event_source_timer_update(source, 0);
        if (self.grab.active) {
            if (self.constraint_control.restore) |restore| restore(self.constraint_control.userdata);
        }
        self.grab.end();
        self.clearDeferred();
    }

    fn cancelGesture(self: *Self) void {
        self.mouse.recognizer.cancel();
        self.mouse.deferred_press = null;
        self.finishGestureGrab();
    }

    fn clearDeferred(self: *Self) void {
        self.deferred_target = null;
        self.deferred_motion.clearRetainingCapacity();
    }
};

pub const PointerResource = struct {
    seat: *Type,
    resource: *c.wl_resource,
};

pub const KeyboardResource = struct {
    seat: *Type,
    resource: *c.wl_resource,
};

pub const TouchResource = struct {
    seat: *Type,
    resource: *c.wl_resource,
};

fn removeResource(
    comptime T: type,
    resources: *std.ArrayList(*T),
    target: *T,
) void {
    for (resources.items, 0..) |resource, index| {
        if (resource != target) continue;
        _ = resources.swapRemove(index);
        return;
    }
}

pub const Hit = struct {
    surface: *Surface,
    local_x: f64,
    local_y: f64,
};

pub fn hitTest(surfaces: []const *Surface, x: f64, y: f64) ?Hit {
    var index = surfaces.len;
    while (index > 0) {
        index -= 1;
        const surface = surfaces[index];
        if (surface.parent != null or !surface.mapped or surface.role == .cursor) continue;
        const geometry = surface.scene_geometry orelse continue;
        if (!inside(x, y, geometry.x, geometry.y, geometry.width, geometry.height)) continue;
        const local_x = x - @as(f64, @floatFromInt(geometry.x));
        const local_y = y - @as(f64, @floatFromInt(geometry.y));
        return hitTree(surface, local_x, local_y, 0);
    }
    return null;
}

fn hitTree(surface: *Surface, x: f64, y: f64, depth: usize) ?Hit {
    if (depth >= 256 or !surface.mapped) return null;
    if (hitChildren(surface, x, y, true, depth)) |hit| return hit;
    const size = logicalSize(surface);
    if (inside(x, y, 0, 0, size.width, size.height) and surface.acceptsInput(x, y))
        return .{ .surface = surface, .local_x = x, .local_y = y };
    return hitChildren(surface, x, y, false, depth);
}

fn hitChildren(surface: *Surface, x: f64, y: f64, above: bool, depth: usize) ?Hit {
    var index = surface.children.items.len;
    while (index > 0) {
        index -= 1;
        const child = surface.children.items[index];
        if (child.subsurface_above_parent != above) continue;
        const child_x = x - @as(f64, @floatFromInt(child.subsurface_x));
        const child_y = y - @as(f64, @floatFromInt(child.subsurface_y));
        const size = logicalSize(child);
        if (!inside(child_x, child_y, 0, 0, size.width, size.height)) continue;
        if (hitTree(child, child_x, child_y, depth + 1)) |hit| return hit;
    }
    return null;
}

fn localPoint(surface: *Surface, global_x: f64, global_y: f64) gesture.Point {
    var x = global_x;
    var y = global_y;
    var current = surface;
    while (current.parent) |parent| {
        x -= @floatFromInt(current.subsurface_x);
        y -= @floatFromInt(current.subsurface_y);
        current = parent;
    }
    if (current.scene_geometry) |geometry| {
        x -= @floatFromInt(geometry.x);
        y -= @floatFromInt(geometry.y);
    }
    return .{ .x = x, .y = y };
}

fn logicalSize(surface: *Surface) struct { width: i32, height: i32 } {
    if (surface.current.viewport.destination) |destination|
        return .{ .width = destination.width, .height = destination.height };
    if (surface.scene_geometry) |geometry|
        return .{ .width = geometry.width, .height = geometry.height };
    return .{ .width = surface.current.width, .height = surface.current.height };
}

fn inside(x: f64, y: f64, left: i32, top: i32, width: i32, height: i32) bool {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or width <= 0 or height <= 0) return false;
    const right = @as(f64, @floatFromInt(left + width));
    const bottom = @as(f64, @floatFromInt(top + height));
    return x >= @as(f64, @floatFromInt(left)) and y >= @as(f64, @floatFromInt(top)) and x < right and y < bottom;
}

fn sameClient(resource: *c.wl_resource, surface: *Surface) bool {
    const surface_resource = surface.resource orelse return false;
    return c.wl_resource_get_client(resource) == c.wl_resource_get_client(surface_resource);
}

fn isPopup(surface: ?*Surface) bool {
    const candidate = surface orelse return false;
    return candidate.role == .xdg_popup;
}

fn fixed(value: f64) c.wl_fixed_t {
    const scaled = value * 256.0;
    return @intFromFloat(std.math.clamp(scaled, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn sendPointerFrame(resource: *c.wl_resource) void {
    if (c.wl_resource_get_version(resource) >= c.WL_POINTER_FRAME_SINCE_VERSION)
        c.wl_pointer_send_frame(resource);
}

fn sendAxis(
    resource: *c.wl_resource,
    time: u32,
    source: AxisSource,
    axis_kind: Axis,
    value: f64,
    discrete: i32,
) void {
    const version = c.wl_resource_get_version(resource);
    if (version >= c.WL_POINTER_AXIS_SOURCE_SINCE_VERSION)
        c.wl_pointer_send_axis_source(resource, @intFromEnum(source));
    c.wl_pointer_send_axis(resource, time, @intFromEnum(axis_kind), fixed(value));
    if (version >= c.WL_POINTER_AXIS_DISCRETE_SINCE_VERSION and discrete != 0)
        c.wl_pointer_send_axis_discrete(resource, @intFromEnum(axis_kind), discrete);
    if (version >= c.WL_POINTER_FRAME_SINCE_VERSION) c.wl_pointer_send_frame(resource);
}

fn gestureTimer(data: ?*anyopaque) callconv(.c) i32 {
    const seat: *Type = @ptrCast(@alignCast(data orelse return 0));
    const deadline = seat.mouse.recognizer.started_usec + seat.mouse.config.gesture.hold_usec;
    const translated = seat.mouse.tick(deadline) catch return 0;
    if (translated.claimed) seat.claimGesture();
    seat.dispatchTranslation(translated);
    return 0;
}

fn toMsec(time_usec: u64) u32 {
    return @truncate(time_usec / std.time.us_per_ms);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = try core.unix.write(fd, bytes[offset..]);
        if (written == 0) return error.UnexpectedWriteFailure;
        offset += written;
    }
}

const testing = core.testing;

test "Grab - suspends and restores constraints" {
    var grab = Grab{};
    grab.begin();
    try testing.expect(grab.active);
    try testing.expect(grab.constraints_suspended);

    grab.end();
    try testing.expectFalse(grab.active);
    try testing.expectFalse(grab.constraints_suspended);
}

test "Seat - creates an xkbcommon keymap" {
    var runtime = try wayland.test_setup.RuntimeDir.setup(testing.allocator);
    defer runtime.cleanup();
    var server = try wayland.Server.init(testing.allocator, null);
    defer server.deinit();

    var seat = try Type.init(testing.allocator, server.getDisplay());
    defer seat.deinit();

    try testing.expect(seat.keymap_text.len > 0);
    try testing.expect(std.mem.startsWith(u8, seat.keymap_text, "xkb_keymap"));
}

test "Timebase - unwraps millisecond timestamp rollover" {
    var timebase: Timebase = .{};
    const before = timebase.usec(std.math.maxInt(u32) - 1);
    const after = timebase.usec(2);
    try testing.expectEqual(@as(u64, 4 * std.time.us_per_ms), after - before);
}

test "Seat - constraints pause only after gesture claim and restore on release" {
    var runtime = try wayland.test_setup.RuntimeDir.setup(testing.allocator);
    defer runtime.cleanup();
    var server = try wayland.Server.init(testing.allocator, null);
    defer server.deinit();
    var seat = try Type.init(testing.allocator, server.getDisplay());
    defer seat.deinit();

    const Probe = struct {
        var paused = false;
        var restored = false;

        fn pause(_: ?*anyopaque) void {
            paused = true;
        }

        fn restore(_: ?*anyopaque) void {
            restored = true;
        }
    };
    Probe.paused = false;
    Probe.restored = false;
    seat.setConstraintControl(.{ .pause = Probe.pause, .restore = Probe.restore });

    seat.button(1, gesture.Button.middle, .pressed);
    try testing.expectFalse(seat.grab.active);
    try testing.expectFalse(Probe.paused);
    seat.motionAbsolute(&.{}, 2, 12, 0);
    try testing.expectFalse(seat.grab.active);
    seat.motionAbsolute(&.{}, 302, 12, 0);
    try testing.expect(seat.grab.active);
    try testing.expect(Probe.paused);
    seat.button(303, gesture.Button.middle, .released);
    try testing.expectFalse(seat.grab.active);
    try testing.expect(Probe.restored);
}

test "Seat - unclaimed shell sequence retains motion until paired release" {
    var runtime = try wayland.test_setup.RuntimeDir.setup(testing.allocator);
    defer runtime.cleanup();
    var server = try wayland.Server.init(testing.allocator, null);
    defer server.deinit();
    var seat = try Type.init(testing.allocator, server.getDisplay());
    defer seat.deinit();

    seat.button(10, gesture.Button.middle, .pressed);
    seat.motionAbsolute(&.{}, 11, 2, 1);
    try testing.expectEqual(@as(usize, 1), seat.deferred_motion.items.len);
    try testing.expectFalse(seat.grab.constraints_suspended);
    seat.button(12, gesture.Button.middle, .released);
    try testing.expectEqual(@as(usize, 0), seat.deferred_motion.items.len);
    try testing.expectFalse(seat.mouse.recognizer.active());
}

test "Seat - hit test chooses topmost subsurface and local coordinates" {
    var root: Surface = undefined;
    var child: Surface = undefined;
    root.mapped = true;
    root.role = .xdg_toplevel;
    root.parent = null;
    root.scene_geometry = .{ .x = 100, .y = 200, .width = 300, .height = 200 };
    root.children = .empty;
    root.current.input_region = .empty;
    root.current.input_region_infinite = true;
    root.current.viewport.destination = null;
    root.current.width = 300;
    root.current.height = 200;
    child.mapped = true;
    child.role = .subsurface;
    child.parent = &root;
    child.scene_geometry = null;
    child.children = .empty;
    child.current.input_region = .empty;
    child.current.input_region_infinite = true;
    child.subsurface_above_parent = true;
    child.subsurface_x = 20;
    child.subsurface_y = 30;
    child.current.viewport.destination = .{ .width = 80, .height = 60 };
    try root.children.append(testing.allocator, &child);
    defer root.children.deinit(testing.allocator);

    const hit = hitTest(&.{&root}, 125, 235).?;
    try testing.expectEqual(&child, hit.surface);
    try testing.expectEqual(@as(f64, 5), hit.local_x);
    try testing.expectEqual(@as(f64, 5), hit.local_y);
    const parent_hit = hitTest(&.{&root}, 110, 210).?;
    try testing.expectEqual(&root, parent_hit.surface);
    try testing.expectEqual(@as(f64, 10), parent_hit.local_x);
    try testing.expectNull(hitTest(&.{&root}, 99, 210));
}

test "Seat - hit test honors committed input regions and local coordinates" {
    var root: Surface = undefined;
    root.mapped = true;
    root.role = .xdg_toplevel;
    root.parent = null;
    root.scene_geometry = .{ .x = 100, .y = 200, .width = 300, .height = 200 };
    root.children = .empty;
    root.current.viewport.destination = null;
    root.current.width = 300;
    root.current.height = 200;
    root.current.input_region = .empty;
    defer root.current.input_region.deinit(testing.allocator);
    root.current.input_region_infinite = false;
    try root.current.input_region.append(testing.allocator, .{
        .x = 20,
        .y = 30,
        .width = 40,
        .height = 50,
    });

    try testing.expectNull(hitTest(&.{&root}, 110, 210));
    const accepted = hitTest(&.{&root}, 125, 235).?;
    try testing.expectEqual(&root, accepted.surface);
    try testing.expectEqual(@as(f64, 25), accepted.local_x);
    try testing.expectEqual(@as(f64, 35), accepted.local_y);
}

test "Seat - nested input regions preserve stacking and local coordinates" {
    var root: Surface = undefined;
    var lower: Surface = undefined;
    var upper: Surface = undefined;
    root.mapped = true;
    root.role = .xdg_toplevel;
    root.parent = null;
    root.scene_geometry = .{ .x = 100, .y = 200, .width = 300, .height = 200 };
    root.children = .empty;
    defer root.children.deinit(testing.allocator);
    root.current.width = 300;
    root.current.height = 200;
    root.current.viewport.destination = null;
    root.current.input_region = .empty;
    root.current.input_region_infinite = true;
    lower.mapped = true;
    lower.role = .subsurface;
    lower.parent = &root;
    lower.scene_geometry = null;
    lower.children = .empty;
    lower.current.input_region = .empty;
    lower.current.input_region_infinite = true;
    upper.mapped = true;
    upper.role = .subsurface;
    upper.parent = &root;
    upper.scene_geometry = null;
    upper.children = .empty;
    upper.current.input_region = .empty;
    defer upper.current.input_region.deinit(testing.allocator);
    upper.current.input_region_infinite = false;
    try root.children.appendSlice(testing.allocator, &.{ &lower, &upper });
    lower.subsurface_x = 20;
    lower.subsurface_y = 30;
    lower.subsurface_above_parent = true;
    upper.subsurface_x = 20;
    upper.subsurface_y = 30;
    upper.subsurface_above_parent = true;
    lower.current.viewport.destination = .{ .width = 80, .height = 60 };
    upper.current.viewport.destination = .{ .width = 80, .height = 60 };

    try upper.current.input_region.append(testing.allocator, .{
        .x = 10,
        .y = 10,
        .width = 20,
        .height = 20,
    });

    const lower_hit = hitTest(&.{&root}, 125, 235).?;
    try testing.expectEqual(&lower, lower_hit.surface);
    try testing.expectEqual(@as(f64, 5), lower_hit.local_x);
    try testing.expectEqual(@as(f64, 5), lower_hit.local_y);
    const upper_hit = hitTest(&.{&root}, 135, 245).?;
    try testing.expectEqual(&upper, upper_hit.surface);
    try testing.expectEqual(@as(f64, 15), upper_hit.local_x);
    try testing.expectEqual(@as(f64, 15), upper_hit.local_y);
}
