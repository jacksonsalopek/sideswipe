//! CTA-861 VIC timing database
//! Auto-generated from libdisplay-info cta-vic-table.c

const std = @import("std");

pub const AspectRatio = enum {
    @"4:3",
    @"16:9",
    @"64:27",
    @"256:135",
};

pub const Timing = struct {
    vic: u8,
    h_active: u16,
    v_active: u16,
    interlaced: bool,
    pixel_clock_hz: u64,
    h_front: u16,
    h_sync: u16,
    h_back: u16,
    v_front: u16,
    v_sync: u16,
    v_back: u16,
    aspect_ratio: AspectRatio,
};

const entries = [_]Timing{
    // VIC 1: 640x480p
    .{ .vic = 1, .h_active = 640, .v_active = 480, .interlaced = false, .pixel_clock_hz = 25175000, .h_front = 16, .h_sync = 96, .h_back = 48, .v_front = 10, .v_sync = 2, .v_back = 33, .aspect_ratio = .@"4:3" },
    // VIC 2: 720x480p
    .{ .vic = 2, .h_active = 720, .v_active = 480, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"4:3" },
    // VIC 3: 720x480p
    .{ .vic = 3, .h_active = 720, .v_active = 480, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"16:9" },
    // VIC 4: 1280x720p
    .{ .vic = 4, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 110, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 5: 1920x1080i
    .{ .vic = 5, .h_active = 1920, .v_active = 1080, .interlaced = true, .pixel_clock_hz = 74250000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 2, .v_sync = 5, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 6: 1440x480i
    .{ .vic = 6, .h_active = 1440, .v_active = 480, .interlaced = true, .pixel_clock_hz = 27000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"4:3" },
    // VIC 7: 1440x480i
    .{ .vic = 7, .h_active = 1440, .v_active = 480, .interlaced = true, .pixel_clock_hz = 27000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 8: 1440x240p
    .{ .vic = 8, .h_active = 1440, .v_active = 240, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"4:3" },
    // VIC 9: 1440x240p
    .{ .vic = 9, .h_active = 1440, .v_active = 240, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 10: 2880x480i
    .{ .vic = 10, .h_active = 2880, .v_active = 480, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 76, .h_sync = 248, .h_back = 228, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"4:3" },
    // VIC 11: 2880x480i
    .{ .vic = 11, .h_active = 2880, .v_active = 480, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 76, .h_sync = 248, .h_back = 228, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 12: 2880x240p
    .{ .vic = 12, .h_active = 2880, .v_active = 240, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 76, .h_sync = 248, .h_back = 228, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"4:3" },
    // VIC 13: 2880x240p
    .{ .vic = 13, .h_active = 2880, .v_active = 240, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 76, .h_sync = 248, .h_back = 228, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 14: 1440x480p
    .{ .vic = 14, .h_active = 1440, .v_active = 480, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 32, .h_sync = 124, .h_back = 120, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"4:3" },
    // VIC 15: 1440x480p
    .{ .vic = 15, .h_active = 1440, .v_active = 480, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 32, .h_sync = 124, .h_back = 120, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"16:9" },
    // VIC 16: 1920x1080p
    .{ .vic = 16, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 17: 720x576p
    .{ .vic = 17, .h_active = 720, .v_active = 576, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"4:3" },
    // VIC 18: 720x576p
    .{ .vic = 18, .h_active = 720, .v_active = 576, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"16:9" },
    // VIC 19: 1280x720p
    .{ .vic = 19, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 440, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 20: 1920x1080i
    .{ .vic = 20, .h_active = 1920, .v_active = 1080, .interlaced = true, .pixel_clock_hz = 74250000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 2, .v_sync = 5, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 21: 1440x576i
    .{ .vic = 21, .h_active = 1440, .v_active = 576, .interlaced = true, .pixel_clock_hz = 27000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"4:3" },
    // VIC 22: 1440x576i
    .{ .vic = 22, .h_active = 1440, .v_active = 576, .interlaced = true, .pixel_clock_hz = 27000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"16:9" },
    // VIC 23: 1440x288p
    .{ .vic = 23, .h_active = 1440, .v_active = 288, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"4:3" },
    // VIC 24: 1440x288p
    .{ .vic = 24, .h_active = 1440, .v_active = 288, .interlaced = false, .pixel_clock_hz = 27000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"16:9" },
    // VIC 25: 2880x576i
    .{ .vic = 25, .h_active = 2880, .v_active = 576, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 48, .h_sync = 252, .h_back = 276, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"4:3" },
    // VIC 26: 2880x576i
    .{ .vic = 26, .h_active = 2880, .v_active = 576, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 48, .h_sync = 252, .h_back = 276, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"16:9" },
    // VIC 27: 2880x288p
    .{ .vic = 27, .h_active = 2880, .v_active = 288, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 48, .h_sync = 252, .h_back = 276, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"4:3" },
    // VIC 28: 2880x288p
    .{ .vic = 28, .h_active = 2880, .v_active = 288, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 48, .h_sync = 252, .h_back = 276, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"16:9" },
    // VIC 29: 1440x576p
    .{ .vic = 29, .h_active = 1440, .v_active = 576, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 24, .h_sync = 128, .h_back = 136, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"4:3" },
    // VIC 30: 1440x576p
    .{ .vic = 30, .h_active = 1440, .v_active = 576, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 24, .h_sync = 128, .h_back = 136, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"16:9" },
    // VIC 31: 1920x1080p
    .{ .vic = 31, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 32: 1920x1080p
    .{ .vic = 32, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 638, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 33: 1920x1080p
    .{ .vic = 33, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 34: 1920x1080p
    .{ .vic = 34, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 35: 2880x480p
    .{ .vic = 35, .h_active = 2880, .v_active = 480, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 64, .h_sync = 248, .h_back = 240, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"4:3" },
    // VIC 36: 2880x480p
    .{ .vic = 36, .h_active = 2880, .v_active = 480, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 64, .h_sync = 248, .h_back = 240, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"16:9" },
    // VIC 37: 2880x576p
    .{ .vic = 37, .h_active = 2880, .v_active = 576, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 48, .h_sync = 256, .h_back = 272, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"4:3" },
    // VIC 38: 2880x576p
    .{ .vic = 38, .h_active = 2880, .v_active = 576, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 48, .h_sync = 256, .h_back = 272, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"16:9" },
    // VIC 39: 1920x1080i
    .{ .vic = 39, .h_active = 1920, .v_active = 1080, .interlaced = true, .pixel_clock_hz = 72000000, .h_front = 32, .h_sync = 168, .h_back = 184, .v_front = 23, .v_sync = 5, .v_back = 57, .aspect_ratio = .@"16:9" },
    // VIC 40: 1920x1080i
    .{ .vic = 40, .h_active = 1920, .v_active = 1080, .interlaced = true, .pixel_clock_hz = 148500000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 2, .v_sync = 5, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 41: 1280x720p
    .{ .vic = 41, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 440, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 42: 720x576p
    .{ .vic = 42, .h_active = 720, .v_active = 576, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"4:3" },
    // VIC 43: 720x576p
    .{ .vic = 43, .h_active = 720, .v_active = 576, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"16:9" },
    // VIC 44: 1440x576i
    .{ .vic = 44, .h_active = 1440, .v_active = 576, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"4:3" },
    // VIC 45: 1440x576i
    .{ .vic = 45, .h_active = 1440, .v_active = 576, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"16:9" },
    // VIC 46: 1920x1080i
    .{ .vic = 46, .h_active = 1920, .v_active = 1080, .interlaced = true, .pixel_clock_hz = 148500000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 2, .v_sync = 5, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 47: 1280x720p
    .{ .vic = 47, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 110, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 48: 720x480p
    .{ .vic = 48, .h_active = 720, .v_active = 480, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"4:3" },
    // VIC 49: 720x480p
    .{ .vic = 49, .h_active = 720, .v_active = 480, .interlaced = false, .pixel_clock_hz = 54000000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"16:9" },
    // VIC 50: 1440x480i
    .{ .vic = 50, .h_active = 1440, .v_active = 480, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"4:3" },
    // VIC 51: 1440x480i
    .{ .vic = 51, .h_active = 1440, .v_active = 480, .interlaced = true, .pixel_clock_hz = 54000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 52: 720x576p
    .{ .vic = 52, .h_active = 720, .v_active = 576, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"4:3" },
    // VIC 53: 720x576p
    .{ .vic = 53, .h_active = 720, .v_active = 576, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .aspect_ratio = .@"16:9" },
    // VIC 54: 1440x576i
    .{ .vic = 54, .h_active = 1440, .v_active = 576, .interlaced = true, .pixel_clock_hz = 108000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"4:3" },
    // VIC 55: 1440x576i
    .{ .vic = 55, .h_active = 1440, .v_active = 576, .interlaced = true, .pixel_clock_hz = 108000000, .h_front = 24, .h_sync = 126, .h_back = 138, .v_front = 2, .v_sync = 3, .v_back = 19, .aspect_ratio = .@"16:9" },
    // VIC 56: 720x480p
    .{ .vic = 56, .h_active = 720, .v_active = 480, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"4:3" },
    // VIC 57: 720x480p
    .{ .vic = 57, .h_active = 720, .v_active = 480, .interlaced = false, .pixel_clock_hz = 108000000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .aspect_ratio = .@"16:9" },
    // VIC 58: 1440x480i
    .{ .vic = 58, .h_active = 1440, .v_active = 480, .interlaced = true, .pixel_clock_hz = 108000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"4:3" },
    // VIC 59: 1440x480i
    .{ .vic = 59, .h_active = 1440, .v_active = 480, .interlaced = true, .pixel_clock_hz = 108000000, .h_front = 38, .h_sync = 124, .h_back = 114, .v_front = 4, .v_sync = 3, .v_back = 15, .aspect_ratio = .@"16:9" },
    // VIC 60: 1280x720p
    .{ .vic = 60, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 59400000, .h_front = 1760, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 61: 1280x720p
    .{ .vic = 61, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 2420, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 62: 1280x720p
    .{ .vic = 62, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 1760, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 63: 1920x1080p
    .{ .vic = 63, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 64: 1920x1080p
    .{ .vic = 64, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 65: 1280x720p
    .{ .vic = 65, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 59400000, .h_front = 1760, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 66: 1280x720p
    .{ .vic = 66, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 2420, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 67: 1280x720p
    .{ .vic = 67, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 1760, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 68: 1280x720p
    .{ .vic = 68, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 440, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 69: 1280x720p
    .{ .vic = 69, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 110, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 70: 1280x720p
    .{ .vic = 70, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 440, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 71: 1280x720p
    .{ .vic = 71, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 110, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 72: 1920x1080p
    .{ .vic = 72, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 638, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 73: 1920x1080p
    .{ .vic = 73, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 74: 1920x1080p
    .{ .vic = 74, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 74250000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 75: 1920x1080p
    .{ .vic = 75, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 76: 1920x1080p
    .{ .vic = 76, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 77: 1920x1080p
    .{ .vic = 77, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 78: 1920x1080p
    .{ .vic = 78, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 79: 1680x720p
    .{ .vic = 79, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 59400000, .h_front = 1360, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 80: 1680x720p
    .{ .vic = 80, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 59400000, .h_front = 1228, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 81: 1680x720p
    .{ .vic = 81, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 59400000, .h_front = 700, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 82: 1680x720p
    .{ .vic = 82, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 82500000, .h_front = 260, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 83: 1680x720p
    .{ .vic = 83, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 99000000, .h_front = 260, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 84: 1680x720p
    .{ .vic = 84, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 165000000, .h_front = 60, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 95, .aspect_ratio = .@"64:27" },
    // VIC 85: 1680x720p
    .{ .vic = 85, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 198000000, .h_front = 60, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 95, .aspect_ratio = .@"64:27" },
    // VIC 86: 2560x1080p
    .{ .vic = 86, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 99000000, .h_front = 998, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 11, .aspect_ratio = .@"64:27" },
    // VIC 87: 2560x1080p
    .{ .vic = 87, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 90000000, .h_front = 448, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 88: 2560x1080p
    .{ .vic = 88, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 118800000, .h_front = 768, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 89: 2560x1080p
    .{ .vic = 89, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 185625000, .h_front = 548, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 90: 2560x1080p
    .{ .vic = 90, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 198000000, .h_front = 248, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 11, .aspect_ratio = .@"64:27" },
    // VIC 91: 2560x1080p
    .{ .vic = 91, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 371250000, .h_front = 218, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 161, .aspect_ratio = .@"64:27" },
    // VIC 92: 2560x1080p
    .{ .vic = 92, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 495000000, .h_front = 548, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 161, .aspect_ratio = .@"64:27" },
    // VIC 93: 3840x2160p
    .{ .vic = 93, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 1276, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 94: 3840x2160p
    .{ .vic = 94, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 95: 3840x2160p
    .{ .vic = 95, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 96: 3840x2160p
    .{ .vic = 96, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 97: 3840x2160p
    .{ .vic = 97, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 98: 4096x2160p
    .{ .vic = 98, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 1020, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
    // VIC 99: 4096x2160p
    .{ .vic = 99, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 968, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
    // VIC 100: 4096x2160p
    .{ .vic = 100, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 88, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
    // VIC 101: 4096x2160p
    .{ .vic = 101, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 968, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
    // VIC 102: 4096x2160p
    .{ .vic = 102, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 88, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
    // VIC 103: 3840x2160p
    .{ .vic = 103, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 1276, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 104: 3840x2160p
    .{ .vic = 104, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 105: 3840x2160p
    .{ .vic = 105, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 297000000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 106: 3840x2160p
    .{ .vic = 106, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 107: 3840x2160p
    .{ .vic = 107, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 108: 1280x720p
    .{ .vic = 108, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 90000000, .h_front = 960, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"16:9" },
    // VIC 109: 1280x720p
    .{ .vic = 109, .h_active = 1280, .v_active = 720, .interlaced = false, .pixel_clock_hz = 90000000, .h_front = 960, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 110: 1680x720p
    .{ .vic = 110, .h_active = 1680, .v_active = 720, .interlaced = false, .pixel_clock_hz = 99000000, .h_front = 810, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .aspect_ratio = .@"64:27" },
    // VIC 111: 1920x1080p
    .{ .vic = 111, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 638, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"16:9" },
    // VIC 112: 1920x1080p
    .{ .vic = 112, .h_active = 1920, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 148500000, .h_front = 638, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .aspect_ratio = .@"64:27" },
    // VIC 113: 2560x1080p
    .{ .vic = 113, .h_active = 2560, .v_active = 1080, .interlaced = false, .pixel_clock_hz = 198000000, .h_front = 998, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 11, .aspect_ratio = .@"64:27" },
    // VIC 114: 3840x2160p
    .{ .vic = 114, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 1276, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 115: 4096x2160p
    .{ .vic = 115, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 1020, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
    // VIC 116: 3840x2160p
    .{ .vic = 116, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 594000000, .h_front = 1276, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 117: 3840x2160p
    .{ .vic = 117, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 118: 3840x2160p
    .{ .vic = 118, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"16:9" },
    // VIC 119: 3840x2160p
    .{ .vic = 119, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 120: 3840x2160p
    .{ .vic = 120, .h_active = 3840, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 121: 5120x2160p
    .{ .vic = 121, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 396000000, .h_front = 1996, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 22, .aspect_ratio = .@"64:27" },
    // VIC 122: 5120x2160p
    .{ .vic = 122, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 396000000, .h_front = 1696, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 22, .aspect_ratio = .@"64:27" },
    // VIC 123: 5120x2160p
    .{ .vic = 123, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 396000000, .h_front = 664, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 22, .aspect_ratio = .@"64:27" },
    // VIC 124: 5120x2160p
    .{ .vic = 124, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 742500000, .h_front = 746, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 297, .aspect_ratio = .@"64:27" },
    // VIC 125: 5120x2160p
    .{ .vic = 125, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 742500000, .h_front = 1096, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 126: 5120x2160p
    .{ .vic = 126, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 742500000, .h_front = 164, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 127: 5120x2160p
    .{ .vic = 127, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1485000000, .h_front = 1096, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 193: 5120x2160p
    .{ .vic = 193, .h_active = 5120, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1485000000, .h_front = 164, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"64:27" },
    // VIC 194: 7680x4320p
    .{ .vic = 194, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 2552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"16:9" },
    // VIC 195: 7680x4320p
    .{ .vic = 195, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 2352, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"16:9" },
    // VIC 196: 7680x4320p
    .{ .vic = 196, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"16:9" },
    // VIC 197: 7680x4320p
    .{ .vic = 197, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2376000000, .h_front = 2552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"16:9" },
    // VIC 198: 7680x4320p
    .{ .vic = 198, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2376000000, .h_front = 2352, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"16:9" },
    // VIC 199: 7680x4320p
    .{ .vic = 199, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2376000000, .h_front = 552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"16:9" },
    // VIC 200: 7680x4320p
    .{ .vic = 200, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 4752000000, .h_front = 2112, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"16:9" },
    // VIC 201: 7680x4320p
    .{ .vic = 201, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 4752000000, .h_front = 352, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"16:9" },
    // VIC 202: 7680x4320p
    .{ .vic = 202, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 2552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 203: 7680x4320p
    .{ .vic = 203, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 2352, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"64:27" },
    // VIC 204: 7680x4320p
    .{ .vic = 204, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"64:27" },
    // VIC 205: 7680x4320p
    .{ .vic = 205, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2376000000, .h_front = 2552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 206: 7680x4320p
    .{ .vic = 206, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2376000000, .h_front = 2352, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"64:27" },
    // VIC 207: 7680x4320p
    .{ .vic = 207, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2376000000, .h_front = 552, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"64:27" },
    // VIC 208: 7680x4320p
    .{ .vic = 208, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 4752000000, .h_front = 2112, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 209: 7680x4320p
    .{ .vic = 209, .h_active = 7680, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 4752000000, .h_front = 352, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 210: 10240x4320p
    .{ .vic = 210, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1485000000, .h_front = 1492, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 594, .aspect_ratio = .@"64:27" },
    // VIC 211: 10240x4320p
    .{ .vic = 211, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1485000000, .h_front = 2492, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"64:27" },
    // VIC 212: 10240x4320p
    .{ .vic = 212, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 1485000000, .h_front = 288, .h_sync = 176, .h_back = 296, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 213: 10240x4320p
    .{ .vic = 213, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2970000000, .h_front = 1492, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 594, .aspect_ratio = .@"64:27" },
    // VIC 214: 10240x4320p
    .{ .vic = 214, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2970000000, .h_front = 2492, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 44, .aspect_ratio = .@"64:27" },
    // VIC 215: 10240x4320p
    .{ .vic = 215, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 2970000000, .h_front = 288, .h_sync = 176, .h_back = 296, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 216: 10240x4320p
    .{ .vic = 216, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 5940000000, .h_front = 2192, .h_sync = 176, .h_back = 592, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 217: 10240x4320p
    .{ .vic = 217, .h_active = 10240, .v_active = 4320, .interlaced = false, .pixel_clock_hz = 5940000000, .h_front = 288, .h_sync = 176, .h_back = 296, .v_front = 16, .v_sync = 20, .v_back = 144, .aspect_ratio = .@"64:27" },
    // VIC 218: 4096x2160p
    .{ .vic = 218, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 800, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
    // VIC 219: 4096x2160p
    .{ .vic = 219, .h_active = 4096, .v_active = 2160, .interlaced = false, .pixel_clock_hz = 1188000000, .h_front = 88, .h_sync = 88, .h_back = 128, .v_front = 8, .v_sync = 10, .v_back = 72, .aspect_ratio = .@"256:135" },
};

/// Lookup VIC timing by code (O(log n) binary search)
pub fn lookup(vic: u8) ?Timing {
    if (vic == 0) return null;
    
    // Binary search
    var left: usize = 0;
    var right: usize = entries.len;
    
    while (left < right) {
        const mid = left + (right - left) / 2;
        const entry_vic = entries[mid].vic;
        
        if (entry_vic == vic) {
            return entries[mid];
        } else if (entry_vic < vic) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    
    return null;
}

/// Get common VIC name
pub fn getCommonName(vic: u8) ?[]const u8 {
    return switch (vic) {
        1 => "640x480p60",
        4 => "1280x720p60",
        16 => "1920x1080p60",
        31 => "1920x1080p50",
        93 => "3840x2160p24",
        95 => "3840x2160p30",
        97 => "3840x2160p60",
        else => null,
    };
}
