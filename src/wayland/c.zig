//! C bindings for libwayland-server

pub const c = @cImport({
    @cInclude("wayland-server-core.h");
    @cInclude("wayland-server-protocol.h");
    @cInclude("wayland-client-core.h");
    @cInclude("wayland-client-protocol.h");
    @cInclude("xdg-shell-protocol.h");
    @cInclude("linux-dmabuf-unstable-v1-protocol.h");
    @cInclude("xdg-activation-v1-protocol.h");
    @cInclude("viewporter-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("fractional-scale-v1-protocol.h");
    @cInclude("sideswipe-shell-v1-protocol.h");
    @cInclude("xdg-dialog-v1-protocol.h");
    @cInclude("xdg-decoration-unstable-v1-protocol.h");
    @cInclude("color-management-v1-protocol.h");
    @cInclude("color-representation-v1-protocol.h");
    @cInclude("tearing-control-v1-protocol.h");
    @cInclude("ext-session-lock-v1-protocol.h");
    @cInclude("ext-idle-notify-v1-protocol.h");
    @cInclude("sys/stat.h");
});
