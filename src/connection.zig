const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const PreparedStatement = @import("prepared_statement.zig").PreparedStatement;
const ResultSet = @import("result_set.zig").ResultSet;
const FetchResult = @import("result_set.zig").FetchResult;

pub const Column = struct {
    table_category: ?[]const u8,
    table_schema: ?[]const u8,
    table_name: []const u8,
    column_name: []const u8,
    data_type: u16,
    type_name: []const u8,
    column_size: ?u32,
    buffer_length: ?u32,
    decimal_digits: ?u16,
    num_prec_radix: ?u16,
    nullable: odbc.Types.Nullable,
    remarks: ?[]const u8,
    column_def: ?[]const u8,
    sql_data_type: odbc.Types.SqlType,
    sql_datetime_sub: ?u16,
    char_octet_length: ?u32,
    ordinal_position: u32,
    is_nullable: ?[]const u8,

    pub fn deinit(self: *Column, allocator: *Allocator) void {
        if (self.table_category) |tc| allocator.free(tc);
        if (self.table_schema) |ts| allocator.free(ts);
        allocator.free(self.table_name);
        allocator.free(self.column_name);
        allocator.free(self.type_name);
        if (self.remarks) |r| allocator.free(r);
        if (self.column_def) |cd| allocator.free(cd);
        if (self.is_nullable) |in| allocator.free(in);
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

    pub fn insert(self: *DBConnection, comptime DataType: type, comptime table_name: []const u8, values: []const DataType) !void {
        // @todo Maybe return num rows inserted?
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

        var prepared_statement = try self.prepareStatement(insert_statement);
        defer prepared_statement.deinit();

        for (values) |value| {
            inline for (std.meta.fields(DataType)) |field, index| {
                try prepared_statement.addParam(index + 1, @field(value, field.name));
            }

            prepared_statement.execute() catch |err| {
                var err_buf: [@sizeOf(odbc.Error.SqlState) * 3]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(err_buf[0..]);
                const errors = try prepared_statement.statement.getErrors(&fba.allocator);
                for (errors) |e| {
                    std.debug.print("Insert Error: {s}\n", .{@tagName(e)});
                }
            };
        }
    }

    /// Create a prepared statement from the specified SQL statement. 
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
        errdefer statement.deinit() catch |_| {};

        try statement.prepare(sql_statement);

        return try PreparedStatement.init(self.allocator, statement, num_params);
    }

    /// Get information about the columns of a given table.
    pub fn getColumns(self: *DBConnection, catalog_name: []const u8, schema_name: []const u8, table_name: []const u8) ![]Column {
        var statement = try self.getStatement();
        defer statement.deinit() catch |_| {};

        var result_set = try ResultSet(Column).init(&statement, self.allocator);
        defer result_set.deinit();

        try statement.setAttribute(.{ .RowBindType = @sizeOf(FetchResult(Column)) });
        try statement.setAttribute(.{ .RowArraySize = 10 });
        try statement.setAttribute(.{ .RowStatusPointer = result_set.row_status });
        try statement.setAttribute(.{ .RowsFetchedPointer = &result_set.rows_fetched });

        try statement.columns(catalog_name, schema_name, table_name, null);

        statement.fetch() catch |err| switch (err) {
            error.StillExecuting => {},
            error.NoData => {},
            else => {
                var error_buf: [@sizeOf(odbc.Error.SqlState) * 3]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(error_buf[0..]);
                const errors = statement.getErrors(&fba.allocator) catch |_| return err;
                for (errors) |e| {
                    std.debug.print("Fetch Error: {s}\n", .{@tagName(e)});
                }

                return err;
            }
        };

        return try result_set.getAllRows();
    }

    pub fn getStatement(self: *DBConnection) !odbc.Statement {
        return try odbc.Statement.init(&self.connection, self.allocator);
    }
};