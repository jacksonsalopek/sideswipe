//! HDR policy, surface intent, and SDR-container helpers (H5–H8).
//!
//! Honest v1 subset: parametric + Windows-scRGB/BT.2100 creators, double-buffered
//! surface intent, fullscreen passthrough. SHM fullscreen is an 8-bit opaque
//! copy (no linear blend); DRM tries client-FB scanout. ICC profiles and
//! mixed-strip HDR (M7) are unsupported. `on` matches `auto` (passthrough only).

const std = @import("std");
const string = @import("core.string").string;
const testing = @import("core").testing;

pub const Policy = enum {
    auto,
    on,
    off,

    pub fn parse(value: string) ?Policy {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "on")) return .on;
        if (std.mem.eql(u8, value, "off")) return .off;
        return null;
    }
};

pub const Transfer = enum {
    sdr,
    pq,
    hlg,
    /// Windows-scRGB: extended-linear; KMS still signals BT.2100/PQ.
    scrgb,
};

pub const Intent = struct {
    transfer: Transfer = .sdr,
    bt2020: bool = false,
    max_cll: u16 = 0,
    max_fall: u16 = 0,
    max_luminance: u16 = 0,
    min_luminance: u16 = 0,

    pub fn sdr() Intent {
        return .{};
    }

    pub fn isHdr(self: Intent) bool {
        return self.transfer != .sdr;
    }
};

pub const Caps = struct {
    hdr10: bool = false,
    hlg: bool = false,
    bt2020: bool = false,
    max_luminance_cdm2: f32 = 0,
    max_frame_avg_luminance_cdm2: f32 = 0,
    min_luminance_cdm2: f32 = 0,

    pub fn allowsHdr(self: Caps) bool {
        return self.hdr10 or self.hlg;
    }
};

pub const Scanout = enum {
    sdr,
    hdr_passthrough,
};

/// `auto` and v1 `on` engage HDR only for fullscreen passthrough (H7). Mixed strips stay SDR.
pub fn decide(policy: Policy, caps: Caps, fullscreen_hdr: bool) Scanout {
    if (policy == .off or !caps.allowsHdr() or !fullscreen_hdr) return .sdr;
    return .hdr_passthrough;
}

/// Preferred output description stays sRGB until HDR scanout is actually engaged (H7).
pub fn preferredIntent(caps: Caps, engaged: bool) Intent {
    if (!engaged or !caps.allowsHdr()) return Intent.sdr();
    return .{ .transfer = if (caps.hdr10) .pq else .hlg, .bt2020 = caps.bt2020 };
}

pub const Metadata = struct {
    eotf: u8 = 2,
    primaries: [3][2]u16 = bt2020_primaries,
    white_point: [2]u16 = d65_white,
    max_mastering: u16 = 1000,
    min_mastering: u16 = 50,
    max_cll: u16 = 1000,
    max_fall: u16 = 400,
};

pub const bt2020_primaries = [3][2]u16{
    .{ 35400, 14600 },
    .{ 8500, 39850 },
    .{ 6550, 2300 },
};

pub const d65_white = [2]u16{ 15635, 16450 };

pub const eotf_sdr: u8 = 0;
pub const eotf_pq: u8 = 2;
pub const eotf_hlg: u8 = 3;

pub fn metadataFrom(intent: Intent, caps: Caps) Metadata {
    var meta = Metadata{
        .eotf = switch (intent.transfer) {
            .hlg => eotf_hlg,
            .pq, .scrgb, .sdr => eotf_pq,
        },
    };
    if (intent.max_cll != 0) meta.max_cll = intent.max_cll;
    if (intent.max_fall != 0) meta.max_fall = intent.max_fall;
    if (intent.max_luminance != 0) meta.max_mastering = intent.max_luminance;
    if (intent.min_luminance != 0) meta.min_mastering = intent.min_luminance;
    if (caps.max_luminance_cdm2 > 0 and intent.max_luminance == 0)
        meta.max_mastering = luminanceToU16(caps.max_luminance_cdm2);
    if (caps.max_frame_avg_luminance_cdm2 > 0 and intent.max_fall == 0)
        meta.max_fall = luminanceToU16(caps.max_frame_avg_luminance_cdm2);
    return meta;
}

fn luminanceToU16(value: f32) u16 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@min(value, 65535));
}

/// Optical (linear-light) sRGB encode used for SDR blends (H8).
pub fn srgbToLinear(channel: u8) f32 {
    const encoded = @as(f32, @floatFromInt(channel)) / 255;
    if (encoded <= 0.04045) return encoded / 12.92;
    return std.math.pow(f32, (encoded + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(linear: f32) u8 {
    const clamped = std.math.clamp(linear, 0, 1);
    const encoded = if (clamped <= 0.0031308)
        clamped * 12.92
    else
        1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255));
}

pub fn blendLinear(destination: u8, source: u8, alpha: u8) u8 {
    const a = @as(f32, @floatFromInt(alpha)) / 255;
    return linearToSrgb(srgbToLinear(source) * a + srgbToLinear(destination) * (1 - a));
}

/// Fixed Reinhard operator for mixed-strip SDR containers (H6 / M7 hold).
pub fn reinhard(channel: u8) u8 {
    const linear = srgbToLinear(channel);
    return linearToSrgb(linear / (1 + linear));
}

test "policy parse accepts auto on off" {
    try testing.expectEqual(Policy.auto, Policy.parse("auto").?);
    try testing.expectEqual(Policy.on, Policy.parse("on").?);
    try testing.expectEqual(Policy.off, Policy.parse("off").?);
    try testing.expectNull(Policy.parse("hdr"));
}

test "preferred intent is SDR until HDR is engaged" {
    const caps = Caps{ .hdr10 = true, .bt2020 = true };
    try testing.expectEqual(Transfer.sdr, preferredIntent(caps, false).transfer);
    try testing.expectEqual(Transfer.pq, preferredIntent(caps, true).transfer);
    try testing.expect((preferredIntent(caps, true)).bt2020);
    try testing.expectEqual(Transfer.sdr, preferredIntent(.{}, true).transfer);
}

test "decide keeps SDR unless fullscreen HDR is allowed" {
    const caps = Caps{ .hdr10 = true };
    try testing.expectEqual(Scanout.sdr, decide(.off, caps, true));
    try testing.expectEqual(Scanout.sdr, decide(.auto, .{}, true));
    try testing.expectEqual(Scanout.sdr, decide(.auto, caps, false));
    try testing.expectEqual(Scanout.hdr_passthrough, decide(.auto, caps, true));
    try testing.expectEqual(Scanout.hdr_passthrough, decide(.on, caps, true));
}

test "intent reports HDR for PQ, HLG, and scRGB" {
    try testing.expect(!Intent.sdr().isHdr());
    try testing.expect((Intent{ .transfer = .pq }).isHdr());
    try testing.expect((Intent{ .transfer = .hlg, .bt2020 = true }).isHdr());
    try testing.expect((Intent{ .transfer = .scrgb }).isHdr());
}

test "scRGB metadata maps to PQ for KMS" {
    const meta = metadataFrom(.{ .transfer = .scrgb, .max_cll = 400 }, .{});
    try testing.expectEqual(eotf_pq, meta.eotf);
    try testing.expectEqual(@as(u16, 400), meta.max_cll);
}

test "metadata uses PQ BT.2020 defaults and client CLL" {
    const meta = metadataFrom(.{ .transfer = .pq, .max_cll = 600, .max_fall = 200 }, .{});
    try testing.expectEqual(eotf_pq, meta.eotf);
    try testing.expectEqual(@as(u16, 35400), meta.primaries[0][0]);
    try testing.expectEqual(@as(u16, 600), meta.max_cll);
    try testing.expectEqual(@as(u16, 200), meta.max_fall);
}

test "linear blend is not electrical-space lerp" {
    const electrical = @as(u8, 128);
    const linear = blendLinear(0, 255, 128);
    try testing.expect(linear != electrical);
    try testing.expect(linear > 170);
}

test "reinhard compresses highlights without clipping black" {
    try testing.expectEqual(@as(u8, 0), reinhard(0));
    try testing.expect(reinhard(255) < 255);
    try testing.expect(reinhard(200) < 200);
}
