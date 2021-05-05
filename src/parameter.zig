const std = @import("std");
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
        .sql_type = comptime odbc.Types.SqlType.fromType(ValueType) orelse @compileError("Cannot get default SqlType for type " ++ @typeName(T)),
        .c_type = comptime odbc.Types.CType.fromType(ValueType) orelse @compileError("Cannot get default CType for type " ++ @typeName(T)),
    };

    if (std.meta.trait.isFloat(@TypeOf(value))) {
        result.precision = 6;
    }

    return result;
}

