//! wl_seat protocol implementation
//! Handles input devices (keyboard, pointer, touch)

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("../compositor.zig").Compositor;

// wl_seat interface version we support
const WL_SEAT_VERSION = 7;

// Seat capabilities
const WL_SEAT_CAPABILITY_POINTER = 1;
const WL_SEAT_CAPABILITY_KEYBOARD = 2;
const WL_SEAT_CAPABILITY_TOUCH = 4;

// User data structures
// Note: All user data structs are allocated/freed with compositor.allocator

/// User data attached to wl_seat resources
const SeatData = struct {
    compositor: *Compositor,
};

/// User data attached to wl_pointer resources
const PointerData = struct {
    seat_data: *SeatData,
};

/// User data attached to wl_keyboard resources
const KeyboardData = struct {
    seat_data: *SeatData,
};

/// User data attached to wl_touch resources
const TouchData = struct {
    seat_data: *SeatData,
};

// wl_seat request handlers

fn seatGetPointer(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;

    const data: *SeatData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;
    comp.logger.debug("Client requested wl_pointer", .{});

    // Create wl_pointer resource
    const pointer_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_pointer_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    const pointer_data = comp.allocator.create(PointerData) catch {
        c.wl_resource_destroy(pointer_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    pointer_data.* = .{ .seat_data = data };

    c.wl_resource_set_implementation(
        pointer_resource,
        @ptrCast(&pointer_implementation),
        pointer_data,
        pointerResourceDestroy,
    );

    // TODO: Store pointer resource for sending events later
}

fn seatGetKeyboard(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;

    const data: *SeatData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;
    comp.logger.debug("Client requested wl_keyboard", .{});

    // Create wl_keyboard resource
    const keyboard_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_keyboard_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    const keyboard_data = comp.allocator.create(KeyboardData) catch {
        c.wl_resource_destroy(keyboard_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    keyboard_data.* = .{ .seat_data = data };

    c.wl_resource_set_implementation(
        keyboard_resource,
        @ptrCast(&keyboard_implementation),
        keyboard_data,
        keyboardResourceDestroy,
    );

    // Send keymap (empty for now)
    sendKeymap(keyboard_resource);

    // Send repeat info (version 4+)
    const version = c.wl_resource_get_version(keyboard_resource);
    if (version >= 4) {
        c.wl_keyboard_send_repeat_info(keyboard_resource, 25, 600); // 25 Hz, 600ms delay
    }

    // TODO: Store keyboard resource for sending events later
}

fn seatGetTouch(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;

    const data: *SeatData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;
    comp.logger.debug("Client requested wl_touch", .{});

    // Create wl_touch resource
    const touch_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_touch_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    const touch_data = comp.allocator.create(TouchData) catch {
        c.wl_resource_destroy(touch_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    touch_data.* = .{ .seat_data = data };

    c.wl_resource_set_implementation(
        touch_resource,
        @ptrCast(&touch_implementation),
        touch_data,
        touchResourceDestroy,
    );

    // TODO: Store touch resource for sending events later
}

fn seatRelease(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

var seat_implementation = [_]?*const anyopaque{
    @ptrCast(&seatGetPointer),
    @ptrCast(&seatGetKeyboard),
    @ptrCast(&seatGetTouch),
    @ptrCast(&seatRelease),
};

// wl_pointer request handlers (stubs for now)

fn pointerSetCursor(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    serial: u32,
    surface: ?*c.wl_resource,
    hotspot_x: i32,
    hotspot_y: i32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = serial;
    _ = surface;
    _ = hotspot_x;
    _ = hotspot_y;
    // Cursor setting stub
}

fn pointerRelease(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

var pointer_implementation = [_]?*const anyopaque{
    @ptrCast(&pointerSetCursor),
    @ptrCast(&pointerRelease),
};

fn pointerResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *PointerData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.seat_data.compositor.allocator.destroy(data);
}

// wl_keyboard request handlers (stubs for now)

fn keyboardRelease(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

var keyboard_implementation = [_]?*const anyopaque{
    @ptrCast(&keyboardRelease),
};

fn keyboardResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *KeyboardData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.seat_data.compositor.allocator.destroy(data);
}

// wl_touch request handlers (stubs for now)

fn touchRelease(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

var touch_implementation = [_]?*const anyopaque{
    @ptrCast(&touchRelease),
};

fn touchResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *TouchData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.seat_data.compositor.allocator.destroy(data);
}

// Helper functions

/// Sends an empty keymap to the client
fn sendKeymap(keyboard_resource: ?*c.wl_resource) void {
    // Create minimal empty keymap
    const keymap_str = "xkb_keymap { xkb_keycodes { minimum = 8; maximum = 255; }; };";
    const keymap_size = keymap_str.len + 1; // +1 for null terminator

    // Create anonymous file for keymap
    const fd = std.posix.memfd_create("keymap", 0) catch {
        // Fallback: just send empty keymap
        c.wl_keyboard_send_keymap(
            keyboard_resource,
            c.WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP,
            -1,
            0,
        );
        return;
    };
    defer std.posix.close(fd);

    // Write keymap to fd
    _ = std.posix.write(fd, keymap_str) catch {
        c.wl_keyboard_send_keymap(
            keyboard_resource,
            c.WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP,
            -1,
            0,
        );
        return;
    };

    // Send keymap
    c.wl_keyboard_send_keymap(
        keyboard_resource,
        c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
        fd,
        @intCast(keymap_size),
    );
}

// Global bind handler

fn seatBind(
    client: ?*c.wl_client,
    data: ?*anyopaque,
    version: u32,
    id: u32,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(data));

    compositor.logger.debug("Client bound to wl_seat (version {d})", .{version});

    const resource = c.wl_resource_create(
        client,
        &c.wl_seat_interface,
        @intCast(@min(version, WL_SEAT_VERSION)),
        id,
    ) orelse {
        c.wl_client_post_no_memory(client);
        return;
    };

    const seat_data = compositor.allocator.create(SeatData) catch {
        c.wl_resource_destroy(resource);
        c.wl_client_post_no_memory(client);
        return;
    };
    seat_data.* = .{ .compositor = compositor };

    c.wl_resource_set_implementation(
        resource,
        @ptrCast(&seat_implementation),
        seat_data,
        seatResourceDestroy,
    );

    // Send capabilities
    const capabilities = WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD;
    c.wl_seat_send_capabilities(resource, capabilities);

    // Send name (version 2+)
    if (version >= 2) {
        c.wl_seat_send_name(resource, "seat0");
    }
}

fn seatResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *SeatData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.compositor.allocator.destroy(data);
}

/// Registers the wl_seat global
pub fn register(compositor: *Compositor) !void {
    const global = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wl_seat_interface,
        WL_SEAT_VERSION,
        compositor,
        seatBind,
    );
    _ = global; // Global is owned by display, no need to track
}
