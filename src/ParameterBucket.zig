const std = @import("std");
const Allocator = std.mem.Allocator;
const odbc = @import("odbc");

const EraseComptime = @import("util.zig").EraseComptime;

const ParameterBucket = @This();

/// This struct contains the information necessary to communicate with the ODBC driver
/// about the type of a value. `sql_type` is often used to tell the driver how to convert
/// the value into one that SQL will understand, whereas `c_type` is generally used so that
/// the driver has a way to convert a `*anyopaque` or `[]u8` into a value.
pub const SqlParameter = struct {
    sql_type: odbc.Types.SqlType,
    c_type: odbc.Types.CType,
    precision: ?u16 = null, // Only for numeric types, not sure the best way to model this

    /// Get the default SqlType and CType equivalents for an arbitrary value. If the value is a float,
    /// precision will be defaulted to `6`. If the value is a `comptime_int` or `comptime_float`, then
    /// it will be converted here to `i64` or `f64`, respectively.
    pub fn default(value: anytype) SqlParameter {
        const ValueType = EraseComptime(@TypeOf(value));

        return SqlParameter{
            .sql_type = comptime odbc.Types.SqlType.fromType(ValueType) orelse @compileError("Cannot get default SqlType for type " ++ @typeName(ValueType)),
            .c_type = comptime odbc.Types.CType.fromType(ValueType) orelse @compileError("Cannot get default CType for type " ++ @typeName(ValueType)),
            .precision = if (std.meta.trait.isFloat(@TypeOf(value))) 6 else null,
        };
    }
};

// @todo I think that it's actually going to be beneficial to return to the original design of ParameterBucket which used a []u8 to hold
//       all of the param data. That idea wasn't the problem, the problem is that I didn't work hard enough to build a system that can properly
//       realloc/move data when the user wants to replace values.
//
//       This design actually has a big disadvantage which is that every parameter that gets set needs to be separately allocated in order to produce
//       a *anyopaque to store in Param. With the []u8 approach, extra space will need to be reallocated much more rarely since the data will be stored
//       in the same persistent buffer.
pub const Param = struct {
    data: *anyopaque,
    indicator: *c_longlong,
};

data: []u8,
indicators: []c_longlong,

pub fn init(allocator: Allocator, num_params: usize) !ParameterBucket {
    var indicators = try allocator.alloc(c_longlong, num_params);
    errdefer allocator.free(indicators);

    for (indicators) |*i| i.* = 0;

    return ParameterBucket{
        .data = try allocator.alloc(u8, num_params * 8),
        .indicators = indicators,
    };
}

pub fn deinit(bucket: *ParameterBucket, allocator: Allocator) void {
    allocator.free(bucket.data);
    allocator.free(bucket.indicators);
}

pub fn reset(bucket: *ParameterBucket, allocator: Allocator, new_param_count: usize) !void {
    if (new_param_count > bucket.indicators.len) {
        bucket.indicators = try allocator.realloc(bucket.indicators, new_param_count);
        bucket.data = try allocator.realloc(bucket.data, new_param_count * 8);
    }

    for (bucket.indicators) |*i| i.* = 0;
    for (bucket.data) |*d| d.* = 0;
}

pub fn set(bucket: *ParameterBucket, allocator: Allocator, param_data: anytype, param_index: usize) !Param {
    const ParamType = EraseComptime(@TypeOf(param_data));

    var data_index: usize = 0;
    for (bucket.indicators[0..param_index]) |indicator| {
        data_index += @intCast(usize, indicator);
    }

    const data_indicator = @intCast(usize, bucket.indicators[param_index]);

    const data_buffer: []const u8 = if (comptime std.meta.trait.isZigString(ParamType))
        param_data
    else
        &std.mem.toBytes(@as(ParamType, param_data));

    bucket.indicators[param_index] = @intCast(c_longlong, data_buffer.len);

    if (data_buffer.len != data_indicator) {
        // If the new len is not the same as the old one, then some adjustments have to be made to the rest of
        // the params
        var remaining_param_size: usize = 0;
        for (bucket.indicators[param_index..]) |ind| {
            remaining_param_size += @intCast(usize, ind);
        }

        const original_data_end_index = data_index + data_indicator;
        const new_data_end_index = data_index + data_buffer.len;

        const copy_dest = bucket.data[new_data_end_index..];
        const copy_src = bucket.data[original_data_end_index .. original_data_end_index + remaining_param_size];

        if (data_buffer.len < data_indicator) {
            // If the new len is smaller than the old one, then just move the remaining params
            // forward
            std.mem.copy(u8, copy_dest, copy_src);
        } else {
            // If the new len is bigger than the old one, then resize the buffer and then move the
            // remaining params backwards
            const size_increase = data_buffer.len - data_indicator;
            bucket.data = try allocator.realloc(bucket.data, bucket.data.len + size_increase);

            std.mem.copyBackwards(u8, copy_dest, copy_src);
        }
    }

    std.mem.copy(u8, bucket.data[data_index..], data_buffer);

    return Param{
        .data = @ptrCast(*anyopaque, &bucket.data[data_index]),
        .indicator = &bucket.indicators[param_index],
    };
}

test "SqlParameter defaults" {
    const SqlType = odbc.Types.SqlType;
    const CType = odbc.Types.CType;
    const a = SqlParameter.default(10);

    try std.testing.expect(a.precision == null);
    try std.testing.expectEqual(CType.SBigInt, a.c_type);
    try std.testing.expectEqual(SqlType.BigInt, a.sql_type);
}

test "SqlParameter string" {
    const SqlType = odbc.Types.SqlType;
    const CType = odbc.Types.CType;
    const param = SqlParameter.default("some string");

    try std.testing.expect(param.precision == null);
    try std.testing.expectEqual(CType.Char, param.c_type);
    try std.testing.expectEqual(SqlType.Varchar, param.sql_type);
}

test "add parameter to ParameterBucket" {
    const allocator = std.testing.allocator;

    var bucket = try ParameterBucket.init(allocator, 5);
    defer bucket.deinit(allocator);

    var param_value: u32 = 10;

    const param = try bucket.set(allocator, param_value, 0);

    const param_data = @ptrCast([*]u8, param.data)[0..@intCast(usize, param.indicator.*)];
    try std.testing.expectEqualSlices(u8, std.mem.toBytes(param_value)[0..], param_data);
}

test "add string parameter to ParameterBucket" {
    const allocator = std.testing.allocator;

    var bucket = try ParameterBucket.init(allocator, 5);
    defer bucket.deinit(allocator);

    var param_value = "some string value";

    const param = try bucket.set(allocator, param_value, 0);

    const param_data = @ptrCast([*]u8, param.data)[0..@intCast(usize, param.indicator.*)];
    try std.testing.expectEqualStrings(param_value, param_data);
}
