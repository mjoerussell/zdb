const std = @import("std");
const zdb = @import("zdb");

const Connection = zdb.Connection;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    var basic_connect_config = Connection.ConnectionInfo.Config{
        .driver = "PostgreSQL Unicode(x64)",
        .database = "postgres",
        .server = "localhost",
        .port = "5433",
        .username = "postgres",
        .password = "postgres",
    };

    var pg_connection_info = try Connection.ConnectionInfo.initWithConfig(allocator, basic_connect_config);
    defer pg_connection_info.deinit();

    const pg_connection_string = try pg_connection_info.toConnectionString(allocator);
    defer allocator.free(pg_connection_string);
    
    var conn = try Connection.init(.{});
    defer conn.deinit();

    {
        try conn.connectExtended(pg_connection_string);
        defer conn.disconnect();

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = try cursor.executeDirect(allocator, "CREATE DATABASE create_example WITH OWNER = postgres", .{});
    }

    basic_connect_config.database = "create_example";
    var example_connection_info = try Connection.ConnectionInfo.initWithConfig(allocator, basic_connect_config);
    defer example_connection_info.deinit();

    const example_connection_string = try example_connection_info.toConnectionString(allocator);
    defer allocator.free(example_connection_string);

    {
        try conn.connectExtended(example_connection_string);
        defer conn.disconnect();
    }

    {
        try conn.connectExtended(pg_connection_string);

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = try cursor.executeDirect(allocator, "DROP DATABASE create_example", .{});
    }

}
