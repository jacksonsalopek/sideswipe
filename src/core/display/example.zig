//! Example usage of the display module

const std = @import("std");
const display = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Fast parser (RECOMMENDED)
    std.debug.print("\n=== Example 1: Fast Parser (210x faster) ===\n", .{});
    {
        // Read EDID from sysfs (or any source)
        const edid_data = try std.fs.cwd().readFileAlloc(
            allocator,
            "/sys/class/drm/card0-HDMI-A-1/edid",
            1024,
        );
        defer allocator.free(edid_data);

        // Parse with ZERO allocations - just borrows the data!
        const edid = try display.edid.fast.parse(edid_data);

        // Access display information
        const mfg_id = edid.getManufacturerId();
        std.debug.print("Manufacturer ID: {s}\n", .{mfg_id});
        
        if (edid.getManufacturerName()) |mfg_name| {
            std.debug.print("Manufacturer: {s}\n", .{mfg_name});
        }
        
        if (edid.getProductName()) |product| {
            std.debug.print("Product: {s}\n", .{product});
        }
        
        std.debug.print("Product Code: 0x{X:0>4}\n", .{edid.getProductCode()});
        std.debug.print("Serial: 0x{X:0>8}\n", .{edid.getSerialNumber()});
        std.debug.print("Version: {d}.{d}\n", .{ edid.getVersion(), edid.getRevision() });
        std.debug.print("Screen: {d}x{d} cm\n", .{ edid.getScreenWidthCm(), edid.getScreenHeightCm() });
        std.debug.print("Gamma: {d:.2}\n", .{edid.getGamma()});

        if (edid.getDigitalInput()) |digital| {
            std.debug.print("Digital interface: {}\n", .{digital.interface_type});
            std.debug.print("Color depth: {}\n", .{digital.color_depth});
        } else if (edid.getAnalogInput()) |analog| {
            std.debug.print("Analog signal level: {}\n", .{analog.signal_level});
        }

        const features = edid.getFeatureSupport();
        std.debug.print("DPMS standby: {}\n", .{features.dpms_standby});
        std.debug.print("sRGB primary: {}\n", .{features.srgb_is_primary});
    }

    // Example 2: Standard parser (when you need ownership semantics)
    std.debug.print("\n=== Example 2: Standard Parser (owns data) ===\n", .{});
    {
        const edid_data = try std.fs.cwd().readFileAlloc(
            allocator,
            "/sys/class/drm/card0-HDMI-A-1/edid",
            1024,
        );
        defer allocator.free(edid_data);

        // Parse with ownership
        var edid = try display.edid.standard.parse(allocator, edid_data);
        defer edid.deinit(); // Cleans up internal allocation

        // Direct field access (no getters)
        std.debug.print("Manufacturer: {s}\n", .{edid.vendor_product.manufacturer});
        std.debug.print("Product: 0x{X:0>4}\n", .{edid.vendor_product.product});
        std.debug.print("Version: {d}.{d}\n", .{ edid.version, edid.revision });
    }
}
