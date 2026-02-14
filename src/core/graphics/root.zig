//! Graphics utilities
//!
//! Provides color space conversions, color management,
//! and graphics-related utilities.

pub const color = @import("color.zig");

// Re-export commonly used types
pub const Color = color.Color;
pub const SRGB = color.SRGB;
pub const HSL = color.HSL;
pub const OkLab = color.OkLab;
pub const Primaries = color.Primaries;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("color.zig");
}
