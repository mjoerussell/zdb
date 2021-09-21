const std = @import("std");

/// Convert `comptime_int` and `comptime_float` to `i64` and `f64`, respectively.
/// For any other type, this is a no-op.
pub fn EraseComptime(comptime T: type) type {
    return switch (T) {
        comptime_int => i64,
        comptime_float => f64,
        else => T
    };
}

/// Helper function to convert a slice of bytes to a value of type `T`.
/// Internally calls `std.mem.bytesToValue`.
pub inline fn sliceToValue(comptime T: type, slice: []u8) T {
    std.debug.assert(slice.len >= @sizeOf(T));
    const ptr = @ptrCast(*const [@sizeOf(T)]u8, slice[0..@sizeOf(T)]);
    return std.mem.bytesToValue(T, ptr);
}