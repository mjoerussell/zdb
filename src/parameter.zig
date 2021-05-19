const std = @import("std");
const Allocator = std.mem.Allocator;
const odbc = @import("odbc");

const EraseComptime = @import("util.zig").EraseComptime;

/// This struct contains the information necessary to communicate with the ODBC driver
/// about the type of a value. `sql_type` is often used to tell the driver how to convert
/// the value into one that SQL will understand, whereas `c_type` is generally used so that
/// the driver has a way to convert a `*c_void` or `[]u8` into a value.
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
    data: std.ArrayListUnmanaged(u8),
    indicators: []c_longlong,

    allocator: *Allocator,

    pub fn init(allocator: *Allocator, num_params: usize) !ParameterBucket {
        return ParameterBucket{
            .allocator = allocator,
            .data = try std.ArrayListUnmanaged(u8).initCapacity(allocator, num_params * 8),
            .indicators = try allocator.alloc(c_longlong, num_params)
        };
    }

    pub fn deinit(self: *ParameterBucket) void {
        self.data.deinit(self.allocator);
        self.allocator.free(indicators);
    }

    pub fn addParameter(self: *ParameterBucket, index: usize, param: anytype) !*EraseComptime(@TypeOf(param)) {
        const ParamType = EraseComptime(@TypeOf(param));
        const param_index = self.data.items.len;
        if (comptime std.meta.trait.isZigString(ParamType)) {
            try self.data.appendSlice(self.allocator, param);
            self.indicators[index] = @intCast(c_longlong, param.len);
        } else {
            try self.data.appendSlice(self.allocator, std.mem.toBytes(@as(ParamType, param))[0..]);
            self.indicators[index] = @sizeOf(ParamType);
        }
        
        return @ptrCast(*ParamType, &self.data.items[param_index]);
    }
};

test "SqlParameter defaults" {
    const a = default(10);

    std.testing.expect(a.precision == null);
    std.testing.expect(a.value == 10);
    std.testing.expect(@TypeOf(a.value) == i64);
    std.testing.expect(a.c_type == .SBigInt);
    std.testing.expect(a.sql_type == .Integer);
}

test "SqlParameter string" {
    const param = default("some string");

    std.testing.expect(param.precision == null);
    std.testing.expect(param.value == "some string");
    std.testing.expect(@TypeOf(param.value) == [11:0] u8);
    std.testing.expect(param.c_type == .Char);
    std.testing.expect(param.sql_type == .Char);
}

