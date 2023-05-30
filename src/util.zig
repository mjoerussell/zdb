const std = @import("std");

/// Convert `comptime_int` and `comptime_float` to `i64` and `f64`, respectively.
/// For any other type, this is a no-op.
pub fn EraseComptime(comptime T: type) type {
    return switch (T) {
        comptime_int => i64,
        comptime_float => f64,
        else => T,
    };
}

/// Helper function to convert a slice of bytes to a value of type `T`.
/// Internally calls `std.mem.bytesToValue`.
pub inline fn sliceToValue(comptime T: type, slice: []u8) T {
    switch (@typeInfo(T)) {
        .Int => |info| {
            if (slice.len == 1) {
                return @intCast(T, slice[0]);
            } else if (slice.len < 4) {
                if (info.signedness == .unsigned) {
                    const int = std.mem.bytesToValue(u16, slice[0..2]);
                    return @intCast(T, int);
                } else {
                    const int = std.mem.bytesToValue(i16, slice[0..2]);
                    return @intCast(T, int);
                }
            } else if (slice.len < 8) {
                if (info.signedness == .unsigned) {
                    const int = std.mem.bytesToValue(u32, slice[0..4]);
                    return @intCast(T, int);
                } else {
                    const int = std.mem.bytesToValue(i32, slice[0..4]);
                    return @intCast(T, int);
                }
            } else {
                if (info.signedness == .unsigned) {
                    const int = std.mem.bytesToValue(u64, slice[0..8]);
                    return @intCast(T, int);
                } else {
                    const int = std.mem.bytesToValue(i64, slice[0..8]);
                    return @intCast(T, int);
                }
            }
        },
        .Float => {
            if (slice.len >= 4 and slice.len < 8) {
                const float = std.mem.bytesToValue(f32, slice[0..4]);
                return @floatCast(T, float);
            } else {
                const float = std.mem.bytesToValue(f64, slice[0..8]);
                return @floatCast(T, float);
            }
        },
        .Struct => {
            var struct_bytes = [_]u8{0} ** @sizeOf(T);
            const slice_end_index = if (@sizeOf(T) >= slice.len) slice.len else @sizeOf(T);
            std.mem.copy(u8, struct_bytes[0..], slice[0..slice_end_index]);
            return std.mem.bytesToValue(T, &struct_bytes);
        },
        else => {
            std.debug.assert(slice.len >= @sizeOf(T));
            const ptr = @ptrCast(*const [@sizeOf(T)]u8, slice[0..@sizeOf(T)]);
            return std.mem.bytesToValue(T, ptr);
        },
    }
}
