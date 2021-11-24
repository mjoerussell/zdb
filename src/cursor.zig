const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");
const Statement = odbc.Statement;
const Connection = odbc.Connection;

const sql_parameter = @import("parameter.zig");
const ParameterBucket = sql_parameter.ParameterBucket;

const ResultSet = @import("result_set.zig").ResultSet;

const catalog_types = @import("catalog.zig");
const Column = catalog_types.Column;
const Table = catalog_types.Table;
const TablePrivileges = catalog_types.TablePrivileges;

pub const Cursor = struct {

    parameters: ?ParameterBucket = null,

    connection: Connection,
    statement: Statement,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator, connection: Connection) !Cursor {
        return Cursor{
            .allocator = allocator,
            .connection = connection,
            .statement = try Statement.init(connection),
        };
    }

    pub fn deinit(self: *Cursor) !void {
        try self.close();
        try self.statement.deinit();
        self.clearParameters();
    }

    /// Close the current cursor. If the cursor is not open, does nothing and does not return an error.
    pub fn close(self: *Cursor) !void {
        self.statement.closeCursor() catch |err| {
            var errors = try self.statement.getErrors(self.allocator);
            for (errors) |e| {
                // InvalidCursorState just means that no cursor was open on the statement. Here, we just want to
                // ignore this error and pretend everything succeeded.
                if (e == .InvalidCursorState) return;
            }
            return err;
        };
    }

    /// Execute a SQL statement and return the result set. SQL query parameters can be passed with the `parameters` argument. 
    /// This is the fastest way to execute a SQL statement once.
    pub fn executeDirect(self: *Cursor, comptime ResultType: type, parameters: anytype, sql_statement: []const u8) !ResultSet(ResultType) {
        var num_params: usize = 0;
        for (sql_statement) |c| {
            if (c == '?') num_params += 1;
        }

        if (num_params != parameters.len) return error.InvalidNumParams;

        self.clearParameters();
        self.parameters = try ParameterBucket.init(self.allocator, num_params);
        defer {
            self.parameters.?.deinit();
            self.parameters = null;
        }

        inline for (parameters) |param, index| {
            const stored_param = try self.parameters.?.addParameter(index, param);
            const sql_param = sql_parameter.default(param);
            try self.statement.bindParameter(
                @intCast(u16, index + 1), 
                .Input, 
                sql_param.c_type, 
                sql_param.sql_type, 
                stored_param.param, 
                sql_param.precision, 
                stored_param.indicator,
            );
        }

        _ = try self.statement.executeDirect(sql_statement);

        return try ResultSet(ResultType).init(self.allocator, self.statement, 10);
    }

    /// Execute a statement and return the result set. A statement must have been prepared previously
    /// using `Cursor.prepare()`.
    pub fn execute(self: *Cursor, comptime ResultType: type) !ResultSet(ResultType) {
        _ = try self.statement.execute();
        return try ResultSet(ResultType).init(self.allocator, self.statement, 10);
    }

    /// Prepare a SQL statement for execution. If you want to execute a statement multiple times,
    /// preparing it first is much faster because you only have to compile and load the statement
    /// once on the driver/DBMS. Use `Cursor.execute()` to get the results.
    pub fn prepare(self: *Cursor, parameters: anytype, sql_statement: []const u8) !void {
        try self.bindParameters(parameters);
        try self.statement.prepare(sql_statement);
    }

    // pub fn insert(self: *Cursor, comptime DataType: type, comptime table_name: []const u8, values: []const DataType) !usize {
    pub fn insert(self: *Cursor, comptime DataType: type, comptime insert_statement: []const u8, values: []const DataType) !usize {
        // @todo Try using arrays of parameters for bulk ops
        AssertInsertable(DataType);

        const num_params = blk: {
            comptime var count: usize = 0;
            inline for (insert_statement) |c| {
                if (c == '?') count += 1;
            }
            break :blk count;
        };

        try self.prepare(.{}, insert_statement);
        self.parameters = try ParameterBucket.init(self.allocator, num_params);

        var num_rows_inserted: usize = 0;

        for (values) |value, value_index| {
            switch (@typeInfo(DataType)) {
                .Pointer => |pointer_tag| switch (pointer_tag.size) {
                    .Slice => {
                        if (value.len < num_params) return error.WrongParamCount;
                        for (value) |param, param_index| {
                            try self.bindParameter(param_index + 1, param);
                        }
                    },
                    .One => {
                        if (num_params != 1) return error.WrongParamCount;
                        try self.bindParameter(value_index + 1, value.*);
                    },
                    else => unreachable,
                },
                .Struct => |struct_tag| {
                    comptime if (struct_tag.fields.len != num_params) 
                        @compileError("Struct type " ++ @typeName(DataType) ++ " cannot be inserted as it has the wrong number of fields.");
                    inline for (std.meta.fields(DataType)) |field, param_index| {
                        try self.bindParameter(param_index + 1, @field(value, field.name));
                    }
                },
                .Array => |array_tag| {
                    comptime if (array_tag.len != num_params) @compileError("Array type " ++ @typeName(DataType) ++ " cannot be inserted because it has the wrong length");
                    for (value) |val, param_index| {
                        try self.bindParameter(param_index + 1, val);
                    }
                },
                .Optional => {
                    comptime if (num_params != 1) @compileError("Cannot insert Optional type - statement only has one parameter.");
                    try self.bindParameter(value_index + 1, value);
                },
                .Enum => {
                    comptime if (num_params != 1) @compileError("Cannot insert Enum type - statement only has one parameter.");
                    const enum_value = @enumToInt(value);
                    try self.bindParameter(value_index + 1, enum_value);
                }, 
                .EnumLiteral => {
                    comptime if (num_params != 1) @compileError("Cannot insert EnumLiteral type - statement only has one parameter.");
                    try self.bindParameter(value_index + 1, @tagName(value));
                },
                .Int, .Float, .ComptimeInt, .ComptimeFloat, .Bool => {
                    comptime if (num_params != 1) @compileError("Cannot insert " ++ @typeName(DataType) ++ " type - statement only has one parameter.");
                    try self.bindParameter(value_index + 1, value);
                },
                else => unreachable,
            }

            self.statement.execute() catch |err| {
                std.log.err("{s}", .{ @errorName(err) });
                return err;
            };
            num_rows_inserted += try self.statement.rowCount();
        }

        return num_rows_inserted;
    }

    /// When in manual-commit mode, use this to commit a transaction. **Important!:** This will
    /// commit *all open cursors allocated on this connection*. Be mindful of that before using
    /// this, if in a situation where you are using multiple cursors simultaneously.
    pub fn commit(self: *Cursor) !void {
        try self.connection.endTransaction(.commit);
    }

    /// When in manual-commit mode, use this to rollback a transaction. **Important!:** This will
    /// rollback *all open cursors allocated on this connection*. Be mindful of that before using
    /// this, if in a situation where you are using multiple cursors simultaneously.
    pub fn rollback(self: *Cursor) !void {
        try self.connection.endTransaction(.rollback);
    }

    pub fn columns(self: *Cursor, catalog_name: ?[]const u8, schema_name: ?[]const u8, table_name: []const u8) ![]Column {
        var result_set = try ResultSet(Column).init(self.allocator, self.statement, 10);
        defer result_set.deinit();

        try self.statement.columns(catalog_name, schema_name, table_name, null);

        return try result_set.getAllRows();
    }

    pub fn tables(self: *Cursor, catalog_name: ?[]const u8, schema_name: ?[]const u8) ![]Table {
        var result_set = try ResultSet(Table).init(self.allocator, self.statement, 10);
        defer result_set.deinit();

        try self.statement.tables(catalog_name, schema_name, null, null);

        return try result_set.getAllRows();
    }

    pub fn tablePrivileges(self: *Cursor, catalog_name: ?[]const u8, schema_name: ?[]const u8, table_name: []const u8) ![]TablePrivileges {
        var result_set = try ResultSet(TablePrivileges).init(self.allocator, self.statement, 10);
        defer result_set.deinit();

        try self.statement.tablePrivileges(catalog_name, schema_name, table_name);

        return try result_set.getAllRows();
    }

    /// Bind a single value to a SQL parameter. If `self.parameters` is `null`, this does nothing
    /// and does not return an error. Parameter indices start at 1.
    pub fn bindParameter(self: *Cursor, index: usize, parameter: anytype) !void {
        if (self.parameters) |*params| {
            const stored_param = try params.addParameter(index - 1, parameter);
            const sql_param = sql_parameter.default(parameter);
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
    }

    /// Bind a list of parameters to SQL parameters. The first item in the list will be bound
    /// to the parameter at index 1, the second to index 2, etc. 
    ///
    /// Calling this function clears all existing parameters, and if an empty list is passed in 
    /// will not re-initialize them.
    pub fn bindParameters(self: *Cursor, parameters: anytype) !void {
        self.clearParameters();
        if (parameters.len > 0) {
            self.parameters = try ParameterBucket.init(self.allocator, parameters.len);
        }

        inline for (parameters) |param, index| {
            try self.bindParameter(index + 1, param);
        }
    }
    
    /// Deinitialize any parameters allocated on this statement (if any), and reset `self.parameters` to null.
    fn clearParameters(self: *Cursor) void {
        if (self.parameters) |*p| p.deinit();
        self.parameters = null;
    }

    pub fn getErrors(self: *Cursor) []odbc.Error.DiagnosticRecord {
        return self.statement.getDiagnosticRecords() catch return &[_]odbc.Error.DiagnosticRecord{};
    }

};

/// Assert that the type `T` can be used as an insert parameter. Deeply checks types that have child types when necessary.
fn AssertInsertable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .Frame, .AnyFrame, .Void, .NoReturn, .Undefined, 
        .ErrorUnion, .ErrorSet, .Fn, .BoundFn, .Union,
        .Vector, .Opaque, .Null, .Type => @compileError(@tagName(std.meta.activeTag(@typeInfo(T))) ++ " types cannot be used as insert parameters"),
        .Pointer => |pointer_tag| switch (pointer_tag.size) {
            .Slice, .One => AssertInsertable(pointer_tag.child),
            else => @compileError(@tagName(std.meta.activeTag(pointer_tag.size)) ++ "-type pointers cannot be used as insert parameters"),
        },
        .Array => |array_tag| AssertInsertable(array_tag.child),
        .Optional => |op_tag| AssertInsertable(op_tag.child),
        .Struct => {},
        .Enum, .EnumLiteral => {},
        .Int, .Float, .ComptimeInt, .ComptimeFloat, .Bool => {}
    }
}