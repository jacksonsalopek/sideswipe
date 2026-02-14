//! CTA-861 (Consumer Technology Association) extension block parsing
//!
//! CTA-861 provides HDMI/HDCP capabilities, audio formats, and video data blocks.
//! Specified in CTA-861-H standard.

const std = @import("std");
const testing = std.testing;

pub const video = @import("video.zig");
pub const audio = @import("audio.zig");
pub const speaker = @import("speaker.zig");
pub const hdmi = @import("hdmi.zig");
pub const hdr = @import("hdr.zig");
pub const colorimetry = @import("colorimetry.zig");
pub const ycbcr420 = @import("ycbcr420.zig");
pub const extended = @import("extended.zig");
pub const vic_table = @import("vic_table.zig");
pub const displayid_timing = @import("displayid_timing.zig");

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

/// Extended data block tag (when primary tag = 7)
pub const ExtendedTag = enum(u8) {
    video_cap = 0,
    vendor = 1,
    vesa_display_device = 2,
    vesa_video_timing = 3,
    hdmi_video = 4,
    colorimetry = 5,
    hdr_static_metadata = 6,
    hdr_dynamic_metadata = 7,
    native_video_resolution = 8,
    video_format_pref = 9,
    ycbcr420 = 14,
    ycbcr420_cap_map = 15,
    hdmi_audio = 16,
    room_config = 17,
    speaker_location = 18,
    infoframe = 32,
    displayid_video_timing_vii = 19,
    displayid_video_timing_viii = 20,
    displayid_video_timing_x = 21,
    hdmi_edid_ext_override = 120,
    hdmi_sink_cap = 121,
    _,
};

/// CTA data block header (1 byte)
pub const DataBlockHeader = packed struct(u8) {
    /// Length of data block in bytes (not including header)
    length: u5,
    /// Data block tag
    tag: DataBlockTag,
};

/// Parsed CTA data block
pub const DataBlock = struct {
    /// Primary tag
    tag: DataBlockTag,
    /// Extended tag (only if primary tag = extended)
    extended_tag: ?ExtendedTag,
    /// Data payload (not including header bytes)
    data: []const u8,
    
    /// Check if this is an audio block
    pub fn isAudio(self: DataBlock) bool {
        return self.tag == .audio;
    }
    
    /// Check if this is a video block
    pub fn isVideo(self: DataBlock) bool {
        return self.tag == .video;
    }
    
    /// Check if this is vendor-specific
    pub fn isVendorSpecific(self: DataBlock) bool {
        return self.tag == .vendor_specific;
    }
    
    /// Check if this is an extended block with specific tag
    pub fn isExtended(self: DataBlock, ext_tag: ExtendedTag) bool {
        if (self.tag != .extended) return false;
        if (self.extended_tag) |et| {
            return et == ext_tag;
        }
        return false;
    }
};

/// Iterator for CTA data blocks
pub const DataBlockIterator = struct {
    /// Data block region
    data: []const u8,
    /// Current position in bytes
    pos: usize,
    
    /// Create iterator for data block region
    pub fn init(region: []const u8) DataBlockIterator {
        return DataBlockIterator{
            .data = region,
            .pos = 0,
        };
    }
    
    /// Get next data block, or null if done
    pub fn next(self: *DataBlockIterator) ?DataBlock {
        if (self.pos >= self.data.len) {
            return null;
        }
        
        // Parse header
        const header_byte = self.data[self.pos];
        const header: DataBlockHeader = @bitCast(header_byte);
        
        self.pos += 1; // Skip header byte
        
        const length = header.length;
        if (length == 0) {
            return null; // Invalid
        }
        
        // Check if we have enough data
        if (self.pos + length > self.data.len) {
            return null; // Truncated
        }
        
        // Extract data payload
        const payload = self.data[self.pos .. self.pos + length];
        
        // Check for extended tag
        var extended_tag: ?ExtendedTag = null;
        var actual_payload = payload;
        
        if (header.tag == .extended and payload.len > 0) {
            extended_tag = @enumFromInt(payload[0]);
            actual_payload = payload[1..]; // Skip extended tag byte
        }
        
        self.pos += length;
        
        return DataBlock{
            .tag = header.tag,
            .extended_tag = extended_tag,
            .data = actual_payload,
        };
    }
    
    /// Reset iterator to beginning
    pub fn reset(self: *DataBlockIterator) void {
        self.pos = 0;
    }
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
    
    /// Create iterator for data blocks
    pub fn iterateDataBlocks(self: *align(1) const CtaExtensionBlock) DataBlockIterator {
        return DataBlockIterator.init(self.getDataBlockRegion());
    }
    
    /// Get video data blocks (returns first video block found)
    pub fn getVideoBlock(self: *align(1) const CtaExtensionBlock) ?video.BlockView {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.isVideo()) {
                return video.parseBlockView(block.data);
            }
        }
        
        return null;
    }
    
    /// Get audio data block (returns first audio block found)
    pub fn getAudioBlock(self: *align(1) const CtaExtensionBlock) ?audio.BlockView {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.isAudio()) {
                return audio.parseBlockView(block.data);
            }
        }
        
        return null;
    }
    
    /// Get speaker allocation block (returns first found)
    pub fn getSpeakerBlock(self: *align(1) const CtaExtensionBlock) ?speaker.BlockView {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.tag == .speaker_allocation) {
                return speaker.BlockView.parse(block.data);
            }
        }
        
        return null;
    }
    
    /// Get HDMI vendor-specific data block
    pub fn getHdmiVsdb(self: *align(1) const CtaExtensionBlock) ?hdmi.Vsdb {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.tag == .vendor_specific) {
                if (hdmi.Vsdb.parse(block.data)) |vsdb| {
                    return vsdb;
                }
            }
        }
        
        return null;
    }
    
    /// Get HDMI Forum vendor-specific data block (HDMI 2.0+)
    pub fn getHdmiForumVsdb(self: *align(1) const CtaExtensionBlock) ?hdmi.ForumVsdb {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.tag == .vendor_specific) {
                if (hdmi.ForumVsdb.parse(block.data)) |vsdb| {
                    return vsdb;
                }
            }
        }
        
        return null;
    }
    
    /// Get HDR static metadata block
    pub fn getHdrStaticMetadata(self: *align(1) const CtaExtensionBlock) ?hdr.StaticMetadata {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.isExtended(.hdr_static_metadata)) {
                return hdr.StaticMetadata.parse(block.data);
            }
        }
        
        return null;
    }
    
    /// Get colorimetry data block
    pub fn getColorimetryBlock(self: *align(1) const CtaExtensionBlock) ?colorimetry.Block {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.isExtended(.colorimetry)) {
                return colorimetry.Block.parse(block.data);
            }
        }
        
        return null;
    }
    
    /// Get video capability data block
    pub fn getVideoCapBlock(self: *align(1) const CtaExtensionBlock) ?video.CapabilityBlock {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.isExtended(.video_cap)) {
                return video.CapabilityBlock.parse(block.data);
            }
        }
        
        return null;
    }
    
    /// Get YCbCr 4:2:0 video data block
    pub fn getYcbcr420VideoBlock(self: *align(1) const CtaExtensionBlock) ?ycbcr420.VideoBlock {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.isExtended(.ycbcr420)) {
                return ycbcr420.VideoBlock.parse(block.data);
            }
        }
        
        return null;
    }
    
    /// Get YCbCr 4:2:0 capability map
    pub fn getYcbcr420CapMap(self: *align(1) const CtaExtensionBlock) ?ycbcr420.CapabilityMap {
        var iter = self.iterateDataBlocks();
        
        while (iter.next()) |block| {
            if (block.isExtended(.ycbcr420_cap_map)) {
                return ycbcr420.CapabilityMap.parse(block.data);
            }
        }
        
        return null;
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

test "data block iterator - video block" {
    // Create a simple video data block
    // Header: tag=2 (video), length=3
    // Data: 3 VIC codes
    const data = [_]u8{
        0b01000011, // Header: tag=2 (010), length=3 (00011)
        0x10,       // VIC 16 (1080p60)
        0x04,       // VIC 4 (720p60)
        0x1F,       // VIC 31 (1080p50)
    };
    
    var iter = DataBlockIterator.init(&data);
    
    const block = iter.next().?;
    try testing.expectEqual(DataBlockTag.video, block.tag);
    try testing.expectEqual(@as(usize, 3), block.data.len);
    try testing.expectEqual(@as(u8, 0x10), block.data[0]);
    try testing.expectEqual(@as(u8, 0x04), block.data[1]);
    try testing.expectEqual(@as(u8, 0x1F), block.data[2]);
    
    // Should be end
    try testing.expect(iter.next() == null);
}

test "data block iterator - audio block" {
    // Audio data block: tag=1, length=3 (one SAD)
    const data = [_]u8{
        0b00100011, // Header: tag=1 (001), length=3 (00011)
        0x09,       // Format: LPCM (1), max channels: 2
        0x7F,       // Sample rates: all
        0x07,       // Bit depths: 16/20/24
    };
    
    var iter = DataBlockIterator.init(&data);
    
    const block = iter.next().?;
    try testing.expect(block.isAudio());
    try testing.expectEqual(@as(usize, 3), block.data.len);
}

test "data block iterator - extended block" {
    // Extended data block: tag=7, length=2, extended_tag=5 (colorimetry)
    const data = [_]u8{
        0b11100010, // Header: tag=7 (111), length=2 (00010)
        0x05,       // Extended tag: colorimetry
        0x0F,       // Colorimetry data
    };
    
    var iter = DataBlockIterator.init(&data);
    
    const block = iter.next().?;
    try testing.expectEqual(DataBlockTag.extended, block.tag);
    try testing.expect(block.extended_tag != null);
    try testing.expectEqual(ExtendedTag.colorimetry, block.extended_tag.?);
    try testing.expectEqual(@as(usize, 1), block.data.len); // Payload after extended tag
    try testing.expectEqual(@as(u8, 0x0F), block.data[0]);
}

test "data block iterator - multiple blocks" {
    // Two blocks: video + audio
    const data = [_]u8{
        // Block 1: Video, length=2
        0b01000010, 0x10, 0x04,
        // Block 2: Audio, length=3
        0b00100011, 0x09, 0x7F, 0x07,
    };
    
    var iter = DataBlockIterator.init(&data);
    
    // First block
    const block1 = iter.next().?;
    try testing.expect(block1.isVideo());
    try testing.expectEqual(@as(usize, 2), block1.data.len);
    
    // Second block
    const block2 = iter.next().?;
    try testing.expect(block2.isAudio());
    try testing.expectEqual(@as(usize, 3), block2.data.len);
    
    // End
    try testing.expect(iter.next() == null);
}

test "data block iterator - reset" {
    const data = [_]u8{
        0b01000010, 0x10, 0x04,
    };
    
    var iter = DataBlockIterator.init(&data);
    
    _ = iter.next();
    try testing.expect(iter.next() == null);
    
    // Reset and iterate again
    iter.reset();
    const block = iter.next().?;
    try testing.expect(block.isVideo());
}

test "CTA extension block with data blocks" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    // Header
    data[0] = 0x02; // CTA tag
    data[1] = 0x03; // Revision 3
    data[2] = 0x0C; // DTDs start at byte 0x0C (4 + 8 bytes of data blocks)
    data[3] = 0xE0; // Flags: audio + ycc444 + ycc422
    
    // Data block 1: Video (2 VICs)
    data[4] = 0b01000010; // tag=2, length=2
    data[5] = 0x10;       // VIC 16
    data[6] = 0x04;       // VIC 4
    
    // Data block 2: Audio (3 bytes)
    data[7] = 0b00100011;  // tag=1, length=3
    data[8] = 0x09;
    data[9] = 0x7F;
    data[10] = 0x07;
    
    // Checksum at end
    var sum: u8 = 0;
    for (data[0..127]) |byte| sum +%= byte;
    data[127] = 0 -% sum;
    
    const cta = CtaExtensionBlock.fromBytes(&data);
    
    // Iterate through blocks
    var iter = cta.iterateDataBlocks();
    var video_count: usize = 0;
    var audio_count: usize = 0;
    
    while (iter.next()) |block| {
        if (block.isVideo()) {
            video_count += 1;
            try testing.expectEqual(@as(usize, 2), block.data.len);
        } else if (block.isAudio()) {
            audio_count += 1;
            try testing.expectEqual(@as(usize, 3), block.data.len);
        }
    }
    
    try testing.expectEqual(@as(usize, 1), video_count);
    try testing.expectEqual(@as(usize, 1), audio_count);
}

test "CTA get video block" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    data[0] = 0x02;
    data[1] = 0x03;
    data[2] = 0x09; // DTDs start at 0x09
    data[3] = 0;
    
    // Video data block with 3 VICs
    data[4] = 0b01000011; // tag=2, length=3
    data[5] = 0x10;       // VIC 16 (1080p60)
    data[6] = 0x84;       // VIC 4 (720p60, native)
    data[7] = 0x1F;       // VIC 31 (1080p50)
    
    const cta = CtaExtensionBlock.fromBytes(&data);
    const video_block = cta.getVideoBlock().?;
    
    try testing.expectEqual(@as(usize, 3), video_block.len());
    try testing.expect(video_block.supportsVic(16));
    try testing.expect(video_block.supportsVic(4));
    try testing.expect(video_block.supportsVic(31));
    
    // Check native indicator
    const svd = video_block.getSvd(1).?;
    try testing.expectEqual(@as(u8, 4), svd.vic);
    try testing.expect(svd.native);
}

test "CTA get audio block" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    data[0] = 0x02;
    data[1] = 0x03;
    data[2] = 0x0B; // DTDs start at 0x0B
    data[3] = 0x40; // Basic audio flag
    
    // Audio data block with 2 SADs
    data[4] = 0b00100110; // tag=1 (audio), length=6 (2 SADs)
    // SAD 1: LPCM, 2ch, 48kHz, 16/20/24bit
    data[5] = 0b00001001;
    data[6] = 0b00000100;
    data[7] = 0b00000111;
    // SAD 2: AC-3, 6ch, 48kHz, 640kbps
    data[8] = 0b00010101;
    data[9] = 0b00000100;
    data[10] = 80;
    
    const cta = CtaExtensionBlock.fromBytes(&data);
    const audio_block = cta.getAudioBlock().?;
    
    try testing.expectEqual(@as(usize, 2), audio_block.len());
    try testing.expect(audio_block.supportsFormat(.lpcm));
    try testing.expect(audio_block.supportsFormat(.ac3));
    try testing.expect(!audio_block.supportsFormat(.dts));
}

test "CTA get speaker block" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    data[0] = 0x02;
    data[1] = 0x03;
    data[2] = 0x08; // DTDs start at 0x08
    data[3] = 0x40;
    
    // Speaker allocation block: tag=4, length=3
    data[4] = 0b10000011; // tag=4 (speaker_allocation), length=3
    data[5] = 0x0F;       // FL/FR, LFE, FC, RL/RR (5.1)
    data[6] = 0x00;
    data[7] = 0x00;
    
    const cta = CtaExtensionBlock.fromBytes(&data);
    const spk_block = cta.getSpeakerBlock().?;
    
    try testing.expect(spk_block.allocation.is5_1());
    try testing.expectEqual(@as(u8, 6), spk_block.allocation.getChannelCount());
}

test "CTA get HDMI VSDB" {
    var data: [128]u8 = undefined;
    @memset(&data, 0);
    
    data[0] = 0x02;
    data[1] = 0x03;
    data[2] = 0x0D; // DTDs start at 0x0D
    data[3] = 0x00;
    
    // HDMI vendor-specific block: tag=3, length=8
    data[4] = 0b01101000; // tag=3 (vendor_specific), length=8
    data[5] = 0x03;       // HDMI OUI byte 0
    data[6] = 0x0C;       // HDMI OUI byte 1
    data[7] = 0x00;       // HDMI OUI byte 2
    data[8] = 0x10;       // Physical address high (1.0.0.0)
    data[9] = 0x00;       // Physical address low
    data[10] = 0xB0;      // AI + DC_36bit + DC_30bit
    data[11] = 170;       // Max TMDS: 170 * 5 = 850 MHz
    
    const cta = CtaExtensionBlock.fromBytes(&data);
    const hdmi_vsdb = cta.getHdmiVsdb().?;
    
    try testing.expectEqual([4]u8{ 1, 0, 0, 0 }, hdmi_vsdb.physical_address);
    try testing.expect(hdmi_vsdb.supports_ai);
    try testing.expect(hdmi_vsdb.dc_36bit);
    try testing.expect(hdmi_vsdb.dc_30bit);
    try testing.expectEqual(@as(u16, 850), hdmi_vsdb.max_tmds_clock_mhz);
}
