const std = @import("std");
const c = @import("c.zig").c;

pub const Client = struct {
    handle: *c.wl_client,

    pub const Error = error{
        CreateFailed,
    };

    /// Creates a new client from a file descriptor.
    /// The display takes ownership of the fd.
    pub fn create(display: *c.wl_display, fd: i32) Error!Client {
        const handle = c.wl_client_create(display, fd) orelse return error.CreateFailed;
        return Client{ .handle = handle };
    }

    /// Wraps an existing client handle.
    pub fn wrap(handle: *c.wl_client) Client {
        return Client{ .handle = handle };
    }

    /// Destroys the client connection.
    pub fn destroy(self: *Client) void {
        c.wl_client_destroy(self.handle);
    }

    /// Flushes pending events to the client.
    pub fn flush(self: *Client) void {
        c.wl_client_flush(self.handle);
    }

    /// Gets the display associated with this client.
    pub fn getDisplay(self: *Client) ?*c.wl_display {
        return c.wl_client_get_display(self.handle);
    }

    /// Gets the file descriptor for this client connection.
    pub fn getFd(self: *Client) i32 {
        return c.wl_client_get_fd(self.handle);
    }

    /// Gets a resource by its object ID.
    pub fn getObject(self: *Client, id: u32) ?*c.wl_resource {
        return c.wl_client_get_object(self.handle, id);
    }

    /// Posts an out-of-memory error to the client.
    pub fn postNoMemory(self: *Client) void {
        c.wl_client_post_no_memory(self.handle);
    }
};
