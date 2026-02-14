//! wl_data_device_manager protocol implementation
//! Handles clipboard and drag-and-drop functionality

const std = @import("std");
const wayland = @import("wayland");
const c = wayland.c;

const Compositor = @import("../compositor.zig").Compositor;

// wl_data_device_manager interface version we support
const WL_DATA_DEVICE_MANAGER_VERSION = 3;

// User data structures
// Note: All user data structs are allocated/freed with compositor.allocator

/// User data attached to wl_data_device_manager resources
const ManagerData = struct {
    compositor: *Compositor,
};

/// User data attached to wl_data_source resources
const SourceData = struct {
    manager_data: *ManagerData,
};

/// User data attached to wl_data_device resources
const DeviceData = struct {
    manager_data: *ManagerData,
};

// wl_data_device_manager request handlers

fn managerCreateDataSource(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
) callconv(.c) void {
    _ = client;

    const data: *ManagerData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;
    comp.logger.debug("Client requested wl_data_source", .{});

    // Create wl_data_source resource
    const source_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_data_source_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    const source_data = comp.allocator.create(SourceData) catch {
        c.wl_resource_destroy(source_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    source_data.* = .{ .manager_data = data };

    c.wl_resource_set_implementation(
        source_resource,
        @ptrCast(&source_implementation),
        source_data,
        sourceResourceDestroy,
    );
}

fn managerGetDataDevice(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    id: u32,
    seat: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    _ = seat; // TODO: Associate device with seat

    const data: *ManagerData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));

    const comp = data.compositor;
    comp.logger.debug("Client requested wl_data_device", .{});

    // Create wl_data_device resource
    const device_resource = c.wl_resource_create(
        c.wl_resource_get_client(resource),
        &c.wl_data_device_interface,
        c.wl_resource_get_version(resource),
        id,
    ) orelse {
        c.wl_resource_post_no_memory(resource);
        return;
    };

    const device_data = comp.allocator.create(DeviceData) catch {
        c.wl_resource_destroy(device_resource);
        c.wl_resource_post_no_memory(resource);
        return;
    };
    device_data.* = .{ .manager_data = data };

    c.wl_resource_set_implementation(
        device_resource,
        @ptrCast(&device_implementation),
        device_data,
        deviceResourceDestroy,
    );
}

var manager_implementation = [_]?*const anyopaque{
    @ptrCast(&managerCreateDataSource),
    @ptrCast(&managerGetDataDevice),
};

// wl_data_source request handlers (stubs)

fn sourceOffer(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    mime_type: ?[*:0]const u8,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = mime_type;
    // Stub: Store offered MIME types
}

fn sourceDestroy(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn sourceSetActions(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    dnd_actions: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = dnd_actions;
    // Stub: Set drag-and-drop actions (version 3+)
}

var source_implementation = [_]?*const anyopaque{
    @ptrCast(&sourceOffer),
    @ptrCast(&sourceDestroy),
    @ptrCast(&sourceSetActions),
};

fn sourceResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *SourceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.manager_data.compositor.allocator.destroy(data);
}

// wl_data_device request handlers (stubs)

fn deviceStartDrag(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    source: ?*c.wl_resource,
    origin: ?*c.wl_resource,
    icon: ?*c.wl_resource,
    serial: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = source;
    _ = origin;
    _ = icon;
    _ = serial;
    // Stub: Start drag-and-drop operation
}

fn deviceSetSelection(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
    source: ?*c.wl_resource,
    serial: u32,
) callconv(.c) void {
    _ = client;
    _ = resource;
    _ = source;
    _ = serial;
    // Stub: Set clipboard selection
}

fn deviceRelease(
    client: ?*c.wl_client,
    resource: ?*c.wl_resource,
) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

var device_implementation = [_]?*const anyopaque{
    @ptrCast(&deviceStartDrag),
    @ptrCast(&deviceSetSelection),
    @ptrCast(&deviceRelease),
};

fn deviceResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *DeviceData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.manager_data.compositor.allocator.destroy(data);
}

// Global bind handler

fn managerBind(
    client: ?*c.wl_client,
    data: ?*anyopaque,
    version: u32,
    id: u32,
) callconv(.c) void {
    const compositor: *Compositor = @ptrCast(@alignCast(data));

    compositor.logger.debug("Client bound to wl_data_device_manager (version {d})", .{version});

    const resource = c.wl_resource_create(
        client,
        &c.wl_data_device_manager_interface,
        @intCast(@min(version, WL_DATA_DEVICE_MANAGER_VERSION)),
        id,
    ) orelse {
        c.wl_client_post_no_memory(client);
        return;
    };

    const manager_data = compositor.allocator.create(ManagerData) catch {
        c.wl_resource_destroy(resource);
        c.wl_client_post_no_memory(client);
        return;
    };
    manager_data.* = .{ .compositor = compositor };

    c.wl_resource_set_implementation(
        resource,
        @ptrCast(&manager_implementation),
        manager_data,
        managerResourceDestroy,
    );
}

fn managerResourceDestroy(resource: ?*c.wl_resource) callconv(.c) void {
    const data: *ManagerData = @ptrCast(@alignCast(
        c.wl_resource_get_user_data(resource),
    ));
    data.compositor.allocator.destroy(data);
}

/// Registers the wl_data_device_manager global
pub fn register(compositor: *Compositor) !void {
    const global = try wayland.Global.create(
        compositor.server.getDisplay(),
        &c.wl_data_device_manager_interface,
        WL_DATA_DEVICE_MANAGER_VERSION,
        compositor,
        managerBind,
    );
    _ = global; // Global is owned by display, no need to track
}

// Tests

const testing = std.testing;

test "register data_device_manager" {
    // Basic smoke test - would need full Wayland server setup for real test
    _ = WL_DATA_DEVICE_MANAGER_VERSION;
}
