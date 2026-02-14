//! DisplayID Display Parameters Data Block

const std = @import("std");
const testing = std.testing;

/// Display parameters block
pub const Display = struct {
    /// Horizontal image size in mm
    h_image_mm: u16,
    
    /// Vertical image size in mm
    v_image_mm: u16,
    
    /// Horizontal pixel count
    h_pixels: u16,
    
    /// Vertical pixel count
    v_pixels: u16,
    
    /// Feature support flags
    audio_support: bool,
    separate_audio_inputs: bool,
    audio_input_override: bool,
    power_management: bool,
    fixed_timing: bool,
    fixed_pixel_format: bool,
    ai_support: bool,
    deinterlacing: bool,
    
    /// Parse from data block payload (v1.3)
    pub fn parse(data: []const u8) ?Display {
        if (data.len < 12) return null;
        
        // Bytes 0-1: Horizontal image size (0.1mm units)
        const h_image_raw = @as(u16, data[0]) | (@as(u16, data[1]) << 8);
        const h_image_mm = h_image_raw / 10;
        
        // Bytes 2-3: Vertical image size (0.1mm units)
        const v_image_raw = @as(u16, data[2]) | (@as(u16, data[3]) << 8);
        const v_image_mm = v_image_raw / 10;
        
        // Bytes 4-5: Horizontal pixels
        const h_pixels = @as(u16, data[4]) | (@as(u16, data[5]) << 8);
        
        // Bytes 6-7: Vertical pixels
        const v_pixels = @as(u16, data[6]) | (@as(u16, data[7]) << 8);
        
        // Byte 8: Feature support flags
        const features = data[8];
        
        return Display{
            .h_image_mm = h_image_mm,
            .v_image_mm = v_image_mm,
            .h_pixels = h_pixels,
            .v_pixels = v_pixels,
            .audio_support = (features & 0x80) != 0,
            .separate_audio_inputs = (features & 0x40) != 0,
            .audio_input_override = (features & 0x20) != 0,
            .power_management = (features & 0x10) != 0,
            .fixed_timing = (features & 0x08) != 0,
            .fixed_pixel_format = (features & 0x04) != 0,
            .ai_support = (features & 0x02) != 0,
            .deinterlacing = (features & 0x01) != 0,
        };
    }
};

// Tests

test "display parameters parsing" {
    var data: [12]u8 = undefined;
    
    // Image size: 600mm x 340mm (60.0cm x 34.0cm)
    // 6000 * 0.1mm = 600mm
    data[0] = 0x70;
    data[1] = 0x17; // 6000 (little-endian)
    data[2] = 0x48;
    data[3] = 0x0D; // 3400 (little-endian)
    
    // Resolution: 1920x1080
    data[4] = 0x80;
    data[5] = 0x07;
    data[6] = 0x38;
    data[7] = 0x04;
    
    // Features: audio + power management
    data[8] = 0x90; // Bits 7 and 4 set
    
    @memset(data[9..], 0);
    
    const params = Display.parse(&data).?;
    
    try testing.expectEqual(@as(u16, 600), params.h_image_mm);
    try testing.expectEqual(@as(u16, 340), params.v_image_mm);
    try testing.expectEqual(@as(u16, 1920), params.h_pixels);
    try testing.expectEqual(@as(u16, 1080), params.v_pixels);
    try testing.expect(params.audio_support);
    try testing.expect(params.power_management);
    try testing.expect(!params.fixed_timing);
}
