//! DisplayID Timing Data Blocks
//!
//! Implements timing parsers for DisplayID v1 and v2:
//! - v1: Type I, II, III, IV
//! - v2: Type VII, VIII, IX, X

const std = @import("std");
const testing = std.testing;

/// Stereo 3D viewing support
pub const Stereo3DSupport = enum(u2) {
    /// This timing is always displayed monoscopic (no stereo)
    never = 0,
    /// This timing is always displayed in stereo
    always = 1,
    /// This timing is displayed in mono or stereo depending on user action
    user = 2,
    _,
};

/// Sync polarity
pub const SyncPolarity = enum(u2) {
    negative = 0,
    positive = 1,
    not_required = 2,
    _,
};

/// Aspect ratio
pub const AspectRatio = struct {
    h: u16,
    v: u16,

    /// Common aspect ratios
    pub const ratio_4_3 = AspectRatio{ .h = 4, .v = 3 };
    pub const ratio_16_9 = AspectRatio{ .h = 16, .v = 9 };
    pub const ratio_16_10 = AspectRatio{ .h = 16, .v = 10 };
    pub const ratio_5_4 = AspectRatio{ .h = 5, .v = 4 };
};

/// DisplayID Type I Detailed Timing (v1.x, 20 bytes)
/// Provides detailed timing parameters similar to EDID DTD
pub const TypeITiming = struct {
    /// Pixel clock in Hz
    pixel_clock_hz: u32,
    /// Preferred timing
    preferred: bool,
    /// Stereo 3D support
    stereo_3d: Stereo3DSupport,
    /// Interlaced
    interlaced: bool,
    /// Aspect ratio
    aspect_ratio: AspectRatio,
    /// Horizontal active pixels
    h_active: u16,
    /// Horizontal blank pixels
    h_blank: u16,
    /// Horizontal front porch offset
    h_sync_offset: u16,
    /// Horizontal sync polarity
    h_sync_polarity: SyncPolarity,
    /// Horizontal sync pulse width
    h_sync_width: u16,
    /// Vertical active lines
    v_active: u16,
    /// Vertical blank lines
    v_blank: u16,
    /// Vertical front porch offset
    v_sync_offset: u16,
    /// Vertical sync polarity
    v_sync_polarity: SyncPolarity,
    /// Vertical sync pulse width
    v_sync_width: u16,

    /// Parse Type I timing from data (v1.x uses 0.01 MHz units)
    pub fn parse(data: []const u8) ?TypeITiming {
        return parseInternal(data, false);
    }
    
    /// Internal parser for both Type I (v1) and Type VII (v2)
    fn parseInternal(data: []const u8, is_type7: bool) ?TypeITiming {
        if (data.len < 20) return null;

        // Bytes 0-2: Pixel clock (1 + value) in 0.01 MHz (v1) or 0.001 MHz (v2) units
        const raw_pixel_clock = @as(u32, data[0]) |
            (@as(u32, data[1]) << 8) |
            (@as(u32, data[2]) << 16);
        const pixel_clock_hz = if (is_type7)
            (1 + raw_pixel_clock) * 1_000 // Type VII: 0.001 MHz = 1 kHz
        else
            (1 + raw_pixel_clock) * 10_000; // Type I: 0.01 MHz = 10 kHz

        // Byte 3: Options
        const options = data[3];
        const preferred = (options & 0x80) != 0;
        const stereo_3d: Stereo3DSupport = @enumFromInt((options >> 5) & 0x03);
        const interlaced = (options & 0x10) != 0;
        const aspect_ratio_raw = options & 0x0F;
        
        // Map aspect ratio (see DisplayID spec Table 4-3)
        const aspect_ratio = switch (aspect_ratio_raw) {
            0 => AspectRatio{ .h = 1, .v = 1 },
            1 => AspectRatio{ .h = 5, .v = 4 },
            2 => AspectRatio.ratio_4_3,
            3 => AspectRatio{ .h = 15, .v = 9 },
            4 => AspectRatio.ratio_16_9,
            5 => AspectRatio.ratio_16_10,
            6 => AspectRatio{ .h = 64, .v = 27 },
            7 => AspectRatio{ .h = 256, .v = 135 },
            else => AspectRatio{ .h = 0, .v = 0 }, // undefined
        };

        // Bytes 4-5: Horizontal active (1 + value)
        const h_active = 1 + (@as(u16, data[4]) | (@as(u16, data[5]) << 8));

        // Bytes 6-7: Horizontal blank (1 + value)
        const h_blank = 1 + (@as(u16, data[6]) | (@as(u16, data[7]) << 8));

        // Bytes 8-9: Horizontal sync offset (1 + value), polarity in bit 7 of byte 9
        const h_sync_offset = 1 + (@as(u16, data[8]) | (@as(u16, data[9] & 0x7F) << 8));
        const h_sync_polarity: SyncPolarity = if ((data[9] & 0x80) != 0) .positive else .negative;

        // Bytes 10-11: Horizontal sync width (1 + value)
        const h_sync_width = 1 + (@as(u16, data[10]) | (@as(u16, data[11]) << 8));

        // Bytes 12-13: Vertical active (1 + value)
        const v_active = 1 + (@as(u16, data[12]) | (@as(u16, data[13]) << 8));

        // Bytes 14-15: Vertical blank (1 + value)
        const v_blank = 1 + (@as(u16, data[14]) | (@as(u16, data[15]) << 8));

        // Bytes 16-17: Vertical sync offset (1 + value), polarity in bit 7 of byte 17
        const v_sync_offset = 1 + (@as(u16, data[16]) | (@as(u16, data[17] & 0x7F) << 8));
        const v_sync_polarity: SyncPolarity = if ((data[17] & 0x80) != 0) .positive else .negative;

        // Bytes 18-19: Vertical sync width (1 + value)
        const v_sync_width = 1 + (@as(u16, data[18]) | (@as(u16, data[19]) << 8));

        return TypeITiming{
            .pixel_clock_hz = pixel_clock_hz,
            .preferred = preferred,
            .stereo_3d = stereo_3d,
            .interlaced = interlaced,
            .aspect_ratio = aspect_ratio,
            .h_active = h_active,
            .h_blank = h_blank,
            .h_sync_offset = h_sync_offset,
            .h_sync_polarity = h_sync_polarity,
            .h_sync_width = h_sync_width,
            .v_active = v_active,
            .v_blank = v_blank,
            .v_sync_offset = v_sync_offset,
            .v_sync_polarity = v_sync_polarity,
            .v_sync_width = v_sync_width,
        };
    }

    /// Calculate refresh rate in mHz
    pub fn getRefreshRate(self: TypeITiming) u32 {
        const h_total = @as(u64, self.h_active) + @as(u64, self.h_blank);
        const v_total = @as(u64, self.v_active) + @as(u64, self.v_blank);
        if (h_total == 0 or v_total == 0) return 0;

        const total_pixels = h_total * v_total;
        if (total_pixels == 0) return 0;

        // Convert to mHz using u64 to avoid overflow
        const pixel_clock_mhz = @as(u64, self.pixel_clock_hz) * 1000;
        return @intCast(pixel_clock_mhz / total_pixels);
    }
};

/// DisplayID Type II Detailed Timing (v1.x, 11 bytes)
/// Compressed format for common timings
pub const TypeIITiming = struct {
    /// Horizontal active pixels
    h_active: u16,
    /// Vertical active lines
    v_active: u16,
    /// Aspect ratio
    aspect_ratio: AspectRatio,
    /// Refresh rate in Hz
    refresh_rate_hz: u8,
    /// Interlaced
    interlaced: bool,
    /// Preferred
    preferred: bool,

    /// Parse Type II timing from data
    pub fn parse(data: []const u8) ?TypeIITiming {
        if (data.len < 11) return null;

        // Bytes 0-1: Horizontal active
        const h_active = @as(u16, data[0]) | (@as(u16, data[1] & 0x7F) << 8);

        // Bytes 2-3: Vertical active
        const v_active = @as(u16, data[2]) | (@as(u16, data[3] & 0x7F) << 8);

        // Bytes 4-5: Aspect ratio (1:1 to 256:256 range)
        const aspect_h = @as(u16, data[4]) + 1;
        const aspect_v = @as(u16, data[5]) + 1;

        // Byte 6: Refresh rate in Hz
        const refresh_rate_hz = data[6];

        // Byte 7: Options
        const options = data[7];
        const interlaced = (options & 0x01) != 0;
        const preferred = (options & 0x80) != 0;

        return TypeIITiming{
            .h_active = h_active,
            .v_active = v_active,
            .aspect_ratio = AspectRatio{ .h = aspect_h, .v = aspect_v },
            .refresh_rate_hz = refresh_rate_hz,
            .interlaced = interlaced,
            .preferred = preferred,
        };
    }
};

/// CVT/GTF timing code algorithm
pub const TimingFormula = enum(u8) {
    cvt = 0,
    cvt_reduced_blanking = 1,
    gtf = 2,
    _,
};

/// DisplayID Type III Short Timing Descriptor (v1.x, 3 bytes)
/// References CVT/GTF algorithms
pub const TypeIIITiming = struct {
    /// Horizontal active pixels
    h_active: u16,
    /// Vertical active lines
    v_active: u16,
    /// Aspect ratio
    aspect_ratio: AspectRatio,
    /// Refresh rate in Hz
    refresh_rate_hz: u8,
    /// Timing formula
    formula: TimingFormula,

    /// Parse Type III timing from data
    pub fn parse(data: []const u8) ?TypeIIITiming {
        if (data.len < 3) return null;

        // Byte 0: Horizontal active (in units of 8 pixels)
        const h_active = (@as(u16, data[0]) + 31) * 8;

        // Byte 1: bit 7-4: aspect ratio, bit 3-0: vertical (in units of 8 lines)
        const aspect_bits = (data[1] >> 4) & 0x0F;
        const v_base = (@as(u16, data[1] & 0x0F) + 31) * 8;

        // Calculate aspect ratio and vertical based on aspect bits
        const aspect_ratio = switch (aspect_bits) {
            0 => AspectRatio.ratio_16_10,
            1 => AspectRatio.ratio_4_3,
            2 => AspectRatio.ratio_5_4,
            3 => AspectRatio.ratio_16_9,
            else => AspectRatio.ratio_16_9, // default
        };

        const v_active = v_base;

        // Byte 2: bit 7-2: refresh rate (in 1Hz units), bit 1-0: timing formula
        const refresh_rate_hz = ((data[2] >> 2) & 0x3F) + 60;
        const formula: TimingFormula = @enumFromInt(data[2] & 0x03);

        return TypeIIITiming{
            .h_active = h_active,
            .v_active = v_active,
            .aspect_ratio = aspect_ratio,
            .refresh_rate_hz = refresh_rate_hz,
            .formula = formula,
        };
    }
};

/// DisplayID Type IV DMT Timing Code (v1.x, 1 byte)
/// References VESA DMT standard timing codes
pub const TypeIVTiming = struct {
    /// DMT ID
    dmt_id: u8,

    /// Parse Type IV timing from data
    pub fn parse(data: []const u8) ?TypeIVTiming {
        if (data.len < 1) return null;
        return TypeIVTiming{ .dmt_id = data[0] };
    }
};

/// DisplayID Type VII Detailed Timing (v2.x, 20 bytes)
/// Similar to Type I but with different pixel clock units (0.001 MHz vs 0.01 MHz)
pub const TypeVIITiming = struct {
    timing: TypeITiming,

    /// Parse Type VII timing (v2.x uses 0.001 MHz units)
    pub fn parse(data: []const u8) ?TypeVIITiming {
        const timing = TypeITiming.parseInternal(data, true) orelse return null;
        return TypeVIITiming{ .timing = timing };
    }
};

/// DisplayID Type VIII Enumerated Timing Code (v2.x, 1 byte)
/// Similar to Type IV
pub const TypeVIIITiming = struct {
    /// Timing code
    code: u8,

    /// Parse Type VIII timing
    pub fn parse(data: []const u8) ?TypeVIIITiming {
        if (data.len < 1) return null;
        return TypeVIIITiming{ .code = data[0] };
    }
};

/// DisplayID Type IX Formula-Based Timing (v2.x, 9 bytes)
/// New detailed formula-based timing for v2
pub const TypeIXTiming = struct {
    /// Horizontal active pixels
    h_active: u16,
    /// Vertical active lines
    v_active: u16,
    /// Refresh rate in 0.001 Hz units
    refresh_rate_mhz: u32,
    /// Timing formula
    formula: TimingFormula,

    /// Parse Type IX timing from data
    pub fn parse(data: []const u8) ?TypeIXTiming {
        if (data.len < 9) return null;

        // Bytes 0-1: Horizontal active
        const h_active = @as(u16, data[0]) | (@as(u16, data[1]) << 8);

        // Bytes 2-3: Vertical active
        const v_active = @as(u16, data[2]) | (@as(u16, data[3]) << 8);

        // Bytes 4-6: Refresh rate in 0.001 Hz units
        const refresh_rate_mhz = @as(u32, data[4]) |
            (@as(u32, data[5]) << 8) |
            (@as(u32, data[6]) << 16);

        // Byte 7: Timing options
        const formula: TimingFormula = @enumFromInt(data[7] & 0x03);

        return TypeIXTiming{
            .h_active = h_active,
            .v_active = v_active,
            .refresh_rate_mhz = refresh_rate_mhz,
            .formula = formula,
        };
    }
};

/// DisplayID Type X Dynamic Video Timing Range (v2.x, 11 bytes)
/// Defines supported timing ranges
pub const TypeXTiming = struct {
    /// Minimum pixel clock in Hz
    min_pixel_clock_hz: u32,
    /// Maximum pixel clock in Hz
    max_pixel_clock_hz: u32,
    /// Minimum horizontal active
    min_h_active: u16,
    /// Maximum horizontal active
    max_h_active: u16,
    /// Minimum vertical active
    min_v_active: u16,
    /// Maximum vertical active
    max_v_active: u16,

    /// Parse Type X timing range from data
    pub fn parse(data: []const u8) ?TypeXTiming {
        if (data.len < 11) return null;

        // Bytes 0-2: Min pixel clock in 10kHz units
        const min_pixel_clock_10khz = @as(u32, data[0]) |
            (@as(u32, data[1]) << 8) |
            (@as(u32, data[2]) << 16);

        // Bytes 3-5: Max pixel clock in 10kHz units
        const max_pixel_clock_10khz = @as(u32, data[3]) |
            (@as(u32, data[4]) << 8) |
            (@as(u32, data[5]) << 16);

        // Bytes 6-7: Min/Max horizontal (compressed)
        const min_h_active = (@as(u16, data[6]) + 1) * 8;
        const max_h_active = (@as(u16, data[7]) + 1) * 8;

        // Bytes 8-9: Min/Max vertical (compressed)
        const min_v_active = (@as(u16, data[8]) + 1) * 8;
        const max_v_active = (@as(u16, data[9]) + 1) * 8;

        return TypeXTiming{
            .min_pixel_clock_hz = min_pixel_clock_10khz * 10_000,
            .max_pixel_clock_hz = max_pixel_clock_10khz * 10_000,
            .min_h_active = min_h_active,
            .max_h_active = max_h_active,
            .min_v_active = min_v_active,
            .max_v_active = max_v_active,
        };
    }

    /// Check if a timing fits within this range
    pub fn supports(self: TypeXTiming, h_active: u16, v_active: u16, pixel_clock_hz: u32) bool {
        return h_active >= self.min_h_active and
            h_active <= self.max_h_active and
            v_active >= self.min_v_active and
            v_active <= self.max_v_active and
            pixel_clock_hz >= self.min_pixel_clock_hz and
            pixel_clock_hz <= self.max_pixel_clock_hz;
    }
};

// Tests

test "Type I timing parsing - 1080p60" {
    var data: [20]u8 = undefined;

    // 1920x1080@60Hz  
    // Pixel clock: 148.5 MHz = 148,500,000 Hz
    // Formula: (1 + raw) * 10,000 = 148,500,000
    // raw = 14,849 = 0x3A01 in hex
    data[0] = 0x01;
    data[1] = 0x3A;
    data[2] = 0x00;

    // Byte 3: Options
    // bit 7: preferred = 1
    // bits 6-5: stereo = 00 (never)
    // bit 4: interlaced = 0
    // bits 3-0: aspect ratio = 0100 (16:9)
    data[3] = 0x84; // 0b10000100

    // H active: 1920 (stored as 1919)
    const h_active_raw = 1920 - 1;
    data[4] = @intCast(h_active_raw & 0xFF);
    data[5] = @intCast((h_active_raw >> 8) & 0xFF);

    // H blank: 280 (stored as 279)
    const h_blank_raw = 280 - 1;
    data[6] = @intCast(h_blank_raw & 0xFF);
    data[7] = @intCast((h_blank_raw >> 8) & 0xFF);

    // H sync offset: 88 (stored as 87), with positive polarity (bit 7 = 1)
    const h_offset_raw = 88 - 1;
    data[8] = @intCast(h_offset_raw & 0xFF);
    data[9] = @intCast(((h_offset_raw >> 8) & 0x7F) | 0x80); // Set polarity bit

    // H sync width: 44 (stored as 43)
    const h_width_raw = 44 - 1;
    data[10] = @intCast(h_width_raw & 0xFF);
    data[11] = @intCast((h_width_raw >> 8) & 0xFF);

    // V active: 1080 (stored as 1079)
    const v_active_raw = 1080 - 1;
    data[12] = @intCast(v_active_raw & 0xFF);
    data[13] = @intCast((v_active_raw >> 8) & 0xFF);

    // V blank: 45 (stored as 44)
    const v_blank_raw = 45 - 1;
    data[14] = @intCast(v_blank_raw & 0xFF);
    data[15] = @intCast((v_blank_raw >> 8) & 0xFF);

    // V sync offset: 4 (stored as 3), with positive polarity (bit 7 = 1)
    const v_offset_raw = 4 - 1;
    data[16] = @intCast(v_offset_raw & 0xFF);
    data[17] = @intCast(((v_offset_raw >> 8) & 0x7F) | 0x80);

    // V sync width: 5 (stored as 4)
    const v_width_raw = 5 - 1;
    data[18] = @intCast(v_width_raw & 0xFF);
    data[19] = @intCast((v_width_raw >> 8) & 0xFF);

    const timing = TypeITiming.parse(&data).?;

    try testing.expectEqual(@as(u32, 148_500_000), timing.pixel_clock_hz);
    try testing.expectEqual(@as(u16, 1920), timing.h_active);
    try testing.expectEqual(@as(u16, 1080), timing.v_active);
    try testing.expectEqual(@as(u16, 280), timing.h_blank);
    try testing.expect(timing.preferred);
    try testing.expectEqual(SyncPolarity.positive, timing.h_sync_polarity);
    try testing.expectEqual(SyncPolarity.positive, timing.v_sync_polarity);
    try testing.expectEqual(Stereo3DSupport.never, timing.stereo_3d);
    try testing.expectEqual(@as(u16, 16), timing.aspect_ratio.h);
    try testing.expectEqual(@as(u16, 9), timing.aspect_ratio.v);
}

test "Type II timing parsing" {
    var data: [11]u8 = undefined;
    @memset(&data, 0);

    // 1920x1080, 16:9, 60Hz
    data[0] = 0x80;
    data[1] = 0x07;
    data[2] = 0x38;
    data[3] = 0x04;
    data[4] = 15; // 16:9 aspect (16-1)
    data[5] = 8; // 9-1
    data[6] = 60; // 60 Hz
    data[7] = 0x80; // Preferred

    const timing = TypeIITiming.parse(&data).?;

    try testing.expectEqual(@as(u16, 1920), timing.h_active);
    try testing.expectEqual(@as(u16, 1080), timing.v_active);
    try testing.expectEqual(@as(u8, 60), timing.refresh_rate_hz);
    try testing.expect(timing.preferred);
}

test "Type III timing parsing" {
    var data: [3]u8 = undefined;

    // 1920x1080, 60Hz, CVT
    data[0] = (1920 / 8) - 31; // H active
    data[1] = (3 << 4) | ((1080 / 8) - 31); // 16:9 aspect + V active
    data[2] = ((60 - 60) << 2) | 0; // 60Hz + CVT

    const timing = TypeIIITiming.parse(&data).?;

    try testing.expectEqual(@as(u16, 1920), timing.h_active);
    try testing.expectEqual(@as(u8, 60), timing.refresh_rate_hz);
    try testing.expectEqual(TimingFormula.cvt, timing.formula);
}

test "Type IV timing parsing" {
    const data = [_]u8{0x52}; // DMT 0x52 = 1920x1080@60Hz
    const timing = TypeIVTiming.parse(&data).?;

    try testing.expectEqual(@as(u8, 0x52), timing.dmt_id);
}

test "Type IX timing parsing" {
    var data: [9]u8 = undefined;

    // 3840x2160@60Hz (60000 mHz)
    data[0] = 0x00;
    data[1] = 0x0F; // 3840
    data[2] = 0x70;
    data[3] = 0x08; // 2160
    data[4] = 0x60;
    data[5] = 0xEA;
    data[6] = 0x00; // 60000 mHz
    data[7] = 0x00; // CVT
    data[8] = 0x00;

    const timing = TypeIXTiming.parse(&data).?;

    try testing.expectEqual(@as(u16, 3840), timing.h_active);
    try testing.expectEqual(@as(u16, 2160), timing.v_active);
    try testing.expectEqual(@as(u32, 60000), timing.refresh_rate_mhz);
}

test "Type X timing range parsing" {
    var data: [11]u8 = undefined;

    // Range: 25-170 MHz, 640-1920 pixels, 480-1080 lines
    // 25 MHz = 25,000,000 Hz = 2,500 * 10kHz = 0x09C4
    data[0] = 0xC4;
    data[1] = 0x09;
    data[2] = 0x00;
    // 170 MHz = 170,000,000 Hz = 17,000 * 10kHz = 0x4268
    data[3] = 0x68;
    data[4] = 0x42;
    data[5] = 0x00;
    data[6] = (640 / 8) - 1; // Min H
    data[7] = (1920 / 8) - 1; // Max H
    data[8] = (480 / 8) - 1; // Min V
    data[9] = (1080 / 8) - 1; // Max V
    data[10] = 0x00;

    const timing = TypeXTiming.parse(&data).?;

    try testing.expectEqual(@as(u32, 25_000_000), timing.min_pixel_clock_hz);
    try testing.expectEqual(@as(u16, 640), timing.min_h_active);
    try testing.expectEqual(@as(u16, 1920), timing.max_h_active);

    // Test range checking
    try testing.expect(timing.supports(1920, 1080, 148_500_000));
    try testing.expect(!timing.supports(3840, 2160, 300_000_000));
}
