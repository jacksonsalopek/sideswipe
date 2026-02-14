//! CTA-861 HDMI Vendor-Specific Data Block parsing
//!
//! HDMI VSDB provides HDMI-specific capabilities like deep color,
//! physical address, and 3D support.

const std = @import("std");
const testing = std.testing;

/// HDMI IEEE OUI (0x000C03)
pub const hdmi_oui: u24 = 0x000C03;

/// HDMI Forum IEEE OUI (0xC45DD8)
pub const hdmi_forum_oui: u24 = 0xC45DD8;

/// HDMI Vendor-Specific Data Block
pub const Vsdb = struct {
    /// Source physical address (A.B.C.D format)
    physical_address: [4]u8,
    
    /// Supports AI (Auxiliary Information) packets
    supports_ai: bool,
    
    /// Deep color support flags
    dc_48bit: bool,  // 16 bits per component
    dc_36bit: bool,  // 12 bits per component
    dc_30bit: bool,  // 10 bits per component
    dc_y444: bool,   // Deep color for YCbCr 4:4:4
    
    /// DVI dual-link operation
    dvi_dual: bool,
    
    /// Maximum TMDS clock in MHz (0 if not specified)
    max_tmds_clock_mhz: u16,
    
    /// Content type support
    supports_content_type: bool,
    
    /// Latency fields present
    has_latency_fields: bool,
    has_interlaced_latency_fields: bool,
    
    /// Video latency in milliseconds (0 if not present)
    video_latency_ms: u16,
    audio_latency_ms: u16,
    interlaced_video_latency_ms: u16,
    interlaced_audio_latency_ms: u16,
    
    /// Parse HDMI VSDB from data block payload
    pub fn parse(data: []const u8) ?Vsdb {
        if (data.len < 5) return null; // Minimum: 3 OUI + 2 address bytes
        
        // Check OUI (bytes 0-2)
        const oui = @as(u24, data[0]) | 
                   (@as(u24, data[1]) << 8) | 
                   (@as(u24, data[2]) << 16);
        
        if (oui != hdmi_oui) return null;
        
        // Physical address (bytes 3-4)
        const addr_word = (@as(u16, data[3]) << 8) | data[4];
        const physical_address = [4]u8{
            @intCast((addr_word >> 12) & 0x0F),  // A
            @intCast((addr_word >> 8) & 0x0F),   // B
            @intCast((addr_word >> 4) & 0x0F),   // C
            @intCast(addr_word & 0x0F),          // D
        };
        
        var vsdb = Vsdb{
            .physical_address = physical_address,
            .supports_ai = false,
            .dc_48bit = false,
            .dc_36bit = false,
            .dc_30bit = false,
            .dc_y444 = false,
            .dvi_dual = false,
            .max_tmds_clock_mhz = 0,
            .supports_content_type = false,
            .has_latency_fields = false,
            .has_interlaced_latency_fields = false,
            .video_latency_ms = 0,
            .audio_latency_ms = 0,
            .interlaced_video_latency_ms = 0,
            .interlaced_audio_latency_ms = 0,
        };
        
        // Parse optional fields
        if (data.len < 6) return vsdb;
        
        // Byte 5: flags
        const flags = data[5];
        vsdb.supports_ai = (flags & 0x80) != 0;
        vsdb.dc_48bit = (flags & 0x40) != 0;
        vsdb.dc_36bit = (flags & 0x20) != 0;
        vsdb.dc_30bit = (flags & 0x10) != 0;
        vsdb.dc_y444 = (flags & 0x08) != 0;
        vsdb.dvi_dual = (flags & 0x01) != 0;
        
        if (data.len < 7) return vsdb;
        
        // Byte 6: Max TMDS clock
        if (data[6] > 0) {
            vsdb.max_tmds_clock_mhz = @as(u16, data[6]) * 5;
        }
        
        if (data.len < 8) return vsdb;
        
        // Byte 7: Latency flags
        const latency_flags = data[7];
        vsdb.has_latency_fields = (latency_flags & 0x80) != 0;
        vsdb.has_interlaced_latency_fields = (latency_flags & 0x40) != 0;
        vsdb.supports_content_type = (latency_flags & 0x08) != 0;
        
        var offset: usize = 8;
        
        // Parse latency fields if present
        if (vsdb.has_latency_fields and offset + 2 <= data.len) {
            vsdb.video_latency_ms = if (data[offset] > 0) (@as(u16, data[offset]) - 1) * 2 else 0;
            vsdb.audio_latency_ms = if (data[offset + 1] > 0) (@as(u16, data[offset + 1]) - 1) * 2 else 0;
            offset += 2;
        }
        
        if (vsdb.has_interlaced_latency_fields and offset + 2 <= data.len) {
            vsdb.interlaced_video_latency_ms = if (data[offset] > 0) (@as(u16, data[offset]) - 1) * 2 else 0;
            vsdb.interlaced_audio_latency_ms = if (data[offset + 1] > 0) (@as(u16, data[offset + 1]) - 1) * 2 else 0;
        }
        
        return vsdb;
    }
    
    /// Get physical address as string (A.B.C.D format)
    pub fn formatPhysicalAddress(self: Vsdb, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            self.physical_address[0],
            self.physical_address[1],
            self.physical_address[2],
            self.physical_address[3],
        });
    }
};

// Tests

test "HDMI VSDB parsing - minimal" {
    // Minimal: OUI + physical address
    const data = [_]u8{
        0x03, 0x0C, 0x00,  // HDMI OUI (0x000C03)
        0x10, 0x00,        // Physical address 1.0.0.0
    };
    
    const vsdb = Vsdb.parse(&data).?;
    
    try testing.expectEqual([4]u8{ 1, 0, 0, 0 }, vsdb.physical_address);
    try testing.expect(!vsdb.supports_ai);
    try testing.expect(!vsdb.dc_36bit);
}

test "HDMI VSDB parsing - with deep color" {
    const data = [_]u8{
        0x03, 0x0C, 0x00,  // HDMI OUI
        0x20, 0x00,        // Physical address 2.0.0.0
        0xB0,              // 0b10110000: AI (bit7) + DC_36bit (bit5) + DC_30bit (bit4)
    };
    
    const vsdb = Vsdb.parse(&data).?;
    
    try testing.expectEqual([4]u8{ 2, 0, 0, 0 }, vsdb.physical_address);
    try testing.expect(vsdb.supports_ai);
    try testing.expect(vsdb.dc_36bit);
    try testing.expect(vsdb.dc_30bit);
    try testing.expect(!vsdb.dc_48bit);
}

test "HDMI VSDB parsing - with TMDS clock" {
    const data = [_]u8{
        0x03, 0x0C, 0x00,  // HDMI OUI
        0x10, 0x00,        // Physical address
        0x00,              // No deep color
        170,               // Max TMDS clock: 170 * 5 = 850 MHz
    };
    
    const vsdb = Vsdb.parse(&data).?;
    
    try testing.expectEqual(@as(u16, 850), vsdb.max_tmds_clock_mhz);
}

test "HDMI VSDB parsing - with latency" {
    const data = [_]u8{
        0x03, 0x0C, 0x00,  // HDMI OUI
        0x10, 0x00,        // Physical address
        0x00,              // Flags
        0,                 // Max TMDS clock
        0x80,              // Latency fields present
        21,                // Video latency: (21-1)*2 = 40ms
        11,                // Audio latency: (11-1)*2 = 20ms
    };
    
    const vsdb = Vsdb.parse(&data).?;
    
    try testing.expect(vsdb.has_latency_fields);
    try testing.expectEqual(@as(u16, 40), vsdb.video_latency_ms);
    try testing.expectEqual(@as(u16, 20), vsdb.audio_latency_ms);
}

test "HDMI VSDB parsing - wrong OUI" {
    const data = [_]u8{
        0xFF, 0xFF, 0xFF,  // Wrong OUI
        0x10, 0x00,
    };
    
    const vsdb = Vsdb.parse(&data);
    try testing.expect(vsdb == null);
}

test "physical address formatting" {
    const vsdb = Vsdb{
        .physical_address = [4]u8{ 2, 1, 0, 0 },
        .supports_ai = false,
        .dc_48bit = false,
        .dc_36bit = false,
        .dc_30bit = false,
        .dc_y444 = false,
        .dvi_dual = false,
        .max_tmds_clock_mhz = 0,
        .supports_content_type = false,
        .has_latency_fields = false,
        .has_interlaced_latency_fields = false,
        .video_latency_ms = 0,
        .audio_latency_ms = 0,
        .interlaced_video_latency_ms = 0,
        .interlaced_audio_latency_ms = 0,
    };
    
    var buf: [16]u8 = undefined;
    const addr_str = try vsdb.formatPhysicalAddress(&buf);
    
    try testing.expectEqualStrings("2.1.0.0", addr_str);
}

/// HDMI Forum Vendor-Specific Data Block (HDMI 2.0+)
pub const ForumVsdb = struct {
    /// HDMI 2.0 version
    version: u8,
    
    /// Maximum FRL (Fixed Rate Link) rate in Gbps
    /// 0 = no FRL support, 1-6 = rate levels
    max_frl_rate_gbps: u8,
    
    /// Source supports SCDC (Status and Control Data Channel)
    supports_scdc: bool,
    
    /// Source supports Read Request
    supports_rr: bool,
    
    /// Source supports ALLM (Auto Low Latency Mode)
    supports_allm: bool,
    
    /// Source supports VRR (Variable Refresh Rate)
    supports_vrr: bool,
    
    /// Source supports QMS (Quick Media Switching)
    supports_qms: bool,
    
    /// DSC (Display Stream Compression) capabilities
    supports_dsc: bool,
    dsc_max_slices: u8,
    dsc_max_frl_rate_gbps: u8,
    
    /// Parse HDMI Forum VSDB from vendor-specific data block
    pub fn parse(data: []const u8) ?ForumVsdb {
        if (data.len < 4) return null;
        
        // Check OUI (bytes 0-2)
        const oui = @as(u24, data[0]) | 
                   (@as(u24, data[1]) << 8) | 
                   (@as(u24, data[2]) << 16);
        
        if (oui != hdmi_forum_oui) return null;
        
        // Version (byte 3)
        const version = data[3];
        
        var vsdb = ForumVsdb{
            .version = version,
            .max_frl_rate_gbps = 0,
            .supports_scdc = false,
            .supports_rr = false,
            .supports_allm = false,
            .supports_vrr = false,
            .supports_qms = false,
            .supports_dsc = false,
            .dsc_max_slices = 0,
            .dsc_max_frl_rate_gbps = 0,
        };
        
        if (data.len < 5) return vsdb;
        
        // Byte 4: Max FRL rate (bits 7-4) and flags
        const byte4 = data[4];
        vsdb.max_frl_rate_gbps = @intCast((byte4 >> 4) & 0x0F);
        
        if (data.len < 6) return vsdb;
        
        // Byte 5: Feature flags
        const byte5 = data[5];
        vsdb.supports_scdc = (byte5 & 0x80) != 0;
        vsdb.supports_rr = (byte5 & 0x40) != 0;
        
        if (data.len < 7) return vsdb;
        
        // Byte 6: More flags
        const byte6 = data[6];
        vsdb.supports_allm = (byte6 & 0x02) != 0;
        
        if (data.len < 8) return vsdb;
        
        // Byte 7: VRR and QMS
        const byte7 = data[7];
        vsdb.supports_vrr = (byte7 & 0x40) != 0;
        vsdb.supports_qms = (byte7 & 0x80) != 0;
        
        // DSC capabilities (if present)
        if (data.len >= 12) {
            const byte11 = data[11];
            vsdb.supports_dsc = (byte11 & 0x01) != 0;
            
            if (vsdb.supports_dsc and data.len >= 13) {
                const byte12 = data[12];
                vsdb.dsc_max_slices = @intCast((byte12 >> 4) & 0x0F);
                vsdb.dsc_max_frl_rate_gbps = @intCast(byte12 & 0x0F);
            }
        }
        
        return vsdb;
    }
};

// Tests for HDMI Forum VSDB

test "HDMI Forum VSDB parsing - basic" {
    const data = [_]u8{
        0xD8, 0x5D, 0xC4,  // HDMI Forum OUI (0xC45DD8)
        0x01,              // Version 1
    };
    
    const vsdb = ForumVsdb.parse(&data).?;
    
    try testing.expectEqual(@as(u8, 1), vsdb.version);
    try testing.expectEqual(@as(u8, 0), vsdb.max_frl_rate_gbps);
}

test "HDMI Forum VSDB parsing - with FRL" {
    const data = [_]u8{
        0xD8, 0x5D, 0xC4,  // OUI
        0x01,              // Version
        0x60,              // Max FRL rate: 6 (48 Gbps)
    };
    
    const vsdb = ForumVsdb.parse(&data).?;
    
    try testing.expectEqual(@as(u8, 6), vsdb.max_frl_rate_gbps);
}

test "HDMI Forum VSDB parsing - with ALLM and VRR" {
    const data = [_]u8{
        0xD8, 0x5D, 0xC4,  // OUI
        0x01,              // Version
        0x00,              // Byte 4
        0x00,              // Byte 5
        0x02,              // Byte 6: ALLM support
        0xC0,              // Byte 7: VRR + QMS
    };
    
    const vsdb = ForumVsdb.parse(&data).?;
    
    try testing.expect(vsdb.supports_allm);
    try testing.expect(vsdb.supports_vrr);
    try testing.expect(vsdb.supports_qms);
}

test "HDMI Forum VSDB parsing - wrong OUI" {
    const data = [_]u8{
        0xFF, 0xFF, 0xFF,  // Wrong OUI
        0x01,
    };
    
    const vsdb = ForumVsdb.parse(&data);
    try testing.expect(vsdb == null);
}
