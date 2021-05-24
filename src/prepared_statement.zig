const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const ResultSet = @import("result_set.zig").ResultSet;
const FetchResult = @import("result_set.zig").FetchResult;

const EraseComptime = @import("util.zig").EraseComptime;
const sql_parameter = @import("parameter.zig");
const ParameterBucket = sql_parameter.ParameterBucket;

/// A prepared statement is created by submitting a SQL statement prior to execution. This allows the statement
/// to be executed multiple times without having to re-prepare the query.
pub const PreparedStatement = struct {
    statement: odbc.Statement,
    num_params: usize,

    // Should pull out the param storing logic into it's own struct,
    // that way the same thing can be used in isolation later when I add executeDirect()
    // and need to store parameters in a more temporary way
    // param_data: std.ArrayListUnmanaged(u8),
    // param_indicators: []c_longlong,
    parameters: ParameterBucket,

    allocator: *Allocator,

    pub fn init(allocator: *Allocator, statement: odbc.Statement, num_params: usize) !PreparedStatement {
        return PreparedStatement{ 
            .statement = statement, 
            .num_params = num_params, 
            // .param_data = try std.ArrayListUnmanaged(u8).initCapacity(allocator, num_params * 8), 
            // .param_indicators = try allocator.alloc(c_longlong, num_params), 
            .parameters = try ParameterBucket.init(allocator, num_params),
            .allocator = allocator 
        };
    }

    /// Free allocated memory, close any open cursors, and deinitialize the statement. The underlying statement
    /// will become invalidated after calling this function.
    pub fn deinit(self: *PreparedStatement) void {
        // self.param_data.deinit(self.allocator);
        // self.allocator.free(self.param_indicators);
        self.parameters.deinit();
        self.close() catch |_| {};
        self.statement.deinit() catch |_| {};
    }

    pub fn execute(self: *PreparedStatement) !void {
        _ = try self.statement.execute();
    }

    /// Execute the current statement, binding the result columns to the fields of the type `Result`.
    /// Returns a ResultSet from which each row can be retrieved.
    pub fn fetch(self: *PreparedStatement, comptime Result: type) !ResultSet(Result) {
        const RowType = FetchResult(Result);

        try self.execute();

        return try ResultSet(Result).init(self.allocator, self.statement);
        // return result_set;
    }

    /// Bind a value to a parameter index on the current statement. Parameter indices start at `1`.
    pub fn addParam(self: *PreparedStatement, index: usize, param: anytype) !void {
        if (index > self.num_params) return error.InvalidParamIndex;

        const stored_param = try self.parameters.addParameter(index - 1, param);
        const sql_param = sql_parameter.default(param);

        try self.statement.bindParameter(
            @intCast(u16, index), 
            .Input, 
            sql_param.c_type, 
            sql_param.sql_type, 
            stored_param.param, 
            sql_param.precision, 
            stored_param.indicator,
        );
    }

    pub fn addParams(self: *PreparedStatement, params: anytype) !void {
        inline for (params) |p| try self.addParam(p[0], p[1]);
    }

    /// Close any open cursor on this statement. If no cursor is open, do nothing.
    pub fn close(self: *PreparedStatement) !void {
        self.statement.closeCursor() catch |err| {
            var error_buf: [@sizeOf(odbc.Error.SqlState) * 2]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(error_buf[0..]);
            var errors = try self.statement.getErrors(&fba.allocator);
            for (errors) |e| {
                // InvalidCursorState just means that no cursor was open on the statement. Here, we just want to
                // ignore this error and pretend everything succeeded.
                if (e == .InvalidCursorState) return;
            }
            return err;
        };
    }
};
