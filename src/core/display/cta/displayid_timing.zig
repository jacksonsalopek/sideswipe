//! CTA-861 DisplayID Video Timing Data Blocks
//!
//! DisplayID timing blocks provide an alternative format for video timings
//! using DisplayID structures within CTA-861 extensions.

const std = @import("std");
const testing = std.testing;

/// DisplayID Type VII Video Timing Data Block
/// Contains 6-byte or 7-byte timing descriptors
pub const Type7Block = struct {
    data: []const u8,
    
    pub fn parse(data: []const u8) Type7Block {
        return Type7Block{ .data = data };
    }
    
    /// Get number of timing descriptors
    pub fn len(self: Type7Block) usize {
        // Type VII uses 6-byte descriptors
        return self.data.len / 6;
    }
};

/// DisplayID Type VIII Video Timing Data Block  
/// Contains timing code format
pub const Type8Block = struct {
    data: []const u8,
    
    pub fn parse(data: []const u8) Type8Block {
        return Type8Block{ .data = data };
    }
    
    /// Get number of timing codes
    pub fn len(self: Type8Block) usize {
        // Type VIII uses 1-byte codes
        return self.data.len;
    }
};

/// DisplayID Type X Video Timing Data Block
/// Contains formula-based timings
pub const Type10Block = struct {
    data: []const u8,
    
    pub fn parse(data: []const u8) Type10Block {
        return Type10Block{ .data = data };
    }
    
    /// Get number of timing formulas
    pub fn len(self: Type10Block) usize {
        // Type X uses 11-byte descriptors
        return self.data.len / 11;
    }
};

// Tests

test "DisplayID Type VII parsing" {
    // Simplified - just test structure
    const data = [_]u8{ 0, 0, 0, 0, 0, 0 }; // 6 bytes
    const block = Type7Block.parse(&data);
    try testing.expectEqual(@as(usize, 1), block.len());
}

test "DisplayID Type VIII parsing" {
    const data = [_]u8{ 1, 2, 3, 4, 5 }; // 5 codes
    const block = Type8Block.parse(&data);
    try testing.expectEqual(@as(usize, 5), block.len());
}

test "DisplayID Type X parsing" {
    // 11 bytes per formula
    const data = [_]u8{0} ** 22; // 2 formulas
    const block = Type10Block.parse(&data);
    try testing.expectEqual(@as(usize, 2), block.len());
}
