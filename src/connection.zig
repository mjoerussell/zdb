const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const Cursor = @import("Cursor.zig");

pub const CommitMode = enum(u1) { auto, manual };

const Connection = @This();

pub const ConnectionConfig = struct {
    driver: ?[]const u8 = null,
    dsn: ?[]const u8 = null,
    database: ?[]const u8 = null,
    server: ?[]const u8 = null,
    port: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    pub fn getConnectionString(config: ConnectionConfig, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        var string_builder = buffer.writer();

        if (config.driver)   |driver|   try string_builder.print("DRIVER={s};", .{driver});
        if (config.dsn)      |dsn|      try string_builder.print("DSN={s};", .{dsn});
        if (config.database) |database| try string_builder.print("DATABASE={s};", .{database});
        if (config.server)   |server|   try string_builder.print("SERVER={s};", .{server});
        if (config.port)     |port|     try string_builder.print("PORT={s};", .{port});
        if (config.username) |username| try string_builder.print("UID={s};", .{username});
        if (config.password) |password| try string_builder.print("PWD={s};", .{password});

        return buffer.toOwnedSlice();
    }
};

pub const ConnectionOptions = struct {
    version: odbc.Types.EnvironmentAttributeValue.OdbcVersion = .Odbc3,
};

environment: odbc.Environment,
connection: odbc.Connection,

pub fn init(config: ConnectionOptions) !Connection {
    var connection: Connection = undefined;

    connection.environment = try odbc.Environment.init();
    errdefer connection.environment.deinit() catch {};

    try connection.environment.setOdbcVersion(config.version);

    connection.connection = try odbc.Connection.init(&connection.environment);
    
    return connection;
}

pub fn connect(conn: *Connection, server_name: []const u8, username: []const u8, password: []const u8) !void {
    try conn.connection.connect(server_name, username, password);
}

pub fn connectWithConfig(conn: *Connection, allocator: Allocator, connection_config: ConnectionConfig) !void {
    var connection_string = try connection_config.getConnectionString(allocator);
    defer allocator.free(connection_string);

    try conn.connection.connectExtended(connection_string, .NoPrompt);
}

pub fn connectExtended(conn: *Connection, connection_string: []const u8) !void {
    try conn.connection.connectExtended(connection_string, .NoPrompt);
}

pub fn deinit(self: *Connection) void {
    self.connection.deinit() catch {};
    self.environment.deinit() catch {};
}

pub fn disconnect(self: *Connection) void {
    self.connection.disconnect() catch {};
}

pub fn setCommitMode(self: *Connection, mode: CommitMode) !void {
    try self.connection.setAttribute(.{ .Autocommit = mode == .auto });
}

pub fn getCursor(self: *Connection, allocator: Allocator) !Cursor {
    return try Cursor.init(allocator, self.connection);
}

test "ConnectionInfo" {
    const allocator = std.testing.allocator;

    var connection_info = ConnectionConfig{
        .driver = "A Driver",
        .dsn = "Some DSN Value",
        .username = "User",
        .password = "Password",
    };

    const connection_string = try connection_info.getConnectionString(allocator);
    defer allocator.free(connection_string);

    try std.testing.expectEqualStrings("DRIVER=A Driver;DSN=Some DSN Value;UID=User;PWD=Password", connection_string);    
}
