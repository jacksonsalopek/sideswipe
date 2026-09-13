//! Client C bindings for the privileged shell.

pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-client-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("linux-dmabuf-unstable-v1-client-protocol.h");
    @cInclude("sideswipe-shell-v1-client-protocol.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});
