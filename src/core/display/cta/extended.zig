//! CTA-861 miscellaneous extended data blocks
//!
//! This module handles less common extended blocks that don't warrant
//! their own dedicated module.

const std = @import("std");
const testing = std.testing;

/// InfoFrame Data Block
/// Provides InfoFrame types supported by the display
pub const InfoFrame = struct {
    /// VSI (Vendor-Specific InfoFrame) support
    supports_vsi: bool,
    
    /// AVI (Auxiliary Video Information) InfoFrame version
    avi_version: u8,
    
    /// SPD (Source Product Description) InfoFrame version
    spd_version: u8,
    
    /// Audio InfoFrame version
    audio_version: u8,
    
    /// MPEG Source InfoFrame version
    mpeg_version: u8,
    
    /// Parse from extended block data
    pub fn parse(data: []const u8) ?InfoFrame {
        if (data.len < 1) return null;
        
        var info = InfoFrame{
            .supports_vsi = false,
            .avi_version = 0,
            .spd_version = 0,
            .audio_version = 0,
            .mpeg_version = 0,
        };
        
        // Simple implementation - just detect presence
        if (data.len > 0) {
            info.supports_vsi = (data[0] & 0x01) != 0;
        }
        
        return info;
    }
};

/// Native Video Resolution
/// Indicates the preferred native resolution
pub const NativeVideoResolution = struct {
    /// Preferred horizontal resolution
    h_pixels: u16,
    
    /// Preferred vertical resolution
    v_pixels: u16,
    
    /// Parse from extended block data
    pub fn parse(data: []const u8) ?NativeVideoResolution {
        if (data.len < 4) return null;
        
        const h_pixels = @as(u16, data[0]) | (@as(u16, data[1]) << 8);
        const v_pixels = @as(u16, data[2]) | (@as(u16, data[3]) << 8);
        
        return NativeVideoResolution{
            .h_pixels = h_pixels,
            .v_pixels = v_pixels,
        };
    }
};

/// Video Format Preference
/// Lists VICs in preference order
pub const VideoFormatPreference = struct {
    /// VIC codes in preference order
    vics: []const u8,
    
    pub fn parse(data: []const u8) VideoFormatPreference {
        return VideoFormatPreference{ .vics = data };
    }
};

// Tests

test "InfoFrame parsing" {
    const data = [_]u8{ 0x01 }; // VSI support
    
    const info = InfoFrame.parse(&data).?;
    try testing.expect(info.supports_vsi);
}

test "Native video resolution parsing" {
    // 1920x1080
    const data = [_]u8{
        0x80, 0x07, // 1920 (little-endian)
        0x38, 0x04, // 1080 (little-endian)
    };
    
    const res = NativeVideoResolution.parse(&data).?;
    
    try testing.expectEqual(@as(u16, 1920), res.h_pixels);
    try testing.expectEqual(@as(u16, 1080), res.v_pixels);
}

test "Video format preference parsing" {
    const data = [_]u8{ 16, 4, 31 }; // Preference order
    
    const pref = VideoFormatPreference.parse(&data);
    
    try testing.expectEqual(@as(usize, 3), pref.vics.len);
    try testing.expectEqual(@as(u8, 16), pref.vics[0]);
}
