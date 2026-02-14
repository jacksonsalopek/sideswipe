//! Display information parsing and management
//!
//! This module provides functionality for parsing and interpreting display
//! identification data including EDID (Extended Display Identification Data)
//! and DisplayID standards.
//!
//! ## Recommended: Use `edid.fast` ⚡
//!
//! ```zig
//! const display = @import("core.display");
//!
//! const data = try readEdidData();
//! const parsed = try display.edid.fast.parse(data);
//! std.debug.print("Manufacturer: {s}\n", .{parsed.getManufacturer()});
//! ```

pub const edid = @import("edid/root.zig");
pub const cta = @import("cta/root.zig");
pub const cvt = @import("cvt.zig");
pub const gtf = @import("gtf.zig");
pub const displayid = @import("displayid/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("edid/root.zig");
    _ = @import("cta/root.zig");
    _ = @import("cvt.zig");
    _ = @import("gtf.zig");
    _ = @import("displayid/root.zig");
}
