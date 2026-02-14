//! C bindings for libwayland-server

pub const c = @cImport({
    @cInclude("wayland-server-core.h");
    @cInclude("wayland-server-protocol.h");
    @cInclude("xdg-shell-protocol.h");
});
