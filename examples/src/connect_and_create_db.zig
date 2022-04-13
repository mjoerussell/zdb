const std = @import("std");
const zdb = @import("zdb");

const Connection = zdb.Connection;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    // In this example we'll create a new database and reconnect to it.
    // The beginning is the same as basic_connect
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

        // Once you have a cursor you can execute arbitrary SQL statements with executeDirect. executeDirect is a good option
        // if you're only planning on executing a statement once. Parameters can be set with the final arg, but in this case
        // none are required.
        // Query results can be fetched using the ResultSet value returned by executeDirect. We don't care about the result set
        // of this query, so we'll ignore it.
        _ = try cursor.executeDirect(allocator, "CREATE DATABASE create_example WITH OWNER = postgres", .{});
    }   

    // Now that the new DB was created we can connect to it. We'll use the same options as the original connection,
    // except with the database field set to "create_example".
    basic_connect_config.database = "create_example";
    var example_connection_info = try Connection.ConnectionInfo.initWithConfig(allocator, basic_connect_config);
    defer example_connection_info.deinit();

    const example_connection_string = try example_connection_info.toConnectionString(allocator);
    defer allocator.free(example_connection_string);

    {
        // For now, we'll just connect and disconnect without doing anything.
        try conn.connectExtended(example_connection_string);
        defer conn.disconnect();
    }

    {
        // Now we'll clean up the temp table
        try conn.connectExtended(pg_connection_string);

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = try cursor.executeDirect(allocator, "DROP DATABASE create_example", .{});
    }

}
