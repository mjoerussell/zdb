const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const PreparedStatement = @import("prepared_statement.zig").PreparedStatement;

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