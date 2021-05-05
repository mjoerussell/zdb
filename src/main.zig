const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");
const sql_parameter = @import("parameter.zig");
const SqlParameter = sql_parameter.SqlParameter;

const EraseComptime = @import("util.zig").EraseComptime;

fn FetchResult(comptime Target: type) type {
    const TypeInfo = std.builtin.TypeInfo;

    const TargetInfo = @typeInfo(Target);

    switch (TargetInfo) {
        .Struct => {
            const R = extern struct{};
            var ResultInfo = @typeInfo(R);

            var result_fields: [TargetInfo.Struct.fields.len * 2]TypeInfo.StructField = undefined;
            inline for (TargetInfo.Struct.fields) |field, i| {
                result_fields[i * 2] = field;
                switch (@typeInfo(field.field_type)) {
                    .Pointer => |info| {
                        if (info.size == .Slice) {
                            // If the base type is a slice, the corresponding FetchResult type should be an array
                            result_fields[i * 2].field_type = [200]info.child;
                            result_fields[i * 2].default_value = null;
                            // std.debug.print("Changed type of field \"{s}\" to {s}\n", .{field.name, @typeName(result_fields[i * 2].field_type)});
                        }
                    },
                    else => {}
                }
                // result_fields[i * 2] = field;
                result_fields[(i * 2) + 1] = TypeInfo.StructField{
                    .name = field.name ++ "_len_or_ind",
                    .field_type = c_longlong,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(c_longlong)
                };
            }

            ResultInfo.Struct.fields = result_fields[0..];

            return @Type(ResultInfo);
        },
        else => @compileError("The base type of FetchResult must be a struct, found " ++ @typeName(Target))
    }
}

pub fn ResultSet(comptime Base: type) type {
    return struct {
        const Self = @This();
        const RowStatus = odbc.Types.StatementAttributeValue.RowStatus;

        rows_fetched: usize = 0,
        rows: []FetchResult(Base),
        row_status: []RowStatus,

        current_row: usize = 0,

        statement: *odbc.Statement,
        allocator: *Allocator,

        pub fn init(statement: *odbc.Statement, allocator: *Allocator) !Self {
            var result = Self{
                .statement = statement,
                .allocator = allocator,
                .rows = try allocator.alloc(FetchResult(Base), 10),
                .row_status = try allocator.alloc(RowStatus, 10)
            };

            // inline for (std.meta.fields(FetchResult(Base))) |field| {
            //     std.debug.print("Field: {s}: {s}\n", .{field.name, @typeName(field.field_type)});
            // }

            return result;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.rows);
            self.allocator.free(self.row_status);
        }

        pub fn next(self: *Self) !?Base {
            if (self.current_row >= self.rows_fetched) {
                // Because of the param binding in PreparedStatement.fetch, this will update self.rows_fetched
                // @todo async - Handle error.StillExecuting here
                self.statement.fetch() catch |_| return null;
                self.current_row = 0;
            }

            if (self.current_row < self.rows_fetched) {
                // Iterate until you find the next row that returned Success or SuccessWithInfo. Should generally be the original current row
                while (self.current_row < self.rows_fetched and self.row_status[self.current_row] != .Success and self.row_status[self.current_row] != .SuccessWithInfo) {
                    self.current_row += 1;
                }

                if (self.current_row >= self.rows_fetched) return null;

                const item_row = self.rows[self.current_row];
                var item: Base = undefined;
                
                inline for (std.meta.fields(Base)) |field, index| {
                    const len_or_indicator = @field(item_row, field.name ++ "_len_or_ind");
                    if (len_or_indicator != odbc.sys.SQL_NULL_DATA) {
                        switch (@typeInfo(field.field_type)) {
                            .Array => {
                                if (len_or_indicator == odbc.sys.SQL_NTS) {
                                    const index_of_null_terminator = std.mem.indexOf(u8, @field(item_row, field.name)[0..], &.{ 0x00 }) orelse @field(item_row, field.name).len;
                                    @field(item, field.name) = @field(item_row, field.name)[0..index_of_null_terminator];
                                } else {
                                    @field(item, field.name) = @field(item_row, field.name);
                                }
                            },
                            .Pointer => |info| {
                                switch (info.size) {
                                    .Slice => {
                                        // std.debug.print("Slice len for row {s} is {}\n", .{field.name, @field(item_row, field.name).len});
                                        if (len_or_indicator == odbc.sys.SQL_NTS) {
                                            const index_of_null_terminator = std.mem.indexOf(u8, @field(item_row, field.name)[0..], &.{ 0x00 }) orelse @field(item_row, field.name).len;
                                            var data_slice = try self.allocator.alloc(info.child, @intCast(usize, index_of_null_terminator));
                                            std.mem.copy(info.child, data_slice, @field(item_row, field.name)[0..@intCast(usize, index_of_null_terminator)]);
                                            @field(item, field.name) = data_slice;
                                        } else {
                                            var data_slice = try self.allocator.alloc(info.child, @intCast(usize, len_or_indicator));
                                            std.mem.copy(info.child, data_slice, @field(item_row, field.name)[0..@intCast(usize, len_or_indicator)]);
                                            @field(item, field.name) = data_slice;
                                        }
                                    },
                                    else => {}
                                }
                            },
                            else => @field(item, field.name) = @field(item_row, field.name)
                        }
                    }

                }

                self.current_row += 1;
                return item;
            }

            return null;
        }

    };
}

pub const PreparedStatement = struct {
    statement: odbc.Statement,
    num_params: usize,
    param_data: std.ArrayListUnmanaged(u8),
    param_indicators: []c_longlong,

    allocator: *Allocator,

    pub fn init(allocator: *Allocator, statement: odbc.Statement, num_params: usize) !PreparedStatement {
        return PreparedStatement{
            .statement = statement,
            .num_params = num_params,
            .param_data = try std.ArrayListUnmanaged(u8).initCapacity(allocator, num_params * 8),
            .param_indicators = try allocator.alloc(c_longlong, num_params),
            .allocator = allocator
        };
    }

    pub fn deinit(self: *PreparedStatement) void {
        self.param_data.deinit(self.allocator);
        self.allocator.free(self.param_indicators);
        self.close() catch |_| {};
        self.statement.deinit() catch |_| {};
    }

    pub fn fetch(self: *PreparedStatement, comptime Result: type) !ResultSet(Result) {
        const RowType = FetchResult(Result);

        var result_set = try ResultSet(Result).init(&self.statement, self.allocator);
        errdefer result_set.deinit();

        try self.statement.setAttribute(.{ .RowBindType = @sizeOf(RowType) });
        try self.statement.setAttribute(.{ .RowArraySize = 10 });
        try self.statement.setAttribute(.{ .RowStatusPointer = result_set.row_status });
        try self.statement.setAttribute(.{ .RowsFetchedPointer = &result_set.rows_fetched });
        
        var column_number: u16 = 1;
        inline for (std.meta.fields(RowType)) |field| {
            comptime if (std.mem.endsWith(u8, field.name, "_len_or_ind")) continue;

            const c_type = comptime blk: {
                if (odbc.Types.CType.fromType(field.field_type)) |c_type| {
                    break :blk c_type;
                } else {
                    @compileError("CType could not be derived for " ++ @typeName(Result) ++ "." ++ field.name ++ " (" ++ @typeName(field.field_type) ++ ")");
                }
            };

            const FieldTypeInfo = @typeInfo(field.field_type);
            const FieldDataType = switch (FieldTypeInfo) {
                .Pointer => FieldTypeInfo.Pointer.child,
                .Array => FieldTypeInfo.Array.child,
                else => field.field_type
            };

            const value_ptr: []FieldDataType = switch (FieldTypeInfo) {
                .Pointer => switch (FieldTypeInfo.Pointer.size) {
                    .One => @ptrCast([*]FieldDataType, @field(result_set.rows[0], field.name))[0..1],
                    else => @field(result_set.rows[0], field.name)[0..]
                },
                .Array => @field(result_set.rows[0], field.name)[0..],
                else => @ptrCast([*]FieldDataType, &@field(result_set.rows[0], field.name))[0..1]
            };
            
            try self.statement.bindColumn(
                column_number, 
                c_type, 
                value_ptr,
                &@field(result_set.rows[0], field.name ++ "_len_or_ind")
            );
            
            column_number += 1;
        }

        const execute_result = self.statement.execute() catch |err| {
            var error_buf: [@sizeOf(odbc.Error.SqlState) * 3]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(error_buf[0..]);
            const errors = self.statement.getErrors(&fba.allocator) catch |_| return err;
            for (errors) |e| {
                std.debug.print("Execute Error: {s}\n", .{@tagName(e)});
            }

            return err;
        };

        self.statement.fetch() catch |err| switch (err) {
            error.StillExecuting => {},
            error.NoData => {},
            else => {
                var error_buf: [@sizeOf(odbc.Error.SqlState) * 3]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(error_buf[0..]);
                const errors = self.statement.getErrors(&fba.allocator) catch |_| return err;
                for (errors) |e| {
                    std.debug.print("Fetch Error: {s}\n", .{@tagName(e)});
                }

                return err;
            }
        };

        return result_set;
    }

    pub fn addParam(self: *PreparedStatement, index: usize, param: anytype) !void {
        if (index >= self.num_params) return error.InvalidParamIndex;

        const param_index = self.param_data.items.len;
        try self.param_data.appendSlice(self.allocator, std.mem.toBytes(@as(EraseComptime(@TypeOf(param)), param))[0..]);
        
        const param_ptr = &self.param_data.items[param_index];
        const sql_param = sql_parameter.default(param);

        self.param_indicators[index] = @sizeOf(EraseComptime(@TypeOf(param)));

        try self.statement.bindParameter(
            @intCast(u16, index + 1),
            .Input,
            sql_param.c_type,
            sql_param.sql_type,
            @ptrCast(*c_void, param_ptr),
            sql_param.precision,
            &self.param_indicators[index]
        );
    }

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

pub const DBConnection = struct {
    environment: odbc.Environment,
    connection: odbc.Connection,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator, connection_string: []const u8) !DBConnection {
        var result: DBConnection = undefined;
        result.environment = odbc.Environment.init(allocator) catch |_| return error.EnvironmentError;
        result.environment.setOdbcVersion(.Odbc3) catch |_| return error.EnvironmentError;
        
        result.connection = odbc.Connection.init(allocator, &result.environment) catch |_| return error.ConnectionError;
        try result.connection.connectExtended(connection_string, .NoPrompt);

        result.allocator = allocator;

        return result;
    }

    pub fn deinit(self: *DBConnection) void {
        self.connection.deinit() catch |_| {};
        self.environment.deinit() catch |_| {};
    }

    pub fn prepareStatement(self: *DBConnection, comptime sql_statement: []const u8) !PreparedStatement {
        const num_params: usize = comptime blk: {
            var count: usize = 0;
            inline for (sql_statement) |c| {
                if (c == '?') count += 1;
            }
            break :blk count;
        };

        var statement = odbc.Statement.init(&self.connection, self.allocator) catch |stmt_err| {
            var error_buf: [@sizeOf(odbc.Error.SqlState) * 3]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(error_buf[0..]);

            const errors = try self.connection.getErrors(&fba.allocator);

            for (errors) |e| {
                std.debug.print("Statement init error: {s}\n", .{@tagName(e)});
            }
            return error.StatementError;
        };

        try statement.prepare(sql_statement);

        return try PreparedStatement.init(self.allocator, statement, num_params);
    }
};

const OdbcTestType = struct {
    id: u8,
    name: []u8,
    occupation: []u8,
    age: u32,

    fn deinit(self: *OdbcTestType, allocator: *Allocator) void {
        allocator.free(self.name);
        allocator.free(self.occupation);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var connection = try DBConnection.init(allocator, "ODBC;driver=PostgreSQL Unicode(x64);DSN=PostgreSQL35W");
    defer connection.deinit();

    var prepared_statement = try connection.prepareStatement("SELECT * FROM odbc_zig_test WHERE age >= ?");
    defer prepared_statement.deinit();

    try prepared_statement.addParam(0, 30);

    var result_set = try prepared_statement.fetch(OdbcTestType);
    defer result_set.deinit();

    std.debug.print("Rows fetched: {}\n", .{result_set.rows_fetched});

    while (try result_set.next()) |result| {
        std.debug.print("Id: {}\n", .{result.id});
        std.debug.print("Name: {s}\n", .{result.name});
        std.debug.print("Occupation: {s}\n", .{result.occupation});
        std.debug.print("Age: {}\n", .{result.age});
    }

}
