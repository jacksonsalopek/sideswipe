//! OS-level utilities for file operations and system interactions

pub const file = @import("file.zig");
pub const process = @import("process.zig");

// Re-export commonly used types and functions
pub const readFileAsString = file.readFileAsString;
pub const readFileAsStringWithLimit = file.readFileAsStringWithLimit;
pub const FileError = file.FileError;
pub const FileDescriptor = file.FileDescriptor;
pub const Process = process.Process;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("file.zig");
    _ = @import("process.zig");
}
