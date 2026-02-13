//! CTA-861 (Consumer Technology Association) extension block parsing
//!
//! CTA-861 provides HDMI/HDCP capabilities, audio formats, and video data blocks.
//! Specified in CTA-861-H standard.

const std = @import("std");
const testing = std.testing;

/// CTA extension block tag (must be 0x02)
pub const extension_tag: u8 = 0x02;

/// CTA extension block size (128 bytes, same as EDID base block)
pub const block_size = 128;

/// CTA miscellaneous flags (byte 3)
pub const CtaFlags = packed struct(u8) {
    /// Number of native detailed timing descriptors (bits 0-3)
    native_dtds: u4,
    /// Sink supports YCbCr 4:2:2 (bit 4)
    ycc422: bool,
    /// Sink supports YCbCr 4:4:4 (bit 5)
    ycc444: bool,
    /// Sink supports basic audio (bit 6)
    basic_audio: bool,
    /// Sink underscans IT video formats by default (bit 7)
    it_underscan: bool,
};

/// CTA extension block header (4 bytes)
pub const CtaHeader = extern struct {
    /// Extension tag (must be 0x02)
    tag: u8,
    /// Revision number
    revision: u8,
    /// Offset to detailed timing descriptors (d = offset, 0 = none)
    dtd_offset: u8,
    /// Flags
    flags: CtaFlags,
};

/// CTA data block tag
pub const DataBlockTag = enum(u3) {
    reserved = 0,
    audio = 1,
    video = 2,
    vendor_specific = 3,
    speaker_allocation = 4,
    vesa_dtc = 5,
    reserved2 = 6,
    extended = 7,
};

/// CTA data block header (1 byte)
pub const DataBlockHeader = packed struct(u8) {
    /// Length of data block in bytes (not including header)
    length: u5,
    /// Data block tag
    tag: DataBlockTag,
};

/// CTA extension block (128 bytes)
pub const CtaExtensionBlock = extern struct {
    /// Header
    header: CtaHeader,
    /// Data blocks and detailed timing descriptors
    /// The dtd_offset field indicates where DTDs start
    data: [124]u8,

    comptime {
        if (@sizeOf(@This()) != 128) {
            @compileError("CtaExtensionBlock must be 128 bytes");
        }
    }

    /// Cast raw bytes to CTA extension block
    pub fn fromBytes(data: *align(1) const [128]u8) *align(1) const CtaExtensionBlock {
        return @ptrCast(data);
    }

    /// Check if this is a valid CTA extension
    pub fn isValidCtaExtension(self: *align(1) const CtaExtensionBlock) bool {
        return self.header.tag == extension_tag;
    }

    /// Get revision number
    pub fn getRevision(self: *align(1) const CtaExtensionBlock) u8 {
        return self.header.revision;
    }

    /// Get flags
    pub fn getFlags(self: *align(1) const CtaExtensionBlock) CtaFlags {
        return self.header.flags;
    }

    /// Get data block region (returns slice up to DTD offset or end)
    pub fn getDataBlockRegion(self: *align(1) const CtaExtensionBlock) []const u8 {
        const dtd_offset = self.header.dtd_offset;
        if (dtd_offset == 0 or dtd_offset < 4) {
            return &[_]u8{}; // No data blocks
        }
        
        const end = @min(dtd_offset - 4, 124);
        return self.data[0..end];
    }
};

// Tests

test "CtaExtensionBlock size" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(CtaExtensionBlock));
}

test "CTA header parsing" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    data[0] = 0x02; // CTA tag
    data[1] = 0x03; // Revision 3
    data[2] = 0x20; // DTDs start at byte 0x20
    data[3] = 0b11110001; // it_underscan=1, basic_audio=1, ycc444=1, ycc422=1, native_dtds=1
    
    const cta = CtaExtensionBlock.fromBytes(&data);
    
    try testing.expect(cta.isValidCtaExtension());
    try testing.expectEqual(@as(u8, 3), cta.getRevision());
    
    const flags = cta.getFlags();
    try testing.expect(flags.it_underscan);
    try testing.expect(flags.basic_audio);
    try testing.expect(flags.ycc444);
    try testing.expect(flags.ycc422);
    try testing.expectEqual(@as(u4, 1), flags.native_dtds);
}

test "CTA data block region" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    data[0] = 0x02;
    data[1] = 0x03;
    data[2] = 0x10; // DTDs start at 0x10 (offset from block start)
    data[3] = 0;
    
    const cta = CtaExtensionBlock.fromBytes(&data);
    const region = cta.getDataBlockRegion();
    
    // Data blocks occupy bytes 4 to (dtd_offset-1)
    // dtd_offset=0x10 means bytes 4-15, so 12 bytes
    try testing.expectEqual(@as(usize, 12), region.len);
}
