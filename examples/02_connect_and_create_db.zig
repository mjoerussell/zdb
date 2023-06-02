const std = @import("std");
const zdb = @import("zdb");

const Connection = zdb.Connection;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    // In this example we'll create a new database and reconnect to it.
    // The beginning is the same as basic_connect
    var basic_connect_config = Connection.ConnectionConfig{
        .driver = "PostgreSQL Unicode(x64)",
        .database = "postgres",
        .server = "localhost",
        .port = "5433",
        .username = "postgres",
        .password = "postgres",
    };

    var conn = try Connection.init(.{});
    defer conn.deinit();

    {
        try conn.connectWithConfig(allocator, basic_connect_config);
        defer conn.disconnect();

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        // Once you have a cursor you can execute arbitrary SQL statements with executeDirect. executeDirect is a good option
        // if you're only planning on executing a statement once. Parameters can be set with the final arg, but in this case
        // none are required.
        // Query results can be fetched using the ResultSet value returned by executeDirect. We don't care about the result set
        // of this query, so we'll ignore it.
        _ = try cursor.executeDirect(allocator, "CREATE DATABASE create_example WITH OWNER = postgres", .{});
    }

    // Now that the new DB was created we can connect to it. We'll use the same options as the original connection,
    // except with the database field set to "create_example".
    var db_connect_config = basic_connect_config;
    db_connect_config.database = "create_example";

    {
        // For now, we'll just connect and disconnect without doing anything.
        try conn.connectWithConfig(allocator, db_connect_config);
        conn.disconnect();
    }

    {
        // Now we'll clean up the temp table
        try conn.connectWithConfig(allocator, basic_connect_config);
        defer conn.disconnect();

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = try cursor.executeDirect(allocator, "DROP DATABASE create_example", .{});
    }
}
