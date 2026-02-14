//! CTA-861 Audio Data Block parsing
//!
//! Audio data blocks contain Short Audio Descriptors (SADs) listing
//! supported audio formats and capabilities.

const std = @import("std");
const testing = std.testing;

/// Audio format codes (CTA-861 Table 37)
pub const Format = enum(u4) {
    reserved = 0,
    lpcm = 1,
    ac3 = 2,
    mpeg1 = 3,
    mp3 = 4,
    mpeg2 = 5,
    aac_lc = 6,
    dts = 7,
    atrac = 8,
    one_bit_audio = 9,
    enhanced_ac3 = 10,
    dts_hd = 11,
    mat = 12,
    dst = 13,
    wma_pro = 14,
    extended = 15,
};

/// Extended audio format codes (when format = 15)
pub const ExtendedFormat = enum(u8) {
    mpeg4_he_aac = 4,
    mpeg4_he_aac_v2 = 5,
    mpeg4_aac_lc = 6,
    dra = 7,
    mpeg4_he_aac_mpeg_surround = 8,
    mpeg4_aac_lc_mpeg_surround = 10,
    mpegh_3d = 11,
    ac4 = 12,
    lpcm_3d = 13,
    _,
};

/// Sample rate flags (CTA-861 Table 38)
pub const SampleRates = packed struct(u7) {
    rate_32khz: bool,
    rate_44_1khz: bool,
    rate_48khz: bool,
    rate_88_2khz: bool,
    rate_96khz: bool,
    rate_176_4khz: bool,
    rate_192khz: bool,
};

/// LPCM bit depth flags
pub const LpcmBitDepths = packed struct(u7) {
    depth_16bit: bool,
    depth_20bit: bool,
    depth_24bit: bool,
    _reserved: u4,
};

/// Short Audio Descriptor (3 bytes)
pub const Sad = struct {
    /// Audio format code
    format: Format,
    /// Extended format (only if format = extended)
    extended_format: ?ExtendedFormat,
    /// Maximum number of channels (1-8)
    max_channels: u8,
    /// Supported sample rates
    sample_rates: SampleRates,
    /// Format-specific data (byte 3)
    /// - LPCM: bit depths
    /// - Compressed: max bit rate / 8kHz
    format_specific: u8,
    
    /// Parse SAD from 3 bytes
    pub fn parse(bytes: [3]u8) Sad {
        const byte0 = bytes[0];
        const byte1 = bytes[1];
        const byte2 = bytes[2];
        
        // Byte 0: bits 6-3 = format, bits 2-0 = max channels - 1
        const format_code: u4 = @intCast((byte0 >> 3) & 0x0F);
        const format: Format = @enumFromInt(format_code);
        const max_channels: u8 = (byte0 & 0x07) + 1;
        
        // Byte 1: sample rates (bits 6-0)
        const sample_rates: SampleRates = @bitCast(@as(u7, @intCast(byte1 & 0x7F)));
        
        // Byte 2: format-specific
        // For extended formats, bits 7-3 contain extended format code
        const extended_format: ?ExtendedFormat = if (format == .extended)
            @enumFromInt((byte2 >> 3) & 0x1F)
        else
            null;
        
        return Sad{
            .format = format,
            .extended_format = extended_format,
            .max_channels = max_channels,
            .sample_rates = sample_rates,
            .format_specific = byte2,
        };
    }
    
    /// Get LPCM bit depths (only valid if format = lpcm)
    pub fn getLpcmBitDepths(self: Sad) ?LpcmBitDepths {
        if (self.format != .lpcm) return null;
        return @bitCast(@as(u7, @intCast(self.format_specific & 0x7F)));
    }
    
    /// Get maximum bit rate in kHz (for compressed formats)
    pub fn getMaxBitrateKhz(self: Sad) ?u16 {
        if (self.format == .lpcm or self.format == .extended) return null;
        return @as(u16, self.format_specific) * 8;
    }
};

/// Audio block (zero-copy view)
pub const BlockView = struct {
    data: []const u8,
    
    /// Get number of SADs (each SAD is 3 bytes)
    pub fn len(self: BlockView) usize {
        return self.data.len / 3;
    }
    
    /// Get SAD at index
    pub fn getSad(self: BlockView, index: usize) ?Sad {
        if (index >= self.len()) return null;
        const offset = index * 3;
        const bytes = self.data[offset..][0..3].*;
        return Sad.parse(bytes);
    }
    
    /// Check if format is supported
    pub fn supportsFormat(self: BlockView, format: Format) bool {
        var i: usize = 0;
        while (i < self.len()) : (i += 1) {
            if (self.getSad(i)) |sad| {
                if (sad.format == format) return true;
            }
        }
        return false;
    }
    
    /// Iterator over SADs
    pub const Iterator = struct {
        view: BlockView,
        index: usize,
        
        pub fn next(self: *Iterator) ?Sad {
            if (self.index >= self.view.len()) return null;
            const sad = self.view.getSad(self.index).?;
            self.index += 1;
            return sad;
        }
    };
    
    /// Create iterator
    pub fn iterate(self: BlockView) Iterator {
        return Iterator{
            .view = self,
            .index = 0,
        };
    }
};

/// Parse audio block as zero-copy view
pub fn parseBlockView(data: []const u8) BlockView {
    return BlockView{ .data = data };
}

// Tests

test "SAD parsing - LPCM" {
    // LPCM, 2 channels, 48kHz, 16/20/24 bit
    const bytes = [3]u8{
        0b00001001, // Format: LPCM (1), channels: 2 (001)
        0b00000100, // Sample rates: 48kHz
        0b00000111, // Bit depths: 16/20/24
    };
    
    const sad = Sad.parse(bytes);
    
    try testing.expectEqual(Format.lpcm, sad.format);
    try testing.expectEqual(@as(u8, 2), sad.max_channels);
    try testing.expect(sad.sample_rates.rate_48khz);
    try testing.expect(!sad.sample_rates.rate_44_1khz);
    
    const bit_depths = sad.getLpcmBitDepths().?;
    try testing.expect(bit_depths.depth_16bit);
    try testing.expect(bit_depths.depth_20bit);
    try testing.expect(bit_depths.depth_24bit);
}

test "SAD parsing - AC-3" {
    // AC-3, 6 channels (5.1), 48kHz, max 640 kbps
    const bytes = [3]u8{
        0b00010101, // Format: AC-3 (2), channels: 6 (101)
        0b00000100, // Sample rates: 48kHz
        80,         // Max bitrate: 80 * 8 = 640 kbps
    };
    
    const sad = Sad.parse(bytes);
    
    try testing.expectEqual(Format.ac3, sad.format);
    try testing.expectEqual(@as(u8, 6), sad.max_channels);
    try testing.expect(sad.sample_rates.rate_48khz);
    
    const bitrate = sad.getMaxBitrateKhz().?;
    try testing.expectEqual(@as(u16, 640), bitrate);
}

test "SAD parsing - DTS" {
    // DTS, 6 channels, 48/96kHz, max 1536 kbps
    const bytes = [3]u8{
        0b00111101, // Format: DTS (7), channels: 6
        0b00010100, // Rates: 48kHz + 96kHz
        192,        // Max bitrate: 192 * 8 = 1536 kbps
    };
    
    const sad = Sad.parse(bytes);
    
    try testing.expectEqual(Format.dts, sad.format);
    try testing.expectEqual(@as(u8, 6), sad.max_channels);
    try testing.expect(sad.sample_rates.rate_48khz);
    try testing.expect(sad.sample_rates.rate_96khz);
}

test "audio block view" {
    // 2 SADs: LPCM + AC-3
    const data = [_]u8{
        // LPCM
        0b00001001, 0b00000100, 0b00000111,
        // AC-3
        0b00010101, 0b00000100, 80,
    };
    
    const view = parseBlockView(&data);
    
    try testing.expectEqual(@as(usize, 2), view.len());
    
    const sad0 = view.getSad(0).?;
    try testing.expectEqual(Format.lpcm, sad0.format);
    
    const sad1 = view.getSad(1).?;
    try testing.expectEqual(Format.ac3, sad1.format);
}

test "audio block view - supports format" {
    const data = [_]u8{
        0b00001001, 0b00000100, 0b00000111, // LPCM
        0b00010101, 0b00000100, 80,         // AC-3
    };
    
    const view = parseBlockView(&data);
    
    try testing.expect(view.supportsFormat(.lpcm));
    try testing.expect(view.supportsFormat(.ac3));
    try testing.expect(!view.supportsFormat(.dts));
}

test "audio block view - iterator" {
    const data = [_]u8{
        0b00001001, 0b00000100, 0b00000111,
        0b00010101, 0b00000100, 80,
        0b00111101, 0b00010100, 192,
    };
    
    const view = parseBlockView(&data);
    
    var iter = view.iterate();
    var count: usize = 0;
    
    while (iter.next()) |sad| {
        count += 1;
        try testing.expect(sad.max_channels > 0);
    }
    
    try testing.expectEqual(@as(usize, 3), count);
}
