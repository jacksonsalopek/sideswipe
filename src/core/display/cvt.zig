//! CVT (Coordinated Video Timings) calculator
//!
//! Implements VESA CVT standard version 2.0 for generating video timings.

const std = @import("std");
const testing = std.testing;

/// CVT reduced blanking version
pub const ReducedBlankingVersion = enum {
    none,
    v1,
    v2,
    v3,
};

/// CVT input options
pub const Options = struct {
    /// Version of reduced blanking to use
    reduced_blanking: ReducedBlankingVersion = .none,
    /// Desired horizontal pixels (active)
    h_pixels: u32,
    /// Desired vertical lines (active)
    v_lines: u32,
    /// Target refresh rate in Hz
    refresh_rate_hz: f64,
    /// Interlaced mode (non-RB and RBv1 only)
    interlaced: bool = false,
    /// Add margins (non-RB and RBv1 only)
    margins: bool = false,
    /// Video-optimized timing (RBv2 only)
    video_optimized: bool = false,
    /// Desired VBlank time in microseconds (RBv3 only, must be > 460)
    vblank_us: f64 = 460.0,
    /// Additional HBlank pixels (RBv3 only, must be multiple of 8, 0-120)
    additional_hblank: u32 = 0,
    /// Early VSync (RBv3 only)
    early_vsync: bool = false,
};

/// CVT output timing
pub const Timing = struct {
    /// Pixel clock in MHz
    pixel_clock_mhz: f64,
    /// Horizontal timings (pixels)
    h_active: u32,
    h_front_porch: u32,
    h_sync: u32,
    h_back_porch: u32,
    h_total: u32,
    /// Vertical timings (lines)
    v_active: u32,
    v_front_porch: u32,
    v_sync: u32,
    v_back_porch: u32,
    v_total: u32,
    /// Actual frequencies
    h_freq_khz: f64,
    v_freq_hz: f64,
};

/// CVT constants
const margin_perc = 1.8;
const min_vsync_bp = 550.0; // microseconds
const min_v_porch = 3;
const min_v_bporch = 7;
const fixed_v_bporch = 6;
const c_prime = 30.0;
const m_prime = 300.0;
const rb_min_vblank = 460.0; // microseconds

/// Compute CVT timing following VESA CVT 2.0 specification
pub fn compute(options: Options) Timing {
    const rb = options.reduced_blanking;
    
    // Cell granularity
    const cell_gran: f64 = if (rb == .v2) 1.0 else 8.0;
    
    // Round to cell granularity
    const h_pixels_rnd = @floor(@as(f64, @floatFromInt(options.h_pixels)) / cell_gran) * cell_gran;
    const v_lines_rnd = if (options.interlaced)
        @floor(@as(f64, @floatFromInt(options.v_lines)) / 2.0)
    else
        @as(f64, @floatFromInt(options.v_lines));
    
    // Calculate margins
    const h_margin = if (options.margins)
        @floor((h_pixels_rnd * margin_perc / 100.0) / cell_gran) * cell_gran
    else
        0.0;
    
    const v_margin = if (options.margins)
        @floor(margin_perc / 100.0 * v_lines_rnd)
    else
        0.0;
    
    const interlace: f64 = if (options.interlaced) 0.5 else 0.0;
    const total_active_pixels = h_pixels_rnd + h_margin * 2.0;
    const v_field_rate_rqd = if (options.interlaced)
        options.refresh_rate_hz * 2.0
    else
        options.refresh_rate_hz;
    
    // Clock step precision
    const clock_step: f64 = if (rb == .v2 or rb == .v3) 0.001 else 0.25;
    
    // Horizontal blanking
    var h_blank: f64 = if (rb == .v1) 160.0 else 80.0;
    const h_sync: f64 = 32.0;
    
    // Add additional blanking for RBv3
    if (rb == .v3) {
        var additional: f64 = @floatFromInt(options.additional_hblank);
        if (additional < 0) additional = 0;
        if (additional > 120) additional = 120;
        h_blank += additional;
    }
    
    // Determine VSync based on aspect ratio
    const v_sync: f64 = blk: {
        if (rb == .v2 or rb == .v3) {
            break :blk 8.0;
        }
        
        const h_pix = options.h_pixels;
        const v_lin = options.v_lines;
        
        if ((v_lin * 4 / 3) == h_pix) break :blk 4.0;
        if ((v_lin * 16 / 9) == h_pix) break :blk 5.0;
        if ((v_lin * 16 / 10) == h_pix) break :blk 6.0;
        if (((v_lin % 4) == 0) and ((v_lin * 5 / 4) == h_pix)) break :blk 7.0;
        if ((v_lin * 15 / 9) == h_pix) break :blk 7.0;
        break :blk 10.0; // Custom
    };
    
    const rb_v_fporch: f64 = if (rb == .v1) 3.0 else 1.0;
    var rb_min_vbl = if (rb == .v3) options.vblank_us else rb_min_vblank;
    if (rb_min_vbl < rb_min_vblank) rb_min_vbl = rb_min_vblank;
    
    var v_blank: f64 = undefined;
    var v_sync_bp: f64 = undefined;
    var total_pixels: f64 = undefined;
    var pixel_freq: f64 = undefined;
    var total_v_lines: f64 = undefined;
    
    if (rb == .none) {
        // Standard CVT blanking
        const h_period_est = (1.0 / v_field_rate_rqd - min_vsync_bp / 1_000_000.0) /
            (v_lines_rnd + v_margin * 2.0 + min_v_porch + interlace) * 1_000_000.0;
        
        v_sync_bp = @floor(min_vsync_bp / h_period_est) + 1.0;
        if (v_sync_bp < v_sync + min_v_bporch) {
            v_sync_bp = v_sync + min_v_bporch;
        }
        
        v_blank = v_sync_bp + min_v_porch;
        total_v_lines = v_lines_rnd + v_margin * 2.0 + v_sync_bp + interlace + min_v_porch;
        
        const ideal_duty_cycle = c_prime - m_prime * h_period_est / 1000.0;
        h_blank = @floor(total_active_pixels * ideal_duty_cycle /
            (100.0 - ideal_duty_cycle) / (2.0 * cell_gran)) * 2.0 * cell_gran;
        
        total_pixels = total_active_pixels + h_blank;
        pixel_freq = @floor(total_pixels / h_period_est / clock_step) * clock_step;
    } else {
        // Reduced blanking
        const h_period_est = (1_000_000.0 / v_field_rate_rqd - rb_min_vbl) /
            (v_lines_rnd + v_margin * 2.0);
        
        const vbi_lines = @floor(rb_min_vbl / h_period_est) + 1.0;
        const rb_v_bporch: f64 = if (rb == .v1) min_v_bporch else fixed_v_bporch;
        const rb_min_vbi = rb_v_fporch + v_sync + rb_v_bporch;
        
        v_blank = if (vbi_lines < rb_min_vbi) rb_min_vbi else vbi_lines;
        total_v_lines = v_blank + v_lines_rnd + v_margin * 2.0 + interlace;
        
        v_sync_bp = v_sync + rb_v_bporch;
        total_pixels = h_blank + total_active_pixels;
        
        const refresh_multiplier: f64 = if (rb == .v2 and options.video_optimized)
            1000.0 / 1001.0
        else
            1.0;
        
        const freq = v_field_rate_rqd * total_v_lines * total_pixels * refresh_multiplier;
        pixel_freq = if (rb == .v3)
            @ceil(freq / 1_000_000.0 / clock_step) * clock_step
        else
            @floor(freq / 1_000_000.0 / clock_step) * clock_step;
    }
    
    const h_front_porch: f64 = if (rb == .v2 or rb == .v3)
        8.0
    else
        (h_blank / 2.0) - h_sync;
    
    const v_back_porch = v_sync_bp - v_sync;
    const v_front_porch = v_blank - v_back_porch - v_sync;
    const h_back_porch = h_blank - h_front_porch - h_sync;
    
    const act_h_freq = 1000.0 * pixel_freq / total_pixels;
    const act_v_freq = act_h_freq * 1000.0 / total_v_lines;
    
    return Timing{
        .pixel_clock_mhz = pixel_freq,
        .h_active = @intFromFloat(total_active_pixels - h_margin * 2.0),
        .h_front_porch = @intFromFloat(h_front_porch),
        .h_sync = @intFromFloat(h_sync),
        .h_back_porch = @intFromFloat(h_back_porch),
        .h_total = @intFromFloat(total_pixels),
        .v_active = @intFromFloat(v_lines_rnd),
        .v_front_porch = @intFromFloat(v_front_porch),
        .v_sync = @intFromFloat(v_sync),
        .v_back_porch = @intFromFloat(v_back_porch),
        .v_total = @intFromFloat(total_v_lines),
        .h_freq_khz = act_h_freq,
        .v_freq_hz = act_v_freq,
    };
}

// Tests

test "CVT compute 1920x1080 @ 60Hz" {
    const options = Options{
        .h_pixels = 1920,
        .v_lines = 1080,
        .refresh_rate_hz = 60.0,
    };
    
    const timing = compute(options);
    
    try testing.expectEqual(@as(u32, 1920), timing.h_active);
    try testing.expectEqual(@as(u32, 1080), timing.v_active);
    try testing.expect(timing.v_freq_hz > 59.0 and timing.v_freq_hz < 61.0);
    // CVT spec generates ~173 MHz for 1920x1080@60
    try testing.expect(timing.pixel_clock_mhz > 100.0 and timing.pixel_clock_mhz < 200.0);
}

test "CVT compute with reduced blanking" {
    const options = Options{
        .h_pixels = 1920,
        .v_lines = 1080,
        .refresh_rate_hz = 60.0,
        .reduced_blanking = .v1,
    };
    
    const timing = compute(options);
    
    try testing.expectEqual(@as(u32, 1920), timing.h_active);
    // Reduced blanking should have less blanking area
    try testing.expect(timing.h_total < 2200);
    try testing.expect(timing.pixel_clock_mhz < 150.0); // Less than standard
}
