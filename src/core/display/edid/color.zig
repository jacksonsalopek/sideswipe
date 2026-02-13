//! EDID color characteristics and chromaticity coordinates

const std = @import("std");
const testing = std.testing;

/// CIE 1931 chromaticity coordinates
pub const ChromaticityCoords = struct {
    red_x: f32,
    red_y: f32,
    green_x: f32,
    green_y: f32,
    blue_x: f32,
    blue_y: f32,
    white_x: f32,
    white_y: f32,
};

/// Decode a 10-bit chromaticity coordinate to float (0.0 - 1.0)
inline fn decodeChromaCoord(high: u8, low: u2) f32 {
    const value = (@as(u16, high) << 2) | low;
    return @as(f32, @floatFromInt(value)) / 1024.0;
}

/// Parse chromaticity coordinates from EDID color characteristics (10 bytes)
///
/// EDID bytes 0x19-0x22 contain packed chromaticity data:
/// - Byte 0x19: Red/Green low bits
/// - Byte 0x1A: Blue/White low bits  
/// - Bytes 0x1B-0x22: High 8 bits for each coordinate
pub fn parseChromaticityCoords(data: *align(1) const [10]u8) ChromaticityCoords {
    // Byte 0: red_x(7:6), red_y(5:4), green_x(3:2), green_y(1:0)
    const rg_low = data[0];
    // Byte 1: blue_x(7:6), blue_y(5:4), white_x(3:2), white_y(1:0)
    const bw_low = data[1];
    
    return ChromaticityCoords{
        .red_x = decodeChromaCoord(data[2], @intCast((rg_low >> 6) & 0x03)),
        .red_y = decodeChromaCoord(data[3], @intCast((rg_low >> 4) & 0x03)),
        .green_x = decodeChromaCoord(data[4], @intCast((rg_low >> 2) & 0x03)),
        .green_y = decodeChromaCoord(data[5], @intCast(rg_low & 0x03)),
        .blue_x = decodeChromaCoord(data[6], @intCast((bw_low >> 6) & 0x03)),
        .blue_y = decodeChromaCoord(data[7], @intCast((bw_low >> 4) & 0x03)),
        .white_x = decodeChromaCoord(data[8], @intCast((bw_low >> 2) & 0x03)),
        .white_y = decodeChromaCoord(data[9], @intCast(bw_low & 0x03)),
    };
}

// Tests

test "chromaticity coordinate decoding" {
    // Test decoding: high = 0xFF, low = 0b11 = 1023/1024 ≈ 0.999
    const coord = decodeChromaCoord(0xFF, 0b11);
    try testing.expect(coord > 0.998 and coord < 1.0);
    
    // Test: high = 0x00, low = 0b00 = 0/1024 = 0.0
    const zero = decodeChromaCoord(0x00, 0b00);
    try testing.expectEqual(@as(f32, 0.0), zero);
    
    // Test: high = 0x80, low = 0b00 = 512/1024 = 0.5
    const half = decodeChromaCoord(0x80, 0b00);
    try testing.expectEqual(@as(f32, 0.5), half);
}

test "parse chromaticity coords" {
    var data: [10]u8 = undefined;
    
    // Test with specific bit patterns to verify decoding
    // Low bits: 0b11001100 = red_x=11, red_y=00, green_x=11, green_y=00
    data[0] = 0xC0; // red_x=11, rest=00
    data[1] = 0x00; // all zeros
    
    // High bits: Use simple values to verify formula
    data[2] = 0xFF; // red_x high = 0xFF
    data[3] = 0x00; // red_y high = 0x00
    data[4] = 0x00; // green_x high = 0x00  
    data[5] = 0x00; // green_y high = 0x00
    data[6] = 0x00; // blue_x high = 0x00
    data[7] = 0x00; // blue_y high = 0x00
    data[8] = 0x80; // white_x high = 0x80
    data[9] = 0x80; // white_y high = 0x80
    
    const coords = parseChromaticityCoords(&data);
    
    // red_x = (0xFF << 2) | 0b11 = 1023 → 1023/1024 ≈ 0.999
    try testing.expect(coords.red_x > 0.998 and coords.red_x < 1.0);
    
    // red_y = (0x00 << 2) | 0b00 = 0 → 0/1024 = 0.0
    try testing.expectEqual(@as(f32, 0.0), coords.red_y);
    
    // white_x = (0x80 << 2) | 0b00 = 512 → 512/1024 = 0.5
    try testing.expectEqual(@as(f32, 0.5), coords.white_x);
    
    // white_y = (0x80 << 2) | 0b00 = 512 → 512/1024 = 0.5
    try testing.expectEqual(@as(f32, 0.5), coords.white_y);
}
