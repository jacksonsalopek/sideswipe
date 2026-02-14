//! Core backend type definitions
//! Shared types that both backend and ipc modules need

/// Backend type enumeration
pub const Type = enum(u32) {
    wayland = 0,
    drm = 1,
    headless = 2,
    null = 3,
};
