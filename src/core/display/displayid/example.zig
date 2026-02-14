//! DisplayID v1/v2 parsing example
//!
//! Demonstrates parsing DisplayID sections with product info,
//! display parameters, and timing data blocks.

const std = @import("std");
const displayid = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example: Create a DisplayID v2.0 section with multiple data blocks
    var data = try allocator.alloc(u8, 256);
    defer allocator.free(data);
    @memset(data, 0);

    // Build DisplayID v2.0 section
    var offset: usize = 0;

    // Section header
    data[offset + 0] = 0x20; // DisplayID v2.0
    data[offset + 1] = 0; // Section length (will update)
    data[offset + 2] = 0x02; // Product type: Display
    data[offset + 3] = 0; // No extensions
    data[offset + 4] = 0; // Reserved
    offset += 5;

    const data_start = offset;

    // Data block 1: Product Identification (v2, tag 0x20)
    data[offset + 0] = 0x20; // Tag
    data[offset + 1] = 0x00; // Revision 0
    data[offset + 2] = 0x06; // Payload length = 12
    offset += 3;

    // Product ID payload
    @memcpy(data[offset..][0..3], "ABC"); // Vendor
    data[offset + 3] = 0x01; // Product code
    data[offset + 4] = 0x00;
    data[offset + 5] = 0x78; // Serial
    data[offset + 6] = 0x56;
    data[offset + 7] = 0x34;
    data[offset + 8] = 0x12;
    data[offset + 9] = 0x01; // Week
    data[offset + 10] = 0xE7; // Year 2023
    data[offset + 11] = 0x07;
    offset += 12;

    // Data block 2: Display Parameters (v2, tag 0x21)
    data[offset + 0] = 0x21; // Tag
    data[offset + 1] = 0x00; // Revision 0
    data[offset + 2] = 0x06; // Payload length = 12
    offset += 3;

    // Display params payload (1920x1080, 60cm x 34cm)
    data[offset + 0] = 0x70; // H image 600mm
    data[offset + 1] = 0x17;
    data[offset + 2] = 0x48; // V image 340mm
    data[offset + 3] = 0x0D;
    data[offset + 4] = 0x80; // H pixels 1920
    data[offset + 5] = 0x07;
    data[offset + 6] = 0x38; // V pixels 1080
    data[offset + 7] = 0x04;
    data[offset + 8] = 0x90; // Features: audio + power mgmt
    data[offset + 9] = 0x00;
    data[offset + 10] = 0x00;
    data[offset + 11] = 0x00;
    offset += 12;

    // Update section length
    const data_length = offset - data_start;
    data[1] = @intCast(data_length);

    // Parse the section
    std.debug.print("DisplayID v1/v2 Parsing Example\n", .{});
    std.debug.print("================================\n\n", .{});

    const section = displayid.Section.parse(data) orelse {
        std.debug.print("Failed to parse DisplayID section\n", .{});
        return;
    };

    // Display section info
    const version = section.getVersion();
    std.debug.print("DisplayID Version: {}\n", .{@intFromEnum(version)});
    std.debug.print("Is v2: {}\n", .{section.isV2()});
    std.debug.print("Section length: {} bytes\n\n", .{section.header.section_length});

    // Iterate through data blocks
    var iter = section.blocks();
    var block_num: usize = 1;

    while (iter.next()) |block| {
        std.debug.print("Data Block #{}\n", .{block_num});
        std.debug.print("  Tag: 0x{X:0>2}\n", .{block.tag});
        std.debug.print("  Revision: {}\n", .{block.revision});
        std.debug.print("  Payload length: {} bytes\n", .{block.data.len});

        // Parse specific block types
        if (block.isProductId(section.isV2())) {
            if (block.asProductId()) |product| {
                std.debug.print("  Type: Product Identification\n", .{});
                std.debug.print("    Vendor: {s}\n", .{product.vendor});
                std.debug.print("    Product code: 0x{X:0>4}\n", .{product.product_code});
                std.debug.print("    Serial: 0x{X:0>8}\n", .{product.serial_number});
                std.debug.print("    Model year: {}\n", .{product.model_year});
                if (product.model_string) |model| {
                    std.debug.print("    Model: {s}\n", .{model});
                }
            }
        } else if (block.isDisplayParams(section.isV2())) {
            if (block.asDisplayParams()) |params| {
                std.debug.print("  Type: Display Parameters\n", .{});
                std.debug.print("    Size: {}mm x {}mm\n", .{ params.h_image_mm, params.v_image_mm });
                std.debug.print("    Resolution: {}x{}\n", .{ params.h_pixels, params.v_pixels });
                std.debug.print("    Audio support: {}\n", .{params.audio_support});
                std.debug.print("    Power management: {}\n", .{params.power_management});
                std.debug.print("    Fixed timing: {}\n", .{params.fixed_timing});
            }
        } else if (block.isV2Timing()) {
            std.debug.print("  Type: Timing block (v2)\n", .{});
            const timing_tag = @as(displayid.V2DataBlockTag, @enumFromInt(block.tag));
            std.debug.print("    Timing type: {s}\n", .{@tagName(timing_tag)});
        } else if (block.isV1Timing()) {
            std.debug.print("  Type: Timing block (v1)\n", .{});
            const timing_tag = @as(displayid.V1DataBlockTag, @enumFromInt(block.tag));
            std.debug.print("    Timing type: {s}\n", .{@tagName(timing_tag)});
        }

        std.debug.print("\n", .{});
        block_num += 1;
    }

    // Example: Parse specific timing types
    std.debug.print("Timing Examples\n", .{});
    std.debug.print("===============\n\n", .{});

    // Type I timing example (1920x1080@60Hz)
    {
        var timing_data: [20]u8 = undefined;
        
        // Pixel clock: 148.5 MHz, raw = 14849
        timing_data[0] = 0x01;
        timing_data[1] = 0x3A;
        timing_data[2] = 0x00;
        
        // Options: preferred + 16:9 aspect
        timing_data[3] = 0x84;
        
        // H active: 1920 (stored as 1919)
        timing_data[4] = 0x7F;
        timing_data[5] = 0x07;
        
        // H blank: 280 (stored as 279)
        timing_data[6] = 0x17;
        timing_data[7] = 0x01;
        
        // H sync offset: 88 (stored as 87), positive polarity
        timing_data[8] = 0x57;
        timing_data[9] = 0x80;
        
        // H sync width: 44 (stored as 43)
        timing_data[10] = 0x2B;
        timing_data[11] = 0x00;
        
        // V active: 1080 (stored as 1079)
        timing_data[12] = 0x37;
        timing_data[13] = 0x04;
        
        // V blank: 45 (stored as 44)
        timing_data[14] = 0x2C;
        timing_data[15] = 0x00;
        
        // V sync offset: 4 (stored as 3), positive polarity
        timing_data[16] = 0x03;
        timing_data[17] = 0x80;
        
        // V sync width: 5 (stored as 4)
        timing_data[18] = 0x04;
        timing_data[19] = 0x00;

        if (displayid.timing.TypeITiming.parse(&timing_data)) |timing| {
            std.debug.print("Type I Timing (Detailed):\n", .{});
            std.debug.print("  {}x{}@{d}.{d:0>3}Hz\n", .{
                timing.h_active,
                timing.v_active,
                timing.getRefreshRate() / 1000,
                timing.getRefreshRate() % 1000,
            });
            std.debug.print("  Pixel clock: {d}.{d:0>2} MHz\n", .{
                timing.pixel_clock_hz / 1_000_000,
                (timing.pixel_clock_hz % 1_000_000) / 10_000,
            });
            std.debug.print("  Aspect ratio: {}:{}\n", .{
                timing.aspect_ratio.h,
                timing.aspect_ratio.v,
            });
            std.debug.print("  Stereo 3D: {s}\n", .{@tagName(timing.stereo_3d)});
            std.debug.print("  Preferred: {}\n", .{timing.preferred});
            std.debug.print("  Interlaced: {}\n\n", .{timing.interlaced});
        }
    }

    // Type III timing example (CVT)
    // Note: Type III doesn't directly encode V active, the standard
    // derives it from H active and aspect ratio
    {
        const timing_data = [_]u8{
            (1920 / 8) - 31, // H active: 1920/8 - 31 = 209
            (3 << 4) | 0, // 16:9 aspect ratio + base vertical
            ((60 - 60) << 2) | 0, // 60Hz + CVT
        };

        if (displayid.timing.TypeIIITiming.parse(&timing_data)) |timing| {
            std.debug.print("Type III Timing (Short/Formula):\n", .{});
            std.debug.print("  {}x{}@{}Hz\n", .{
                timing.h_active,
                timing.v_active,
                timing.refresh_rate_hz,
            });
            std.debug.print("  Aspect ratio: {}:{}\n", .{
                timing.aspect_ratio.h,
                timing.aspect_ratio.v,
            });
            std.debug.print("  Formula: {s}\n\n", .{@tagName(timing.formula)});
        }
    }

    std.debug.print("DisplayID parsing complete!\n", .{});
}
