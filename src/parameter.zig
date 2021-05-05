const std = @import("std");
const odbc = @import("odbc");

const EraseComptime = @import("util.zig").EraseComptime;

pub fn SqlParameter(comptime T: type) type {
    return struct {
        sql_type: odbc.Types.SqlType,
        c_type: odbc.Types.CType,
        precision: ?u16 = null, // Only for numeric types, not sure the best way to model this
        value: T,
    };
}

pub fn default(value: anytype) SqlParameter(EraseComptime(@TypeOf(value))) {
    const T = EraseComptime(@TypeOf(value));
    
    var result = SqlParameter(T){
        .value = value,
        .sql_type = comptime odbc.Types.SqlType.fromType(T) orelse @compileError("Cannot get default SqlType for type " ++ @typeName(T)),
        .c_type = comptime odbc.Types.CType.fromType(T) orelse @compileError("Cannot get default CType for type " ++ @typeName(T)),
    };

    if (std.meta.trait.isFloat(@TypeOf(value))) {
        result.precision = 6;
    }

    return result;
}