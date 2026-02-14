//! CTA-861 YCbCr 4:2:0 Data Block parsing
//!
//! YCbCr 4:2:0 blocks describe which video modes support 4:2:0 chroma subsampling,
//! which allows higher resolutions over limited bandwidth (e.g., 4K@60Hz over HDMI 2.0).

const std = @import("std");
const testing = std.testing;

/// YCbCr 4:2:0 Video Data Block
/// Lists VICs that ONLY support 4:2:0 (not 4:4:4 or 4:2:2)
pub const VideoBlock = struct {
    /// VIC codes that only support 4:2:0
    vics: []const u8,
    
    /// Parse from extended data block payload
    pub fn parse(data: []const u8) VideoBlock {
        return VideoBlock{ .vics = data };
    }
    
    /// Check if VIC only supports 4:2:0
    pub fn isYcbcr420Only(self: VideoBlock, vic: u8) bool {
        for (self.vics) |v| {
            if (v == vic) return true;
        }
        return false;
    }
};

/// YCbCr 4:2:0 Capability Map Data Block
/// Bitmap indicating which VICs from the video data block support 4:2:0
pub const CapabilityMap = struct {
    /// Bitmap where each bit corresponds to a VIC in the video data block
    bitmap: []const u8,
    
    /// Parse from extended data block payload
    pub fn parse(data: []const u8) CapabilityMap {
        return CapabilityMap{ .bitmap = data };
    }
    
    /// Check if VIC at given index supports 4:2:0
    /// Index refers to position in the video data block SVD list
    pub fn supportsYcbcr420(self: CapabilityMap, svd_index: usize) bool {
        const byte_index = svd_index / 8;
        const bit_index = @as(u3, @intCast(svd_index % 8));
        
        if (byte_index >= self.bitmap.len) return false;
        
        return (self.bitmap[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }
};

// Tests

test "YCbCr 4:2:0 video block" {
    // VICs that only support 4:2:0
    const data = [_]u8{ 96, 97, 101, 102 }; // 4K modes
    
    const block = VideoBlock.parse(&data);
    
    try testing.expect(block.isYcbcr420Only(96));
    try testing.expect(block.isYcbcr420Only(97));
    try testing.expect(!block.isYcbcr420Only(16));
}

test "YCbCr 4:2:0 capability map" {
    // Bitmap: 0b00000101 = VICs at index 0 and 2 support 4:2:0
    const data = [_]u8{ 0b00000101 };
    
    const cap_map = CapabilityMap.parse(&data);
    
    try testing.expect(cap_map.supportsYcbcr420(0));  // Bit 0 set
    try testing.expect(!cap_map.supportsYcbcr420(1)); // Bit 1 clear
    try testing.expect(cap_map.supportsYcbcr420(2));  // Bit 2 set
    try testing.expect(!cap_map.supportsYcbcr420(3)); // Bit 3 clear
}

test "YCbCr 4:2:0 capability map - multi-byte" {
    // 16 VICs: first byte all set, second byte first bit set
    const data = [_]u8{ 0xFF, 0x01 };
    
    const cap_map = CapabilityMap.parse(&data);
    
    try testing.expect(cap_map.supportsYcbcr420(7));  // Last bit of first byte
    try testing.expect(cap_map.supportsYcbcr420(8));  // First bit of second byte
    try testing.expect(!cap_map.supportsYcbcr420(9)); // Second bit of second byte
}
