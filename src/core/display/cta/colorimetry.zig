//! CTA-861 Colorimetry Data Block parsing
//!
//! Colorimetry blocks describe extended color space support beyond sRGB.

const std = @import("std");
const testing = std.testing;

/// Colorimetry flags (byte 0)
pub const Colorimetry = packed struct(u8) {
    /// xvYCC601
    xvycc601: bool,
    /// xvYCC709
    xvycc709: bool,
    /// sYCC601
    sycc601: bool,
    /// opYCC601 (also called AdobeYCC601)
    opycc601: bool,
    /// opRGB (also called AdobeRGB)
    oprgb: bool,
    /// BT2020 constant luminance YCbCr
    bt2020_cycc: bool,
    /// BT2020 non-constant luminance YCbCr
    bt2020_ycc: bool,
    /// BT2020 RGB
    bt2020_rgb: bool,
};

/// Metadata descriptor flags (byte 1)
pub const MetadataDescriptors = packed struct(u8) {
    /// Metadata Descriptor type 0
    md0: bool,
    /// Metadata Descriptor type 1
    md1: bool,
    /// Metadata Descriptor type 2
    md2: bool,
    /// Metadata Descriptor type 3
    md3: bool,
    /// DCI-P3 (D65)
    dci_p3: bool,
    _reserved: u3,
};

/// Colorimetry Data Block
pub const Block = struct {
    /// Supported colorimetry modes
    colorimetry: Colorimetry,
    
    /// Metadata descriptors
    descriptors: MetadataDescriptors,
    
    /// Parse from extended data block payload (at least 2 bytes)
    pub fn parse(data: []const u8) ?Block {
        if (data.len < 2) return null;
        
        return Block{
            .colorimetry = @bitCast(data[0]),
            .descriptors = @bitCast(data[1]),
        };
    }
    
    /// Check if any extended colorimetry is supported
    pub fn hasExtendedColorimetry(self: Block) bool {
        const c = self.colorimetry;
        return c.xvycc601 or c.xvycc709 or c.sycc601 or c.opycc601 or 
               c.oprgb or c.bt2020_cycc or c.bt2020_ycc or c.bt2020_rgb;
    }
    
    /// Check if BT.2020 (any variant) is supported
    pub fn supportsBt2020(self: Block) bool {
        return self.colorimetry.bt2020_cycc or 
               self.colorimetry.bt2020_ycc or 
               self.colorimetry.bt2020_rgb;
    }
    
    /// Check if DCI-P3 is supported
    pub fn supportsDciP3(self: Block) bool {
        return self.descriptors.dci_p3;
    }
};

// Tests

test "colorimetry parsing - basic" {
    const data = [_]u8{
        0b00000011, // xvYCC601 + xvYCC709
        0b00000000, // No metadata descriptors
    };
    
    const block = Block.parse(&data).?;
    
    try testing.expect(block.colorimetry.xvycc601);
    try testing.expect(block.colorimetry.xvycc709);
    try testing.expect(!block.colorimetry.bt2020_rgb);
    try testing.expect(block.hasExtendedColorimetry());
}

test "colorimetry parsing - BT.2020" {
    const data = [_]u8{
        0b11100000, // BT2020 RGB + YCC + cYCC
        0b00000000,
    };
    
    const block = Block.parse(&data).?;
    
    try testing.expect(block.colorimetry.bt2020_rgb);
    try testing.expect(block.colorimetry.bt2020_ycc);
    try testing.expect(block.colorimetry.bt2020_cycc);
    try testing.expect(block.supportsBt2020());
}

test "colorimetry parsing - DCI-P3" {
    const data = [_]u8{
        0b00000000,
        0b00010000, // DCI-P3 (bit 4)
    };
    
    const block = Block.parse(&data).?;
    
    try testing.expect(block.supportsDciP3());
    try testing.expect(!block.hasExtendedColorimetry());
}

test "colorimetry parsing - with metadata descriptors" {
    const data = [_]u8{
        0b00001111, // sYCC + opYCC + xvYCC709 + xvYCC601
        0b00000011, // MD0 + MD1
    };
    
    const block = Block.parse(&data).?;
    
    try testing.expect(block.colorimetry.sycc601);
    try testing.expect(block.colorimetry.opycc601);
    try testing.expect(block.descriptors.md0);
    try testing.expect(block.descriptors.md1);
}

test "colorimetry size" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(Colorimetry));
    try testing.expectEqual(@as(usize, 1), @sizeOf(MetadataDescriptors));
}
