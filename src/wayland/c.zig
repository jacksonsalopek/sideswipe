//! C bindings for libwayland-server

pub const c = @cImport({
    @cInclude("wayland-server-core.h");
});
