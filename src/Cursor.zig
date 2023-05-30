const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");
const Statement = odbc.Statement;
const Connection = odbc.Connection;

const ParameterBucket = @import("ParameterBucket.zig");
const ResultSet = @import("ResultSet.zig");

const catalog_types = @import("catalog.zig");
const Column = catalog_types.Column;
const Table = catalog_types.Table;
const TablePrivileges = catalog_types.TablePrivileges;

const Cursor = @This();

parameters: ParameterBucket,

connection: Connection,
statement: Statement,

pub fn init(allocator: Allocator, connection: Connection) !Cursor {
    return Cursor{
        .connection = connection,
        .statement = try Statement.init(connection),
        .parameters = try ParameterBucket.init(allocator, 10),
    };
}

pub fn deinit(self: *Cursor, allocator: Allocator) !void {
    try self.close();
    try self.statement.deinit();
    self.parameters.deinit(allocator);
}

/// Close the current cursor. If the cursor is not open, does nothing and does not return an error.
pub fn close(self: *Cursor) !void {
    self.statement.closeCursor() catch |err| switch (err) {
        error.InvalidCursorState => return,
        else => return err,
    };
}

/// Execute a SQL statement and return the result set. SQL query parameters can be passed with the `parameters` argument.
/// This is the fastest way to execute a SQL statement once.
pub fn executeDirect(cursor: *Cursor, allocator: Allocator, sql_statement: []const u8, parameters: anytype) !ResultSet {
    var num_params: usize = 0;
    for (sql_statement) |c| {
        if (c == '?') num_params += 1;
    }

    if (num_params != parameters.len) return error.InvalidNumParams;
    try cursor.parameters.reset(allocator, num_params);

    try cursor.bindParameters(allocator, parameters);
    try cursor.statement.executeDirect(sql_statement);

    return ResultSet.init(cursor.statement);
}

/// Execute a statement and return the result set. A statement must have been prepared previously
/// using `Cursor.prepare()`.
pub fn execute(cursor: *Cursor) !ResultSet {
    try cursor.statement.execute();
    return try ResultSet.init(cursor.statement);
}

/// Prepare a SQL statement for execution. If you want to execute a statement multiple times,
/// preparing it first is much faster because you only have to compile and load the statement
/// once on the driver/DBMS. Use `Cursor.execute()` to get the results.
///
/// If you don't want to set the paramters here, that's fine. You can pass `.{}` and use `cursor.bindParameter` or
/// `cursor.bindParameters` later before executing the statement.
pub fn prepare(cursor: *Cursor, allocator: Allocator, sql_statement: []const u8, parameters: anytype) !void {
    try cursor.bindParameters(allocator, parameters);
    try cursor.statement.prepare(sql_statement);
}

/// `insert` is a helper function for inserting data. It will prepare the statement you provide and then
/// execute it once for each value in the `values` array. It's not fundamentally different than this:
///
/// ```zig
/// const values = [_][2]u32{ [_]u32{0, 1}, [_]u32{1, 2}, [_]u32{2, 3}, [_]u32{3, 4}, };
///
/// try cursor.prepare(allocator, "INSERT INTO table VALUES (?, ?)");
/// for (values) |v| {
///    try cursor.bindParameters(allocator, v);
///    try cursor.execute();
/// }
/// ```
///
/// `insert` will do some work to make sure that each value binds in the appropriate way regardless
/// of its type.
///
/// `insert` is named as such because it's intended to be used when inserting data, however there is nothing
/// here requiring you to use this for insert statements. You could use it for other things, like regular
/// SELECT statements. It's important to keep in mind, though, that there will be no way to fetch result
/// sets for any query other than the last.
pub fn insert(cursor: *Cursor, allocator: Allocator, insert_statement: []const u8, values: anytype) !usize {
    // @todo Try using arrays of parameters for bulk ops
    const DataType = switch (@typeInfo(@TypeOf(values))) {
        .Pointer => |info| switch (info.size) {
            .Slice => info.child,
            else => @compileError("values must be a slice or array type"),
        },
        .Array => |info| info.child,
        else => @compileError("values must be a slice or array type"),
    };
    AssertInsertable(DataType);

    const num_params = blk: {
        var count: usize = 0;
        for (insert_statement) |c| {
            if (c == '?') count += 1;
        }
        break :blk count;
    };

    try cursor.parameters.reset(allocator, num_params);
    try cursor.prepare(allocator, insert_statement, .{});

    var num_rows_inserted: usize = 0;

    for (values, 0..) |value, value_index| {
        switch (@typeInfo(DataType)) {
            .Pointer => |pointer_tag| switch (pointer_tag.size) {
                .Slice => {
                    if (value.len < num_params) return error.WrongParamCount;
                    for (value, 0..) |param, param_index| {
                        try cursor.bindParameter(allocator, param_index + 1, param);
                    }
                },
                .One => {
                    if (num_params != 1) return error.WrongParamCount;
                    try cursor.bindParameter(allocator, value_index + 1, value.*);
                },
                else => unreachable,
            },
            .Struct => |struct_tag| {
                if (struct_tag.fields.len != num_params) return error.WrongParamCount;

                inline for (std.meta.fields(DataType), 0..) |field, param_index| {
                    try cursor.bindParameter(allocator, param_index + 1, @field(value, field.name));
                }
            },
            .Array => |array_tag| {
                if (array_tag.len != num_params) return error.WrongParamCount;
                for (value, 0..) |val, param_index| {
                    try cursor.bindParameter(allocator, param_index + 1, val);
                }
            },
            .Optional => {
                if (num_params != 1) return error.WrongParamCount;
                try cursor.bindParameter(allocator, value_index + 1, value);
            },
            .Enum => {
                if (num_params != 1) return error.WrongParamCount;
                const enum_value = @enumToInt(value);
                try cursor.bindParameter(allocator, value_index + 1, enum_value);
            },
            .EnumLiteral => {
                if (num_params != 1) return error.WrongParamCount;
                try cursor.bindParameter(allocator, value_index + 1, @tagName(value));
            },
            .Int, .Float, .ComptimeInt, .ComptimeFloat, .Bool => {
                if (num_params != 1) return error.WrongParamCount;
                try cursor.bindParameter(allocator, value_index + 1, value);
            },
            else => unreachable,
        }

        cursor.statement.execute() catch |err| {
            std.log.err("{s}", .{@errorName(err)});
            return err;
        };
        num_rows_inserted += try cursor.statement.rowCount();
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

pub fn columns(cursor: *Cursor, allocator: Allocator, catalog_name: ?[]const u8, schema_name: ?[]const u8, table_name: []const u8) ![]Column {
    try cursor.statement.columns(catalog_name, schema_name, table_name, null);
    var result_set = ResultSet.init(cursor.statement);

    var column_iter = try result_set.itemIterator(Column, allocator);
    defer column_iter.deinit();

    var column_result = std.ArrayList(Column).init(allocator);
    errdefer column_result.deinit();

    while (true) {
        var result = column_iter.next() catch continue;
        var column = result orelse break;
        try column_result.append(column);
    }

    return column_result.toOwnedSlice();
}

pub fn tables(cursor: *Cursor, allocator: Allocator, catalog_name: ?[]const u8, schema_name: ?[]const u8) ![]Table {
    try cursor.statement.tables(catalog_name, schema_name, null, null);
    var result_set = ResultSet.init(allocator, cursor.statement);

    var table_iter = try result_set.itemIterator(Table);
    defer table_iter.deinit();

    var table_result = std.ArrayList(Table).init(allocator);
    errdefer table_result.deinit();

    while (true) {
        var result = table_iter.next() catch continue;
        var table = result orelse break;
        try table_result.append(table);
    }

    return table_result.toOwnedSlice();
}

pub fn tablePrivileges(cursor: *Cursor, allocator: Allocator, catalog_name: ?[]const u8, schema_name: ?[]const u8, table_name: []const u8) ![]TablePrivileges {
    try cursor.statement.tablePrivileges(catalog_name, schema_name, table_name);
    var result_set = ResultSet.init(cursor.statement);

    var priv_iter = try result_set.itemIterator(TablePrivileges, allocator);
    defer priv_iter.deinit();

    var priv_result = std.ArrayList(TablePrivileges).init(allocator);
    errdefer priv_result.deinit();

    while (true) {
        var result = priv_iter.next() catch continue;
        var privilege = result orelse break;
        try priv_result.append(privilege);
    }

    return priv_result.toOwnedSlice();
}

pub fn catalogs(cursor: *Cursor, allocator: Allocator) ![][]const u8 {
    try cursor.statement.getAllCatalogs();
    var catalog_names = std.ArrayList([]const u8).init(allocator);
    errdefer catalog_names.deinit();

    var result_set = ResultSet.init(cursor.statement);
    var iter = try result_set.rowIterator(allocator);
    defer iter.deinit(allocator);

    while (true) {
        var result = iter.next() catch continue;
        var row = result orelse break;
        const catalog_name = row.get([]const u8, "TABLE_CAT") catch continue;

        const catalog_name_dupe = try allocator.dupe(u8, catalog_name);
        try catalog_names.append(catalog_name_dupe);
    }

    return catalog_names.toOwnedSlice();
}

/// Bind a single value to a SQL parameter. If `self.parameters` is `null`, this does nothing
/// and does not return an error. Parameter indices start at 1.
pub fn bindParameter(cursor: *Cursor, allocator: Allocator, index: usize, parameter: anytype) !void {
    const stored_param = try cursor.parameters.set(allocator, parameter, index - 1);
    const sql_param = ParameterBucket.SqlParameter.default(parameter);
    try cursor.statement.bindParameter(
        @intCast(u16, index),
        .Input,
        sql_param.c_type,
        sql_param.sql_type,
        stored_param.data,
        sql_param.precision,
        stored_param.indicator,
    );
}

/// Bind a list of parameters to SQL parameters. The first item in the list will be bound
/// to the parameter at index 1, the second to index 2, etc.
///
/// Calling this function clears all existing parameters, and if an empty list is passed in
/// will not re-initialize them.
pub fn bindParameters(cursor: *Cursor, allocator: Allocator, parameters: anytype) !void {
    try cursor.parameters.reset(allocator, parameters.len);

    inline for (parameters, 0..) |param, index| {
        try cursor.bindParameter(allocator, index + 1, param);
    }
}

pub fn getErrors(cursor: *Cursor, allocator: Allocator) []odbc.Error.DiagnosticRecord {
    return cursor.statement.getDiagnosticRecords(allocator) catch return &[_]odbc.Error.DiagnosticRecord{};
}

/// Assert that the type `T` can be used as an insert parameter. Deeply checks types that have child types when necessary.
fn AssertInsertable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .Frame, .AnyFrame, .Void, .NoReturn, .Undefined, .ErrorUnion, .ErrorSet, .Fn, .Union, .Vector, .Opaque, .Null, .Type => @compileError(@tagName(std.meta.activeTag(@typeInfo(T))) ++ " types cannot be used as insert parameters"),
        .Pointer => |pointer_tag| switch (pointer_tag.size) {
            .Slice, .One => AssertInsertable(pointer_tag.child),
            else => @compileError(@tagName(std.meta.activeTag(pointer_tag.size)) ++ "-type pointers cannot be used as insert parameters"),
        },
        .Array => |array_tag| AssertInsertable(array_tag.child),
        .Optional => |op_tag| AssertInsertable(op_tag.child),
        .Struct => {},
        .Enum, .EnumLiteral => {},
        .Int, .Float, .ComptimeInt, .ComptimeFloat, .Bool => {},
    }
}
