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
            .statement = try Statement.init(connection, allocator),
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

        return try ResultSet(ResultType).init(self.allocator, self.statement);
    }

    /// Execute a statement and return the result set. A statement must have been prepared previously
    /// using `Cursor.prepare()`.
    pub fn execute(self: *Cursor, comptime ResultType: type) !ResultSet(ResultType) {
        _ = try self.statement.execute();
        return try ResultSet(ResultType).init(self.allocator, self.statement);
    }

    /// Prepare a SQL statement for execution. If you want to execute a statement multiple times,
    /// preparing it first is much faster because you only have to compile and load the statement
    /// once on the driver/DBMS. Use `Cursor.execute()` to get the results.
    pub fn prepare(self: *Cursor, parameters: anytype, sql_statement: []const u8) !void {
        try self.bindParameters(parameters);
        try self.statement.prepare(sql_statement);
    }

    pub fn insert(self: *Cursor, comptime DataType: type, comptime table_name: []const u8, values: []const DataType) !usize {
        // @todo Try using arrays of parameters for bulk ops
        comptime const num_fields = std.meta.fields(DataType).len;

        const insert_statement = comptime blk: {
            var statement: []const u8 = "INSERT INTO " ++ table_name ++ " (";
            var statement_end: []const u8 = "VALUES (";
            for (std.meta.fields(DataType)) |field, index| {
                statement_end = statement_end ++ "?";
                var column_name: []const u8 = &[_]u8{}; 
                for (field.name) |c| {
                    column_name = column_name ++ [_]u8{std.ascii.toLower(c)};
                }
                statement = statement ++ column_name;
                if (index < num_fields - 1) {
                    statement = statement ++ ", ";
                    statement_end = statement_end ++ ", ";
                }
            }

            statement = statement ++ ") " ++ statement_end ++ ")";
            break :blk statement;
        };

        try self.prepare(.{}, insert_statement);
        self.parameters = try ParameterBucket.init(self.allocator, num_fields);

        var num_rows_inserted: usize = 0;
        for (values) |value| {
            inline for (std.meta.fields(DataType)) |field, index| {
                try self.bindParameter(index, @field(value, field.name));
            }
            
            _ = try self.statement.execute();

            num_rows_inserted += try self.statement.rowCount();
        }
        
        // @todo manual-commit mode
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
        var result_set = try ResultSet(Column).init(self.allocator, self.statement);
        defer result_set.deinit();

        try self.statement.columns(catalog_name, schema_name, table_name, null);

        return try result_set.getAllRows();
    }

    pub fn tables(self: *Cursor, catalog_name: ?[]const u8, schema_name: ?[]const u8) ![]Table {
        var result_set = try ResultSet(Table).init(self.allocator, self.statement);
        defer result_set.deinit();

        try self.statement.tables(catalog_name, schema_name, null, null);

        return try result_set.getAllRows();
    }

    pub fn tablePrivileges(self: *Cursor, catalog_name: ?[]const u8, schema_name: ?[]const u8, table_name: []const u8) ![]TablePrivileges {
        var result_set = try ResultSet(TablePrivileges).init(self.allocator, self.statement);
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
        return self.statement.getDiagnosticRecords() catch |_| return &[_]odbc.Error.DiagnosticRecord{};
    }



};