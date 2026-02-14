//! CTA-861 Speaker Allocation Data Block parsing
//!
//! Speaker allocation blocks describe the physical speaker configuration
//! for multi-channel audio (surround sound).

const std = @import("std");
const testing = std.testing;

/// Speaker allocation (3 bytes)
/// Defined in CTA-861 section 7.5.2
/// 
/// Note: Using raw bytes + methods instead of packed struct due to
/// Zig's u24 alignment. Packed struct(u24) becomes 4 bytes.
pub const Allocation = struct {
    bytes: [3]u8,
    
    /// Parse from 3 bytes
    pub fn parse(bytes: [3]u8) Allocation {
        return Allocation{ .bytes = bytes };
    }
    
    // Speaker position accessor methods
    
    /// Front Left/Right (FL/FR) - bit 0
    pub fn hasFrontLR(self: Allocation) bool {
        return (self.bytes[0] & 0x01) != 0;
    }
    
    /// Low Frequency Effects (LFE) - bit 1
    pub fn hasLFE(self: Allocation) bool {
        return (self.bytes[0] & 0x02) != 0;
    }
    
    /// Front Center (FC) - bit 2
    pub fn hasFrontCenter(self: Allocation) bool {
        return (self.bytes[0] & 0x04) != 0;
    }
    
    /// Rear Left/Right (BL/BR) - bit 3
    pub fn hasRearLR(self: Allocation) bool {
        return (self.bytes[0] & 0x08) != 0;
    }
    
    /// Rear Center (RC) - bit 4
    pub fn hasRearCenter(self: Allocation) bool {
        return (self.bytes[0] & 0x10) != 0;
    }
    
    /// Front Left/Right Center (FLC/FRC) - bit 5
    pub fn hasFrontLRCenter(self: Allocation) bool {
        return (self.bytes[0] & 0x20) != 0;
    }
    
    /// Rear Left/Right Center (RLC/RRC) - bit 6
    pub fn hasRearLRCenter(self: Allocation) bool {
        return (self.bytes[0] & 0x40) != 0;
    }
    
    /// Front Left/Right Wide (FLW/FRW) - bit 7
    pub fn hasFrontLRWide(self: Allocation) bool {
        return (self.bytes[0] & 0x80) != 0;
    }
    
    /// Left/Right Surround (LS/RS) - byte 1 bit 3
    pub fn hasLeftRightSurround(self: Allocation) bool {
        return (self.bytes[1] & 0x08) != 0;
    }
    
    /// Get channel count (rough estimate based on speakers)
    pub fn getChannelCount(self: Allocation) u8 {
        var count: u8 = 0;
        
        if (self.hasFrontLR()) count += 2;
        if (self.hasLFE()) count += 1;
        if (self.hasFrontCenter()) count += 1;
        if (self.hasRearLR()) count += 2;
        if (self.hasRearCenter()) count += 1;
        if (self.hasFrontLRCenter()) count += 2;
        if (self.hasRearLRCenter()) count += 2;
        if (self.hasFrontLRWide()) count += 2;
        if (self.hasLeftRightSurround()) count += 2;
        
        return count;
    }
    
    /// Check if this is stereo (2.0)
    pub fn isStereo(self: Allocation) bool {
        return self.hasFrontLR() and !self.hasLFE() and !self.hasFrontCenter() and !self.hasRearLR();
    }
    
    /// Check if this is 5.1 surround
    pub fn is5_1(self: Allocation) bool {
        return self.hasFrontLR() and self.hasLFE() and self.hasFrontCenter() and self.hasRearLR();
    }
    
    /// Check if this is 7.1 surround
    pub fn is7_1(self: Allocation) bool {
        return self.is5_1() and (self.hasFrontLRCenter() or self.hasRearLRCenter() or self.hasLeftRightSurround());
    }
};

/// Speaker block view
pub const BlockView = struct {
    allocation: Allocation,
    
    /// Parse from data block payload (3 bytes)
    pub fn parse(data: []const u8) ?BlockView {
        if (data.len < 3) return null;
        
        const bytes: [3]u8 = data[0..3].*;
        return BlockView{
            .allocation = Allocation.parse(bytes),
        };
    }
};

// Tests

test "speaker allocation parsing - stereo" {
    // 2.0: Just FL/FR
    const bytes = [3]u8{ 0x01, 0x00, 0x00 };
    const alloc = Allocation.parse(bytes);
    
    try testing.expect(alloc.hasFrontLR());
    try testing.expect(!alloc.hasLFE());
    try testing.expect(!alloc.hasFrontCenter());
    try testing.expect(alloc.isStereo());
    try testing.expect(!alloc.is5_1());
    try testing.expectEqual(@as(u8, 2), alloc.getChannelCount());
}

test "speaker allocation parsing - 5.1" {
    // 5.1: FL/FR + LFE + FC + BL/BR
    const bytes = [3]u8{ 0x0F, 0x00, 0x00 }; // Bits 0-3 set
    const alloc = Allocation.parse(bytes);
    
    try testing.expect(alloc.hasFrontLR());
    try testing.expect(alloc.hasLFE());
    try testing.expect(alloc.hasFrontCenter());
    try testing.expect(alloc.hasRearLR());
    try testing.expect(!alloc.isStereo());
    try testing.expect(alloc.is5_1());
    try testing.expectEqual(@as(u8, 6), alloc.getChannelCount());
}

test "speaker allocation parsing - 7.1" {
    // 7.1: 5.1 + side speakers (LS/RS)
    const bytes = [3]u8{ 0x0F, 0x08, 0x00 }; // Bits 0-3 + byte1 bit 3 set
    const alloc = Allocation.parse(bytes);
    
    try testing.expect(alloc.is5_1());
    try testing.expect(alloc.hasLeftRightSurround());
    try testing.expect(alloc.is7_1());
    try testing.expectEqual(@as(u8, 8), alloc.getChannelCount());
}

test "speaker block view" {
    const data = [3]u8{ 0x0F, 0x00, 0x00 };
    const view = BlockView.parse(&data).?;
    
    try testing.expect(view.allocation.is5_1());
}

test "speaker allocation size" {
    // Allocation is just a wrapper around [3]u8
    try testing.expectEqual(@as(usize, 3), @sizeOf(Allocation));
}
