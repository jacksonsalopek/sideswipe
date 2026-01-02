const std = @import("std");
const c = @import("c.zig").c;

pub const Global = struct {
    handle: *c.wl_global,

    pub const Error = error{
        CreateFailed,
    };

    /// Callback type for when a client binds to a global.
    pub const BindCallback = *const fn (?*c.wl_client, ?*anyopaque, u32, u32) callconv(.C) void;

    /// Creates a new global object.
    /// The global will be advertised to all clients.
    ///
    /// Parameters:
    /// - display: The Wayland display handle
    /// - interface: The protocol interface (e.g., &c.wl_compositor_interface)
    /// - version: The version of the interface to advertise
    /// - data: User data passed to the bind callback
    /// - bind_callback: Called when a client binds to this global
    pub fn create(
        display: *c.wl_display,
        interface: *const c.wl_interface,
        version: i32,
        data: ?*anyopaque,
        bind_callback: BindCallback,
    ) Error!Global {
        const handle = c.wl_global_create(display, interface, version, data, bind_callback) orelse return error.CreateFailed;
        return Global{ .handle = handle };
    }

    /// Removes the global from the registry and destroys it immediately.
    /// Existing bindings remain valid.
    pub fn destroy(self: *Global) void {
        c.wl_global_destroy(self.handle);
    }

    /// Removes the global from the registry without destroying it.
    /// New clients won't see it, but existing bindings remain.
    /// Call destroy() after remove() when ready to clean up.
    pub fn remove(self: *Global) void {
        c.wl_global_remove(self.handle);
    }
};
