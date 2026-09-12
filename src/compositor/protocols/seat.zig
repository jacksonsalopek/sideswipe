//! wl_seat global and child resource lifecycle.

const wayland = @import("wayland");
const c = wayland.c;
const Compositor = @import("../compositor.zig").Compositor;
const input = @import("../input/seat.zig");

const version = 7;

const Resource = struct {
    compositor: *Compositor,
};

fn getPointer(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const seat_resource = resource orelse return;
    const data = getData(Resource, seat_resource);
    const pointer_resource = c.wl_resource_create(
        c.wl_resource_get_client(seat_resource),
        &c.wl_pointer_interface,
        c.wl_resource_get_version(seat_resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(seat_resource);

    const pointer = data.compositor.allocator.create(input.PointerResource) catch {
        c.wl_resource_destroy(pointer_resource);
        return c.wl_resource_post_no_memory(seat_resource);
    };
    pointer.* = .{ .seat = &data.compositor.seat, .resource = pointer_resource };
    data.compositor.seat.addPointer(pointer) catch {
        data.compositor.allocator.destroy(pointer);
        c.wl_resource_destroy(pointer_resource);
        return c.wl_resource_post_no_memory(seat_resource);
    };
    c.wl_resource_set_implementation(pointer_resource, @ptrCast(&pointer_impl), pointer, destroyPointer);
}

fn getKeyboard(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const seat_resource = resource orelse return;
    const data = getData(Resource, seat_resource);
    const keyboard_resource = c.wl_resource_create(
        c.wl_resource_get_client(seat_resource),
        &c.wl_keyboard_interface,
        c.wl_resource_get_version(seat_resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(seat_resource);

    const keyboard = data.compositor.allocator.create(input.KeyboardResource) catch {
        c.wl_resource_destroy(keyboard_resource);
        return c.wl_resource_post_no_memory(seat_resource);
    };
    keyboard.* = .{ .seat = &data.compositor.seat, .resource = keyboard_resource };
    data.compositor.seat.addKeyboard(keyboard) catch {
        data.compositor.allocator.destroy(keyboard);
        c.wl_resource_destroy(keyboard_resource);
        return c.wl_resource_post_no_memory(seat_resource);
    };
    c.wl_resource_set_implementation(keyboard_resource, @ptrCast(&keyboard_impl), keyboard, destroyKeyboard);
    data.compositor.seat.sendKeymap(keyboard_resource);
    if (c.wl_resource_get_version(keyboard_resource) >= 4)
        c.wl_keyboard_send_repeat_info(keyboard_resource, 25, 600);
}

fn getTouch(_: ?*c.wl_client, resource: ?*c.wl_resource, id: u32) callconv(.c) void {
    const seat_resource = resource orelse return;
    const data = getData(Resource, seat_resource);
    const touch_resource = c.wl_resource_create(
        c.wl_resource_get_client(seat_resource),
        &c.wl_touch_interface,
        c.wl_resource_get_version(seat_resource),
        id,
    ) orelse return c.wl_resource_post_no_memory(seat_resource);

    const touch = data.compositor.allocator.create(input.TouchResource) catch {
        c.wl_resource_destroy(touch_resource);
        return c.wl_resource_post_no_memory(seat_resource);
    };
    touch.* = .{ .seat = &data.compositor.seat, .resource = touch_resource };
    data.compositor.seat.addTouch(touch) catch {
        data.compositor.allocator.destroy(touch);
        c.wl_resource_destroy(touch_resource);
        return c.wl_resource_post_no_memory(seat_resource);
    };
    c.wl_resource_set_implementation(touch_resource, @ptrCast(&touch_impl), touch, destroyTouch);
}

fn release(_: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    c.wl_resource_destroy(resource);
}

fn setCursor(
    _: ?*c.wl_client,
    _: ?*c.wl_resource,
    _: u32,
    _: ?*c.wl_resource,
    _: i32,
    _: i32,
) callconv(.c) void {}

fn destroyPointer(resource: ?*c.wl_resource) callconv(.c) void {
    const pointer = getData(input.PointerResource, resource orelse return);
    pointer.seat.removePointer(pointer);
    pointer.seat.allocator.destroy(pointer);
}

fn destroyKeyboard(resource: ?*c.wl_resource) callconv(.c) void {
    const keyboard = getData(input.KeyboardResource, resource orelse return);
    keyboard.seat.removeKeyboard(keyboard);
    keyboard.seat.allocator.destroy(keyboard);
}

fn destroyTouch(resource: ?*c.wl_resource) callconv(.c) void {
    const touch = getData(input.TouchResource, resource orelse return);
    touch.seat.removeTouch(touch);
    touch.seat.allocator.destroy(touch);
}

fn destroySeat(resource: ?*c.wl_resource) callconv(.c) void {
    const data = getData(Resource, resource orelse return);
    data.compositor.allocator.destroy(data);
}

var seat_impl = [_]?*const anyopaque{
    @ptrCast(&getPointer),
    @ptrCast(&getKeyboard),
    @ptrCast(&getTouch),
    @ptrCast(&release),
};

var pointer_impl = [_]?*const anyopaque{
    @ptrCast(&setCursor),
    @ptrCast(&release),
};

var keyboard_impl = [_]?*const anyopaque{@ptrCast(&release)};
var touch_impl = [_]?*const anyopaque{@ptrCast(&release)};

fn bind(client: ?*c.wl_client, context: ?*anyopaque, requested: u32, id: u32) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(context orelse return));
    const resource = c.wl_resource_create(
        client,
        &c.wl_seat_interface,
        @intCast(@min(requested, version)),
        id,
    ) orelse return c.wl_client_post_no_memory(client);

    const data = compositor.allocator.create(Resource) catch {
        c.wl_resource_destroy(resource);
        return c.wl_client_post_no_memory(client);
    };
    data.* = .{ .compositor = compositor };
    c.wl_resource_set_implementation(resource, @ptrCast(&seat_impl), data, destroySeat);
    c.wl_seat_send_capabilities(
        resource,
        c.WL_SEAT_CAPABILITY_POINTER |
            c.WL_SEAT_CAPABILITY_KEYBOARD |
            c.WL_SEAT_CAPABILITY_TOUCH,
    );
    if (requested >= 2) c.wl_seat_send_name(resource, "seat0");
}

pub fn register(compositor: *Compositor) !void {
    _ = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wl_seat_interface,
        version,
        compositor,
        bind,
    );
}

fn getData(comptime T: type, resource: *c.wl_resource) *T {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
}
