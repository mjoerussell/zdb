const std = @import("std");

pub fn EraseComptime(comptime T: type) type {
    return switch (T) {
        comptime_int => i64,
        comptime_float => f64,
        else => T
    };
}

pub fn sliceToValue(comptime T: type, slice: []u8) callconv(.Inline) T {
    const ptr = @ptrCast(*const [@sizeOf(T)]u8, slice[0..@sizeOf(T)]);
    return std.mem.bytesToValue(T, ptr);
}