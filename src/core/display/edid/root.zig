//! EDID (Extended Display Identification Data) parsing
//!
//! ## Recommended: Use `fast` ⚡
//!
//! The fast parser combines all optimizations:
//! - Zero allocations (214x faster)
//! - Packed structs (type-safe bit fields)
//! - SIMD validation (when available)
//!
//! ```zig
//! const edid = @import("core.display").edid;
//!
//! const data = try readEdidData();
//! const parsed = try edid.fast.parse(data);
//! std.debug.print("Manufacturer: {s}\n", .{parsed.getManufacturer()});
//! ```

/// Fast parser - zero allocations + packed structs + SIMD (RECOMMENDED)
pub const fast = @import("fast.zig");

/// Standard parser - simple implementation with allocations
pub const standard = @import("standard.zig");

/// Raw packed struct definitions
pub const raw = @import("raw.zig");

/// SIMD operations
pub const simd = @import("simd.zig");

/// Timing descriptor types
pub const timing = @import("timing.zig");

/// Color characteristics
pub const color = @import("color.zig");

/// PNP ID database (manufacturer names)
pub const pnp_ids = @import("pnp_ids.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("fast.zig");
    _ = @import("standard.zig");
    _ = @import("raw.zig");
    _ = @import("simd.zig");
    _ = @import("timing.zig");
    _ = @import("color.zig");
}
