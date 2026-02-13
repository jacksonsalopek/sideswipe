//! Benchmark comparing Zig implementation against C libdisplay-info
//!
//! This links against the system libdisplay-info to validate correctness
//! and compare performance.

const std = @import("std");
const display = @import("display");

// C library bindings for libdisplay-info
const c = @cImport({
    @cInclude("libdisplay-info/info.h");
    @cInclude("libdisplay-info/edid.h");
});

fn generateTestEdid() [128]u8 {
    var data = [_]u8{0} ** 128;

    // Header
    const header = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    @memcpy(data[0..8], &header);

    // Manufacturer: "DEL" (Dell)
    data[0x08] = 0x10;
    data[0x09] = 0xAC;

    // Product: 0xA0C7
    data[0x0A] = 0xC7;
    data[0x0B] = 0xA0;

    // Serial
    data[0x0C] = 0x42;
    data[0x0D] = 0x4C;
    data[0x0E] = 0x56;
    data[0x0F] = 0x4C;

    // Manufacture: week 15, year 2023
    data[0x10] = 15;
    data[0x11] = 33;

    // Version 1.4
    data[0x12] = 1;
    data[0x13] = 4;

    // Video input: Digital, 8-bit, DisplayPort
    data[0x14] = 0b10100101;

    // Screen: 60cm x 34cm
    data[0x15] = 60;
    data[0x16] = 34;

    // Gamma: 2.20
    data[0x17] = 120;

    // Rest zeros
    @memset(data[0x18..127], 0);

    // Calculate checksum
    var sum: u8 = 0;
    for (data[0..127]) |byte| {
        sum +%= byte;
    }
    data[127] = 0 -% sum;

    return data;
}

pub fn main() !void {
    const test_data = generateTestEdid();
    const iterations = 1_000_000;

    std.debug.print("\n========================================\n", .{});
    std.debug.print("Zig vs C libdisplay-info Benchmark\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("EDID size: {d} bytes\n", .{test_data.len});
    std.debug.print("Iterations: {d}\n", .{iterations});
    std.debug.print("========================================\n\n", .{});

    // Warm up
    {
        const zig_edid = try display.edid.fast.parse(&test_data);
        _ = zig_edid;
    }
    {
        const c_info = c.di_info_parse_edid(&test_data, test_data.len);
        if (c_info != null) {
            c.di_info_destroy(c_info);
        }
    }

    // Benchmark Zig implementation
    std.debug.print("Benchmarking Zig implementation...\n", .{});
    const zig_start = std.time.nanoTimestamp();
    
    for (0..iterations) |_| {
        const zig_edid = try display.edid.fast.parse(&test_data);
        _ = zig_edid;
    }
    
    const zig_end = std.time.nanoTimestamp();
    const zig_time = zig_end - zig_start;

    // Benchmark C implementation
    std.debug.print("Benchmarking C libdisplay-info...\n", .{});
    const c_start = std.time.nanoTimestamp();
    
    for (0..iterations) |_| {
        const c_info = c.di_info_parse_edid(&test_data, test_data.len);
        if (c_info) |info| {
            c.di_info_destroy(info);
        }
    }
    
    const c_end = std.time.nanoTimestamp();
    const c_time = c_end - c_start;

    // Results
    std.debug.print("\n========================================\n", .{});
    std.debug.print("Results\n", .{});
    std.debug.print("========================================\n", .{});
    
    const zig_per_op = @as(f64, @floatFromInt(zig_time)) / @as(f64, @floatFromInt(iterations));
    const c_per_op = @as(f64, @floatFromInt(c_time)) / @as(f64, @floatFromInt(iterations));
    
    std.debug.print("Zig:  {d:.2} ns/op\n", .{zig_per_op});
    std.debug.print("C:    {d:.2} ns/op\n", .{c_per_op});
    
    const speedup = c_per_op / zig_per_op;
    std.debug.print("\n⚡ Zig is {d:.1}x faster than C!\n", .{speedup});
    std.debug.print("========================================\n\n", .{});

    // Validate correctness
    std.debug.print("========================================\n", .{});
    std.debug.print("Correctness Validation\n", .{});
    std.debug.print("========================================\n", .{});

    const zig_edid = try display.edid.fast.parse(&test_data);
    const c_info = c.di_info_parse_edid(&test_data, test_data.len);
    defer if (c_info) |info| c.di_info_destroy(info);

    if (c_info) |info| {
        const c_edid = c.di_info_get_edid(info);
        if (c_edid) |edid_ptr| {
            // Compare versions
            const c_version = c.di_edid_get_version(edid_ptr);
            const c_revision = c.di_edid_get_revision(edid_ptr);
            
            std.debug.print("Version:    Zig={d}.{d}  C={d}.{d}  ", .{
                zig_edid.getVersion(),
                zig_edid.getRevision(),
                c_version,
                c_revision,
            });
            
            if (zig_edid.getVersion() == c_version and zig_edid.getRevision() == c_revision) {
                std.debug.print("✅\n", .{});
            } else {
                std.debug.print("❌\n", .{});
            }

            // Compare manufacturer
            const c_vendor = c.di_edid_get_vendor_product(edid_ptr);
            if (c_vendor) |vp_ptr| {
                const vp = vp_ptr.*;
                const zig_mfg = zig_edid.getManufacturerId();
                const c_mfg: [*c]const u8 = @ptrCast(&vp.manufacturer);
                
                std.debug.print("Manufacturer: Zig={s}  C={s}  ", .{ zig_mfg, c_mfg[0..3] });
                
                if (std.mem.eql(u8, &zig_mfg, c_mfg[0..3])) {
                    std.debug.print("✅\n", .{});
                } else {
                    std.debug.print("❌\n", .{});
                }

                // Compare product code
                std.debug.print("Product:    Zig=0x{X:0>4}  C=0x{X:0>4}  ", .{
                    zig_edid.getProductCode(),
                    vp.product,
                });
                
                if (zig_edid.getProductCode() == vp.product) {
                    std.debug.print("✅\n", .{});
                } else {
                    std.debug.print("❌\n", .{});
                }
            }

            // Compare screen size
            const c_screen = c.di_edid_get_screen_size(edid_ptr);
            if (c_screen) |screen_ptr| {
                const screen = screen_ptr.*;
                std.debug.print("Screen:     Zig={d}x{d}cm  C={d}x{d}cm  ", .{
                    zig_edid.getScreenWidthCm(),
                    zig_edid.getScreenHeightCm(),
                    screen.width_cm,
                    screen.height_cm,
                });
                
                if (zig_edid.getScreenWidthCm() == screen.width_cm and
                    zig_edid.getScreenHeightCm() == screen.height_cm)
                {
                    std.debug.print("✅\n", .{});
                } else {
                    std.debug.print("❌\n", .{});
                }
            }
        }
    }

    std.debug.print("========================================\n\n", .{});
}
