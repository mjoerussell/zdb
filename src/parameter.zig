const std = @import("std");
const Allocator = std.mem.Allocator;
const odbc = @import("odbc");

const EraseComptime = @import("util.zig").EraseComptime;

/// This struct contains the information necessary to communicate with the ODBC driver
/// about the type of a value. `sql_type` is often used to tell the driver how to convert
/// the value into one that SQL will understand, whereas `c_type` is generally used so that
/// the driver has a way to convert a `*anyopaque` or `[]u8` into a value.
pub fn SqlParameter(comptime T: type) type {
    return struct {
        sql_type: odbc.Types.SqlType,
        c_type: odbc.Types.CType,
        precision: ?u16 = null, // Only for numeric types, not sure the best way to model this
        value: T,
    };
}

/// Get the default SqlType and CType equivalents for an arbitrary value. If the value is a float,
/// precision will be defaulted to `6`. If the value is a `comptime_int` or `comptime_float`, then
/// it will be converted here to `i64` or `f64`, respectively.
pub fn default(value: anytype) SqlParameter(EraseComptime(@TypeOf(value))) {
    const ValueType = EraseComptime(@TypeOf(value));
    
    var result = SqlParameter(ValueType){
        .value = value,
        .sql_type = comptime odbc.Types.SqlType.fromType(ValueType) orelse @compileError("Cannot get default SqlType for type " ++ @typeName(ValueType)),
        .c_type = comptime odbc.Types.CType.fromType(ValueType) orelse @compileError("Cannot get default CType for type " ++ @typeName(ValueType)),
    };

    if (std.meta.trait.isFloat(@TypeOf(value))) {
        result.precision = 6;
    }

    return result;
}

pub const ParameterBucket = struct {
    pub const Param = struct {
        param: *anyopaque,
        indicator: *c_longlong,
    };

    data: std.ArrayListAlignedUnmanaged(u8, null),
    param_indices: std.ArrayListUnmanaged(usize),
    indicators: []c_longlong,

    allocator: Allocator,

    pub fn init(allocator: Allocator, num_params: usize) !ParameterBucket {
        return ParameterBucket{
            .allocator = allocator,
            .data = try std.ArrayListAlignedUnmanaged(u8, null).initCapacity(allocator, num_params * 8),
            .param_indices = try std.ArrayListUnmanaged(usize).initCapacity(allocator, num_params),
            .indicators = try allocator.alloc(c_longlong, num_params)
        };
    }

    pub fn deinit(self: *ParameterBucket) void {
        self.data.deinit(self.allocator);
        self.param_indices.deinit(self.allocator);
        self.allocator.free(self.indicators);
    }

    /// Insert a parameter into the bucker at the given index. Old parameter data at the
    /// old index won't be overwritten, but old indicator values will be overwritten.
    pub fn addParameter(self: *ParameterBucket, index: usize, param: anytype) !Param {
        const ParamType = EraseComptime(@TypeOf(param));

        const param_index = self.data.items.len;
        try self.param_indices.append(self.allocator, param_index);

        if (comptime std.meta.trait.isZigString(ParamType)) {
            try self.data.appendSlice(self.allocator, param);
            self.indicators[index] = @intCast(c_longlong, param.len);
        } else {
            try self.data.appendSlice(self.allocator, std.mem.toBytes(@as(ParamType, param))[0..]);
            self.indicators[index] = @sizeOf(ParamType);
        }
        
        return Param{
            .param = @ptrCast(*anyopaque, &self.data.items[param_index]),
            .indicator = &self.indicators[index]
        };
    }
};

test "SqlParameter defaults" {
    const SqlType = odbc.Types.SqlType;
    const CType = odbc.Types.CType;
    const a = default(10);

    try std.testing.expect(a.precision == null);
    try std.testing.expect(a.value == 10);
    try std.testing.expectEqual(i64, @TypeOf(a.value));
    try std.testing.expectEqual(CType.SBigInt, a.c_type);
    try std.testing.expectEqual(SqlType.BigInt, a.sql_type);
}

test "SqlParameter string" {
    const SqlType = odbc.Types.SqlType;
    const CType = odbc.Types.CType;
    const param = default("some string");

    try std.testing.expect(param.precision == null);
    try std.testing.expectEqualStrings("some string", param.value);
    try std.testing.expectEqual(*const [11:0] u8, @TypeOf(param.value));
    try std.testing.expectEqual(CType.Char, param.c_type);
    try std.testing.expectEqual(SqlType.Varchar, param.sql_type);
}

test "add parameter to ParameterBucket" {
    const allocator = std.testing.allocator;

    var bucket = try ParameterBucket.init(allocator, 5);
    defer bucket.deinit();

    var param_value: u32 = 10;

    const param = try bucket.addParameter(0, param_value);

    const param_data = @ptrCast([*]u8, param.param)[0..@intCast(usize, param.indicator.*)];
    try std.testing.expectEqualSlices(u8, std.mem.toBytes(param_value)[0..], param_data);
}

test "add string parameter to ParameterBucket" {
    const allocator = std.testing.allocator;

    var bucket = try ParameterBucket.init(allocator, 5);
    defer bucket.deinit();

    var param_value = "some string value";

    const param = try bucket.addParameter(0, param_value);

    const param_data = @ptrCast([*]u8, param.param)[0..@intCast(usize, param.indicator.*)];
    try std.testing.expectEqualStrings(param_value, param_data);
}

