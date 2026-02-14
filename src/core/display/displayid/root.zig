//! DisplayID standard support
//!
//! DisplayID is a modern display identification standard that can be used
//! as an alternative to or alongside EDID. It provides more flexible and
//! extensible display capability descriptions.

const std = @import("std");
const testing = std.testing;

pub const product = @import("product.zig");
pub const params = @import("params.zig");

/// DisplayID version
pub const Version = enum(u8) {
    v1_3 = 0x13,
    v2_0 = 0x20,
    v2_1 = 0x21,
    _,
};

/// DisplayID section header (5 bytes)
pub const SectionHeader = extern struct {
    /// DisplayID version
    version: u8,
    /// Section length (not including header and checksum)
    section_length: u8,
    /// Product type
    product_type: u8,
    /// Extension count
    extension_count: u8,
    /// Reserved
    _reserved: u8,
    
    comptime {
        if (@sizeOf(@This()) != 5) {
            @compileError("SectionHeader must be 5 bytes");
        }
    }
    
    /// Get DisplayID version
    pub fn getVersion(self: *align(1) const SectionHeader) Version {
        return @enumFromInt(self.version);
    }
    
    /// Check if this is DisplayID v2.x
    pub fn isV2(self: *align(1) const SectionHeader) bool {
        return self.version >= 0x20;
    }
};

/// DisplayID data block tag (v1.x)
pub const V1DataBlockTag = enum(u8) {
    product_identification = 0x00,
    display_parameters = 0x01,
    color_characteristics = 0x02,
    timing_1_detailed = 0x03,
    timing_2_detailed = 0x04,
    timing_3_short = 0x05,
    timing_4_dmti = 0x06,
    _,
};

/// DisplayID data block tag (v2.x)
pub const V2DataBlockTag = enum(u8) {
    product_identification = 0x20,
    display_parameters = 0x21,
    timing_7 = 0x22,
    timing_8 = 0x23,
    timing_9 = 0x24,
    dynamic_video_timing_range = 0x25,
    interface_features = 0x26,
    stereo_display_interface = 0x27,
    tiled_display = 0x28,
    container_id = 0x29,
    _,
};

/// DisplayID data block header (3 bytes)
pub const DataBlockHeader = packed struct(u24) {
    /// Data block tag
    tag: u8,
    /// Revision
    revision: u4,
    /// Reserved
    _reserved: u3,
    /// Payload length in bytes
    payload_length: u9,
};

/// DisplayID data block
pub const DataBlock = struct {
    /// Block tag
    tag: u8,
    /// Revision
    revision: u4,
    /// Payload data
    data: []const u8,
    
    /// Check if this is a product identification block
    pub fn isProductId(self: DataBlock, is_v2: bool) bool {
        if (is_v2) {
            return self.tag == @intFromEnum(V2DataBlockTag.product_identification);
        } else {
            return self.tag == @intFromEnum(V1DataBlockTag.product_identification);
        }
    }
    
    /// Check if this is a display parameters block
    pub fn isDisplayParams(self: DataBlock, is_v2: bool) bool {
        if (is_v2) {
            return self.tag == @intFromEnum(V2DataBlockTag.display_parameters);
        } else {
            return self.tag == @intFromEnum(V1DataBlockTag.display_parameters);
        }
    }
};

/// DisplayID section
pub const Section = struct {
    /// Section header
    header: *align(1) const SectionHeader,
    /// Data blocks region
    data: []const u8,
    
    /// Parse DisplayID section from bytes
    pub fn parse(data: []const u8) ?Section {
        if (data.len < 5) return null;
        
        const header: *align(1) const SectionHeader = @ptrCast(data[0..5]);
        const section_data = data[5..];
        
        return Section{
            .header = header,
            .data = section_data,
        };
    }
    
    /// Get DisplayID version
    pub fn getVersion(self: Section) Version {
        return self.header.getVersion();
    }
    
    /// Check if this is DisplayID v2
    pub fn isV2(self: Section) bool {
        return self.header.isV2();
    }
};

// Tests

test "DisplayID section header size" {
    try testing.expectEqual(@as(usize, 5), @sizeOf(SectionHeader));
}

test "DisplayID section parsing" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    // DisplayID v2.0 header
    data[0] = 0x20; // Version 2.0
    data[1] = 100;  // Section length
    data[2] = 0;    // Product type
    data[3] = 0;    // Extension count
    data[4] = 0;    // Reserved
    
    const section = Section.parse(&data).?;
    
    try testing.expect(section.isV2());
    try testing.expectEqual(Version.v2_0, section.getVersion());
}

test "DisplayID version detection" {
    var header = SectionHeader{
        .version = 0x13,
        .section_length = 0,
        .product_type = 0,
        .extension_count = 0,
        ._reserved = 0,
    };
    
    try testing.expect(!header.isV2());
    try testing.expectEqual(Version.v1_3, header.getVersion());
    
    header.version = 0x21;
    try testing.expect(header.isV2());
    try testing.expectEqual(Version.v2_1, header.getVersion());
}
