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
    pub const Param = struct {
        param: *c_void,
        indicator: *c_longlong,
    };

    // data: std.ArrayListAlignedUnmanaged(u8, null),
    data: std.ArrayListAlignedUnmanaged(u8, null),
    param_indices: std.ArrayListUnmanaged(usize),
    indicators: []c_longlong,

    allocator: *Allocator,

    pub fn init(allocator: *Allocator, num_params: usize) !ParameterBucket {
        return ParameterBucket{
            .allocator = allocator,
            // .data = try std.ArrayListAlignedUnmanaged(u8, null).initCapacity(allocator, num_params * 8),
            .data = try std.ArrayListAlignedUnmanaged(u8, null).initCapacity(allocator, num_params * 8),
            .param_indices = try std.ArrayListUnmanaged(usize).initCapacity(allocator, num_params),
            .indicators = try allocator.alloc(c_longlong, num_params)
        };
    }

    pub fn deinit(self: *ParameterBucket) void {
        // for (self.data.items) |ptr| self.allocator.destroy(ptr);
        self.data.deinit(self.allocator);
        self.param_indices.deinit(self.allocator);
        self.allocator.free(self.indicators);
    }

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
        
        // const param_ptr = @ptrCast(*ParamType, @alignCast(@alignOf(ParamType), &self.data.items[param_index]));

        return Param{
            .param = @ptrCast(*c_void, &self.data.items[param_index]),
            .indicator = &self.indicators[index]
        };
    }

    // pub fn addParameter(self: *ParameterBucket, index: usize, param: anytype) !Param(@TypeOf(param)) {
    //     const ParamType = EraseComptime(@TypeOf(param));

    //     const param_index = self.data.items.len;
    //     var param_ptr = try self.allocator.create(ParamType);
    //     param_ptr.* = param;

    //     try self.data.append(self.allocator, @ptrCast(*c_void, param_ptr));
        
    //     self.indicators[index] = if (comptime std.meta.trait.isZigString(ParamType)) @intCast(c_longlong, param.len) else @sizeOf(ParamType);
    //     // if (comptime std.meta.trait.isZigString(ParamType)) {
            
    //     //     // try self.data.appendSlice(self.allocator, param);
    //     //     self.indicators[index] = @intCast(c_longlong, param.len);
    //     // } else {
    //     //     // try self.data.appendSlice(self.allocator, std.mem.toBytes(@as(ParamType, param))[0..]);
    //     //     self.indicators[index] = @sizeOf(ParamType);
    //     // }
        
    //     // const param_ptr = @ptrCast(*ParamType, @alignCast(@alignOf(ParamType), &self.data.items[param_index]));

    //     return Param(@TypeOf(param)){
    //         .param = param_ptr,
    //         .index = param_index,
    //     };
    // }
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

