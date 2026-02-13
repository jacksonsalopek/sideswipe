//! GTF (Generalized Timing Formula) calculator
//!
//! Implements VESA GTF standard for generating video timings.
//! This is the legacy standard for CRT displays.

const std = @import("std");
const testing = std.testing;

/// GTF input parameter type
pub const InputParam = enum {
    /// Vertical frame rate (Hz)
    v_frame_rate,
    /// Horizontal frequency (kHz)
    h_freq,
    /// Pixel clock rate (MHz)
    pixel_clock,
};

/// GTF input options
pub const Options = struct {
    /// Desired horizontal pixels (active)
    h_pixels: u32,
    /// Desired vertical lines (active)
    v_lines: u32,
    /// Input parameter type
    ip_param: InputParam,
    /// Input frequency (meaning depends on ip_param)
    ip_freq: f64,
    /// Interlaced mode
    interlaced: bool = false,
    /// Add margins
    margins: bool = false,
    /// GTF parameters (use defaults if not specified)
    c: f64 = 40.0,
    m: f64 = 600.0,
    k: f64 = 128.0,
    j: f64 = 20.0,
};

/// GTF output timing
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
    /// Actual frequencies achieved
    h_freq_khz: f64,
    v_freq_hz: f64,
};

/// GTF constants
const cell_gran = 8.0;
const margin_perc = 1.8;
const min_porch = 1.0;
const v_sync_rqd = 3.0;
const h_sync_perc = 8.0;
const min_vsync_bp = 550.0; // microseconds

/// Compute GTF timing
pub fn compute(options: Options) Timing {
    const c_prime = ((options.c - options.j) * options.k / 256.0) + options.j;
    const m_prime = options.k / 256.0 * options.m;
    
    const h_pixels_rnd = @round(@as(f64, @floatFromInt(options.h_pixels)) / cell_gran) * cell_gran;
    const v_lines_rnd: f64 = if (options.interlaced)
        @round(@as(f64, @floatFromInt(options.v_lines)) / 2.0)
    else
        @as(f64, @floatFromInt(options.v_lines));
    
    const h_margin = if (options.margins)
        @round(h_pixels_rnd * margin_perc / 100.0 / cell_gran) * cell_gran
    else
        0.0;
    
    const v_margin = if (options.margins)
        @round(margin_perc / 100.0 * v_lines_rnd)
    else
        0.0;
    
    const interlace: f64 = if (options.interlaced) 0.5 else 0.0;
    const total_active_pixels = h_pixels_rnd + h_margin * 2.0;
    
    var v_sync_bp: f64 = undefined;
    var h_blank_pixels: f64 = undefined;
    var total_pixels: f64 = undefined;
    var pixel_freq: f64 = undefined;
    var total_v_lines: f64 = undefined;
    
    switch (options.ip_param) {
        .v_frame_rate => {
            const v_field_rate_rqd = if (options.interlaced)
                options.ip_freq * 2.0
            else
                options.ip_freq;
            
            const h_period_est = (1.0 / v_field_rate_rqd - min_vsync_bp / 1_000_000.0) /
                (v_lines_rnd + v_margin * 2.0 + min_porch + interlace) * 1_000_000.0;
            
            v_sync_bp = @round(min_vsync_bp / h_period_est);
            total_v_lines = v_lines_rnd + v_margin * 2.0 + v_sync_bp + interlace + min_porch;
            
            const v_field_rate_est = 1.0 / h_period_est / total_v_lines * 1_000_000.0;
            const h_period = h_period_est / (v_field_rate_rqd / v_field_rate_est);
            
            const ideal_duty_cycle = c_prime - m_prime * h_period / 1000.0;
            h_blank_pixels = @round(total_active_pixels * ideal_duty_cycle /
                (100.0 - ideal_duty_cycle) / (2.0 * cell_gran)) * 2.0 * cell_gran;
            
            total_pixels = total_active_pixels + h_blank_pixels;
            pixel_freq = total_pixels / h_period;
        },
        
        .h_freq => {
            const h_freq = options.ip_freq;
            v_sync_bp = @round(min_vsync_bp * h_freq / 1000.0);
            
            const ideal_duty_cycle = c_prime - m_prime / h_freq;
            h_blank_pixels = @round(total_active_pixels * ideal_duty_cycle /
                (100.0 - ideal_duty_cycle) / (2.0 * cell_gran)) * 2.0 * cell_gran;
            
            total_pixels = total_active_pixels + h_blank_pixels;
            pixel_freq = total_pixels * h_freq / 1000.0;
            total_v_lines = v_lines_rnd + v_margin * 2.0 + v_sync_bp + interlace + min_porch;
        },
        
        .pixel_clock => {
            pixel_freq = options.ip_freq;
            
            const ideal_h_period = (c_prime - 100.0 +
                @sqrt((100.0 - c_prime) * (100.0 - c_prime) +
                0.4 * m_prime * (total_active_pixels + h_margin * 2.0) / pixel_freq)) /
                2.0 / m_prime * 1000.0;
            
            const ideal_duty_cycle = c_prime - m_prime * ideal_h_period / 1000.0;
            h_blank_pixels = @round(total_active_pixels * ideal_duty_cycle /
                (100.0 - ideal_duty_cycle) / (2.0 * cell_gran)) * 2.0 * cell_gran;
            
            total_pixels = total_active_pixels + h_blank_pixels;
            const h_freq_hz = pixel_freq / total_pixels * 1_000_000.0;
            v_sync_bp = @round(min_vsync_bp * h_freq_hz / 1000.0);
            total_v_lines = v_lines_rnd + v_margin * 2.0 + v_sync_bp + interlace + min_porch;
        },
    }
    
    const h_sync = @round(total_pixels * h_sync_perc / 100.0 / cell_gran) * cell_gran;
    const h_front_porch = (h_blank_pixels / 2.0) - h_sync;
    const v_back_porch = v_sync_bp - v_sync_rqd;
    
    const h_freq_khz = 1000.0 * pixel_freq / total_pixels;
    const v_freq_hz = h_freq_khz * 1000.0 / total_v_lines;
    
    return Timing{
        .pixel_clock_mhz = pixel_freq,
        .h_active = @intFromFloat(h_pixels_rnd - h_margin * 2.0),
        .h_front_porch = @intFromFloat(h_front_porch),
        .h_sync = @intFromFloat(h_sync),
        .h_back_porch = @intFromFloat(h_blank_pixels - h_front_porch - h_sync),
        .h_total = @intFromFloat(total_pixels),
        .v_active = @intFromFloat(v_lines_rnd),
        .v_front_porch = @intFromFloat(min_porch),
        .v_sync = @intFromFloat(v_sync_rqd),
        .v_back_porch = @intFromFloat(v_back_porch),
        .v_total = @intFromFloat(total_v_lines),
        .h_freq_khz = h_freq_khz,
        .v_freq_hz = v_freq_hz,
    };
}

// Tests

test "GTF compute 1024x768 @ 60Hz" {
    const options = Options{
        .h_pixels = 1024,
        .v_lines = 768,
        .ip_param = .v_frame_rate,
        .ip_freq = 60.0,
    };
    
    const timing = compute(options);
    
    try testing.expectEqual(@as(u32, 1024), timing.h_active);
    try testing.expectEqual(@as(u32, 768), timing.v_active);
    try testing.expect(timing.v_freq_hz > 59.5 and timing.v_freq_hz < 60.5);
    try testing.expect(timing.pixel_clock_mhz > 60.0 and timing.pixel_clock_mhz < 70.0);
}

test "GTF compute 1920x1080 @ 75Hz" {
    const options = Options{
        .h_pixels = 1920,
        .v_lines = 1080,
        .ip_param = .v_frame_rate,
        .ip_freq = 75.0,
    };
    
    const timing = compute(options);
    
    try testing.expectEqual(@as(u32, 1920), timing.h_active);
    try testing.expectEqual(@as(u32, 1080), timing.v_active);
    try testing.expect(timing.v_freq_hz > 74.5 and timing.v_freq_hz < 75.5);
}
