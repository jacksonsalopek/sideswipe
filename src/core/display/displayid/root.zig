//! DisplayID standard support
//!
//! DisplayID is a modern display identification standard that can be used
//! as an alternative to or alongside EDID. It provides more flexible and
//! extensible display capability descriptions.

const std = @import("std");
const testing = std.testing;

pub const product = @import("product.zig");
pub const params = @import("params.zig");
pub const timing = @import("timing.zig");

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
    
    /// Check if this is a timing block (v1)
    pub fn isV1Timing(self: DataBlock) bool {
        return self.tag >= @intFromEnum(V1DataBlockTag.timing_1_detailed) and
            self.tag <= @intFromEnum(V1DataBlockTag.timing_4_dmti);
    }
    
    /// Check if this is a timing block (v2)
    pub fn isV2Timing(self: DataBlock) bool {
        return self.tag >= @intFromEnum(V2DataBlockTag.timing_7) and
            self.tag <= @intFromEnum(V2DataBlockTag.dynamic_video_timing_range);
    }
    
    /// Parse as product identification
    pub fn asProductId(self: DataBlock) ?product.Id {
        return product.Id.parse(self.data);
    }
    
    /// Parse as display parameters
    pub fn asDisplayParams(self: DataBlock) ?params.Display {
        return params.Display.parse(self.data);
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
        const section_length = header.section_length;
        
        // Ensure we have enough data for the section
        if (data.len < 5 + section_length) return null;
        
        const section_data = data[5..][0..section_length];
        
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
    
    /// Get iterator over data blocks
    pub fn blocks(self: Section) DataBlockIterator {
        return DataBlockIterator{
            .data = self.data,
            .offset = 0,
        };
    }
};

/// Iterator over DisplayID data blocks
pub const DataBlockIterator = struct {
    data: []const u8,
    offset: usize,
    
    /// Get next data block
    pub fn next(self: *DataBlockIterator) ?DataBlock {
        if (self.offset >= self.data.len) return null;
        
        // Need at least 3 bytes for header
        if (self.offset + 3 > self.data.len) return null;
        
        // Parse header (packed struct as u24)
        const header_bytes = self.data[self.offset..][0..3];
        const header_int = @as(u24, header_bytes[0]) |
            (@as(u24, header_bytes[1]) << 8) |
            (@as(u24, header_bytes[2]) << 16);
        const header: DataBlockHeader = @bitCast(header_int);
        
        const payload_length = header.payload_length;
        const total_length = 3 + payload_length;
        
        // Check if we have enough data
        if (self.offset + total_length > self.data.len) return null;
        
        const payload = self.data[self.offset + 3..][0..payload_length];
        self.offset += total_length;
        
        return DataBlock{
            .tag = header.tag,
            .revision = header.revision,
            .data = payload,
        };
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

test "DisplayID data block iteration" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    // DisplayID v2.0 header
    data[0] = 0x20; // Version 2.0
    data[1] = 30; // Section length (2 blocks: 15 + 15 = 30 bytes)
    data[2] = 0; // Product type
    data[3] = 0; // Extension count
    data[4] = 0; // Reserved
    
    // Data block 1: Product ID (tag 0x20, revision 0, 12 bytes payload)
    // Total: 3 byte header + 12 byte payload = 15 bytes
    // Packed layout: tag(8) | revision(4) | reserved(3) | payload_length(9)
    // payload_length=12 is at bits 15-23, so 12 << 15 = 0x60000
    // Combined: 0x20 | 0x60000 = 0x060020 in little-endian
    var offset: usize = 5;
    data[offset + 0] = 0x20; // Tag (bits 0-7)
    data[offset + 1] = 0x00; // Revision (bits 8-11) + reserved (bits 12-14)
    data[offset + 2] = 0x06; // Payload length upper bits (bits 16-23, value = 12 >> 1)
    
    // Product ID payload (12 bytes)
    @memcpy(data[offset + 3..][0..3], "TST");
    
    // Data block 2: Display params (tag 0x21, revision 0, 12 bytes payload)
    // Starts at offset 5 + 15 = 20
    // Total: 3 byte header + 12 byte payload = 15 bytes
    offset = 20;
    data[offset + 0] = 0x21; // Tag
    data[offset + 1] = 0x00; // Revision + reserved
    data[offset + 2] = 0x06; // Payload length = 12
    
    const section = Section.parse(&data).?;
    
    // Verify section data contains our blocks
    try testing.expectEqual(@as(u8, 0x20), section.data[0]); // First block tag
    try testing.expectEqual(@as(u8, 0x21), section.data[15]); // Second block tag
    
    var iter = section.blocks();
    
    // First block should be product ID
    const block1 = iter.next().?;
    try testing.expectEqual(@as(u8, 0x20), block1.tag);
    try testing.expectEqual(@as(usize, 12), block1.data.len);
    try testing.expect(block1.isProductId(true));
    try testing.expect(!block1.isDisplayParams(true));
    
    // Second block should be display params
    const block2 = iter.next().?;
    try testing.expectEqual(@as(u8, 0x21), block2.tag);
    try testing.expectEqual(@as(usize, 12), block2.data.len);
    try testing.expect(block2.isDisplayParams(true));
    
    // No more blocks
    try testing.expect(iter.next() == null);
}

test "DisplayID timing block detection" {
    const v1_timing_block = DataBlock{
        .tag = @intFromEnum(V1DataBlockTag.timing_1_detailed),
        .revision = 0,
        .data = &[_]u8{},
    };
    
    try testing.expect(v1_timing_block.isV1Timing());
    try testing.expect(!v1_timing_block.isV2Timing());
    
    const v2_timing_block = DataBlock{
        .tag = @intFromEnum(V2DataBlockTag.timing_7),
        .revision = 0,
        .data = &[_]u8{},
    };
    
    try testing.expect(!v2_timing_block.isV1Timing());
    try testing.expect(v2_timing_block.isV2Timing());
}
