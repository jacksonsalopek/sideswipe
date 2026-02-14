//! CTA-861 HDR Static Metadata Data Block parsing
//!
//! HDR metadata blocks describe HDR capabilities including supported
//! EOTFs (Electro-Optical Transfer Functions) and luminance ranges.

const std = @import("std");
const testing = std.testing;

/// Supported EOTFs (Electro-Optical Transfer Functions)
pub const Eotfs = packed struct(u8) {
    /// Traditional gamma - SDR
    traditional_sdr: bool,
    /// Traditional gamma - HDR
    traditional_hdr: bool,
    /// SMPTE ST 2084 (PQ)
    smpte_st_2084: bool,
    /// Hybrid Log-Gamma (HLG)
    hlg: bool,
    _reserved: u4,
};

/// Static metadata descriptors
pub const StaticMetadataDescriptors = packed struct(u8) {
    /// Static Metadata Type 1
    type1: bool,
    _reserved: u7,
};

/// HDR Static Metadata Data Block
pub const StaticMetadata = struct {
    /// Supported EOTFs
    eotfs: Eotfs,
    
    /// Supported static metadata descriptors
    descriptors: StaticMetadataDescriptors,
    
    /// Desired content max luminance (cd/m²), 0 if unset
    max_luminance_cdm2: f32,
    
    /// Desired content max frame-average luminance (cd/m²), 0 if unset
    max_frame_avg_luminance_cdm2: f32,
    
    /// Desired content min luminance (cd/m²), 0 if unset
    min_luminance_cdm2: f32,
    
    /// Parse from extended data block payload
    pub fn parse(data: []const u8) ?StaticMetadata {
        // Must have at least 2 bytes (EOTFs + descriptors)
        if (data.len < 2) return null;
        
        var metadata = StaticMetadata{
            .eotfs = @bitCast(data[0]),
            .descriptors = @bitCast(data[1]),
            .max_luminance_cdm2 = 0,
            .max_frame_avg_luminance_cdm2 = 0,
            .min_luminance_cdm2 = 0,
        };
        
        // Desired content max luminance (optional, byte 2)
        if (data.len >= 3 and data[2] > 0) {
            metadata.max_luminance_cdm2 = decodeLuminance(data[2]);
        }
        
        // Desired content max frame-avg luminance (optional, byte 3)
        if (data.len >= 4 and data[3] > 0) {
            metadata.max_frame_avg_luminance_cdm2 = decodeLuminance(data[3]);
        }
        
        // Desired content min luminance (optional, byte 4)
        if (data.len >= 5 and data[4] > 0) {
            metadata.min_luminance_cdm2 = decodeMinLuminance(data[4]);
        }
        
        return metadata;
    }
    
    /// Check if HDR10 is supported (PQ EOTF + Type 1 metadata)
    pub fn supportsHdr10(self: StaticMetadata) bool {
        return self.eotfs.smpte_st_2084 and self.descriptors.type1;
    }
    
    /// Check if HLG is supported
    pub fn supportsHlg(self: StaticMetadata) bool {
        return self.eotfs.hlg;
    }
};

/// Decode luminance from byte (max and max frame-avg)
/// Formula: 50 * 2^(byte/32) cd/m²
fn decodeLuminance(byte: u8) f32 {
    const exponent = @as(f32, @floatFromInt(byte)) / 32.0;
    return 50.0 * std.math.pow(f32, 2.0, exponent);
}

/// Decode minimum luminance from byte
/// Formula: max_luminance * (byte/255)² / 100 cd/m²
fn decodeMinLuminance(byte: u8) f32 {
    const normalized = @as(f32, @floatFromInt(byte)) / 255.0;
    return normalized * normalized / 100.0;
}

// Tests

test "HDR static metadata parsing - minimal" {
    const data = [_]u8{
        0b00000101, // EOTFs: SDR + PQ
        0b00000001, // Descriptors: Type 1
    };
    
    const hdr = StaticMetadata.parse(&data).?;
    
    try testing.expect(hdr.eotfs.traditional_sdr);
    try testing.expect(hdr.eotfs.smpte_st_2084);
    try testing.expect(!hdr.eotfs.hlg);
    try testing.expect(hdr.descriptors.type1);
    try testing.expect(hdr.supportsHdr10());
}

test "HDR static metadata parsing - with luminance" {
    const data = [_]u8{
        0b00001101, // EOTFs: SDR + PQ + HLG
        0b00000001, // Descriptors: Type 1
        100,        // Max luminance
        90,         // Max frame-avg luminance
        50,         // Min luminance
    };
    
    const hdr = StaticMetadata.parse(&data).?;
    
    try testing.expect(hdr.supportsHdr10());
    try testing.expect(hdr.supportsHlg());
    try testing.expect(hdr.max_luminance_cdm2 > 0);
    try testing.expect(hdr.max_frame_avg_luminance_cdm2 > 0);
    try testing.expect(hdr.min_luminance_cdm2 > 0);
}

test "HDR luminance decoding" {
    // Byte 100 should give ~445 cd/m²
    const lum = decodeLuminance(100);
    try testing.expect(lum > 400.0 and lum < 500.0);
    
    // Byte 0 gives 50 cd/m²
    try testing.expectEqual(@as(f32, 50.0), decodeLuminance(0));
}
