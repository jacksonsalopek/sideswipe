# DisplayID v1/v2 Implementation

Complete implementation of VESA DisplayID v1.x and v2.x standards for Zig.

## Overview

DisplayID is a modern display identification standard designed to replace and extend EDID. It provides more flexible and extensible display capability descriptions using a modular data block structure.

## Features

### Supported Standards
- ✅ DisplayID v1.3 (released June 2013)
- ✅ DisplayID v2.0/v2.1 (released September 2017)

### Implemented Data Blocks

#### Product Information
- **Product Identification** (v1: 0x00, v2: 0x20)
  - Vendor ID (3-character PNP code)
  - Product code and serial number
  - Model year and optional model string

- **Display Parameters** (v1: 0x01, v2: 0x21)
  - Physical dimensions (mm)
  - Native resolution
  - Feature flags (audio, power management, fixed timing, etc.)

#### Timing Information

**DisplayID v1.x Timing Types:**
- **Type I** - Detailed Timing (20 bytes)
  - Complete timing parameters similar to EDID DTD
  - Pixel clock, active/blank periods, sync timing
  - Stereo viewing support, polarity flags
  
- **Type II** - Detailed Timing (11 bytes)
  - Compressed format for common timings
  - Resolution, aspect ratio, refresh rate
  
- **Type III** - Short Timing Descriptor (3 bytes)
  - References CVT/GTF timing formulas
  - Minimal storage for calculated timings
  
- **Type IV** - DMT Timing Code (1 byte)
  - References VESA DMT standard timing IDs

**DisplayID v2.x Timing Types:**
- **Type VII** - Detailed Timing (20 bytes)
  - Enhanced Type I format for v2
  
- **Type VIII** - Enumerated Timing Code (1 byte)
  - Enhanced Type IV format for v2
  
- **Type IX** - Formula-Based Timing (9 bytes)
  - New detailed formula-based timing
  - High-precision refresh rates (0.001 Hz units)
  
- **Type X** - Dynamic Video Timing Range (11 bytes)
  - Defines supported timing ranges
  - Min/max pixel clock and resolution

## Usage

### Basic Parsing

```zig
const std = @import("std");
const displayid = @import("core.display").displayid;

// Parse DisplayID section from EDID extension or standalone data
const section = displayid.Section.parse(data) orelse return error.InvalidDisplayID;

// Check version
const is_v2 = section.isV2();
std.debug.print("DisplayID version: {}\n", .{@intFromEnum(section.getVersion())});

// Iterate through data blocks
var iter = section.blocks();
while (iter.next()) |block| {
    if (block.isProductId(is_v2)) {
        if (block.asProductId()) |product| {
            std.debug.print("Vendor: {s}\n", .{product.vendor});
            std.debug.print("Product: 0x{X}\n", .{product.product_code});
        }
    }
}
```

### Parsing Timing Blocks

```zig
// Type I Detailed Timing (v1) or Type VII (v2)
if (displayid.timing.TypeITiming.parse(data)) |timing| {
    std.debug.print("{}x{}@{d}.{d:0>3}Hz\n", .{
        timing.h_active,
        timing.v_active,
        timing.getRefreshRate() / 1000,
        timing.getRefreshRate() % 1000,
    });
    std.debug.print("Pixel clock: {} MHz\n", .{timing.pixel_clock_hz / 1_000_000});
    std.debug.print("Preferred: {}\n", .{timing.preferred});
}

// Type III Short Timing (CVT/GTF)
if (displayid.timing.TypeIIITiming.parse(data)) |timing| {
    std.debug.print("Formula: {s}\n", .{@tagName(timing.formula)});
    std.debug.print("{}x{}@{}Hz\n", .{
        timing.h_active,
        timing.v_active,
        timing.refresh_rate_hz,
    });
}

// Type X Timing Range (v2)
if (displayid.timing.TypeXTiming.parse(data)) |range| {
    const supported = range.supports(1920, 1080, 148_500_000);
    std.debug.print("1920x1080@148.5MHz supported: {}\n", .{supported});
}
```

## Module Structure

```
displayid/
├── root.zig          - Core structures (Section, DataBlock, headers)
├── timing.zig        - All timing type parsers (Type I-IV, VII-X)
├── product.zig       - Product identification parsing
├── params.zig        - Display parameters parsing
├── example.zig       - Complete usage example
└── README.md         - This file
```

## Standards Reference

### DisplayID v1.3
- Product Identification (0x00)
- Display Parameters (0x01)
- Color Characteristics (0x02)
- Type I Detailed Timing (0x03)
- Type II Detailed Timing (0x04)
- Type III Short Timing (0x05)
- Type IV DMT Timing (0x06)

### DisplayID v2.0/v2.1
- Product Identification (0x20)
- Display Parameters (0x21)
- Type VII Detailed Timing (0x22)
- Type VIII Enumerated Timing (0x23)
- Type IX Formula-Based Timing (0x24)
- Dynamic Video Timing Range (0x25)
- Interface Features (0x26)
- Stereo Display Interface (0x27)
- Tiled Display (0x28)
- Container ID (0x29)

## Design Principles

### Zero-Copy Parsing
All parsers operate directly on input buffers without copying data. The `Section` and `DataBlock` structures hold slices into the original data.

### Type Safety
- Enums for version detection, data block tags, timing formulas
- Packed structs for binary data layouts
- Explicit alignment annotations where needed

### Error Handling
- Returns `?T` (optional) for parsing functions
- No undefined behavior on malformed data
- Validates lengths before accessing data

### Testing
All functionality is thoroughly tested:
- Section and header parsing
- Data block iteration
- All timing type parsers
- Edge cases and boundary conditions

Run tests:
```bash
zig build test
```

## Implementation Status

| Feature | Status | Notes |
|---------|--------|-------|
| Section parsing | ✅ | v1 and v2 |
| Data block iteration | ✅ | Full validation |
| Product ID | ✅ | v1 and v2 |
| Display params | ✅ | v1 format |
| Type I timing | ✅ | Detailed 20-byte |
| Type II timing | ✅ | Compressed 11-byte |
| Type III timing | ✅ | CVT/GTF formulas |
| Type IV timing | ✅ | DMT codes |
| Type VII timing | ✅ | v2 detailed |
| Type VIII timing | ✅ | v2 enumerated |
| Type IX timing | ✅ | v2 formula-based |
| Type X timing | ✅ | v2 range limits |
| Color characteristics | ⏳ | Not yet implemented |
| Interface features | ⏳ | Not yet implemented |
| Stereo interface | ⏳ | Not yet implemented |
| Tiled display | ⏳ | Not yet implemented |
| Container ID | ⏳ | Not yet implemented |

## Implementation Notes

### Validation Against libdisplay-info

This implementation has been validated against the upstream libdisplay-info C library to ensure correctness:

- **Timing Value Encoding**: All timing values (active, blank, sync width/offset) use the formula `1 + raw_value` as per the DisplayID specification
- **Pixel Clock Units**: 
  - Type I (v1): `(1 + raw) * 0.01 MHz = 10 kHz` units
  - Type VII (v2): `(1 + raw) * 0.001 MHz = 1 kHz` units
- **Byte 3 Layout** (Type I/VII):
  - Bit 7: Preferred timing flag
  - Bits 6-5: Stereo 3D support (2 bits)
  - Bit 4: Interlaced flag
  - Bits 3-0: Aspect ratio (8 standard ratios)
- **Sync Polarity**: Stored in bit 7 of the offset bytes (byte 9 for H, byte 17 for V)

### Differences from Earlier Specifications

Some earlier DisplayID documentation may show different bit layouts. This implementation follows the validated libdisplay-info behavior which matches VESA DisplayID v1.3 and v2.0/2.1 standards.

## References

- [VESA DisplayID Standard](https://vesa.org/vesa-standards/)
- [DisplayID v2.0 Announcement](https://vesa.org/featured-articles/vesa-rolls-out-displayid-version-2-0-standard/)
- [libdisplay-info](https://gitlab.freedesktop.org/emersion/libdisplay-info) - Reference C implementation (validated against)

## Example Output

See `example.zig` for a complete working example:

```bash
zig run src/core/display/displayid/example.zig -I src
```

Output:
```
DisplayID v1/v2 Parsing Example
================================

DisplayID Version: 32
Is v2: true
Section length: 30 bytes

Data Block #1
  Tag: 0x20
  Revision: 0
  Payload length: 12 bytes
  Type: Product Identification
    Vendor: ABC
    Product code: 0x0001
    Serial: 0x12345678
    Model year: 2023

Data Block #2
  Tag: 0x21
  Revision: 0
  Payload length: 12 bytes
  Type: Display Parameters
    Size: 600mm x 340mm
    Resolution: 1920x1080
    Audio support: true
    Power management: true
    Fixed timing: false

Timing Examples
===============

Type I Timing (Detailed):
  1920x1080@60.000Hz
  Pixel clock: 148.50 MHz
  Preferred: true
  Interlaced: false
```
