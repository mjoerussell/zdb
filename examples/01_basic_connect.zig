const std = @import("std");
const zdb = @import("zdb");

const Connection = zdb.Connection;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    // The first step to using zdb is creating your data source. In this example we'll use the default postgres
    // settings and connect without using a DSN.
    var connection_info = Connection.ConnectionConfig{
        .driver = "PostgreSQL Unicode(x64)",
        .database = "postgres",
        .server = "localhost",
        .port = "5433",
        .username = "postgres",
        .password = "postgres",
    };

    // Before connecting, initialize a connection struct with the default settings.
    var conn = try Connection.init(.{});
    defer conn.deinit();

    // connectWithConfig is used to connect to a data source using a connection string, which is generated based on the ConnectionConfig.
    // You can also connect to a data source using a DSN name, username, and password with connection.connect()
    try conn.connectWithConfig(allocator, connection_info);

    // In order to execute statements, you have to create a Cursor object.
    var cursor = try conn.getCursor(allocator);
    defer cursor.deinit(allocator) catch {};

    // We'll run a simple operation on this DB to start - simply querying all the database names assocaiated with this
    // connection. Since we connected to a specific DB above, this should only return "postgres"
    var catalogs = try cursor.catalogs(allocator);
    defer allocator.free(catalogs);

    std.debug.print("Got {} catalogs\n", .{catalogs.len});

    for (catalogs) |cat| {
        std.log.debug("{s}", .{cat});
    }
}
