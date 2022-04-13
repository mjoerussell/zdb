const std = @import("std");
const zdb = @import("zdb");

const Connection = zdb.Connection;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    var connection_info = try Connection.ConnectionInfo.initWithConfig(allocator, .{
        .driver = "PostgreSQL Unicode(x64)",
        .database = "postgres",
        .server = "localhost",
        .port = "5433",
        .username = "postgres",
        .password = "postgres",
    });
    defer connection_info.deinit();

    const connection_string = try connection_info.toConnectionString(allocator);
    defer allocator.free(connection_string);
    
    var conn = try Connection.init(.{});
    defer conn.deinit();

    try conn.connectExtended(connection_string);

    var cursor = try conn.getCursor(allocator);
    defer cursor.deinit(allocator) catch {}; 

    var catalogs = try cursor.catalogs(allocator);
    defer allocator.free(catalogs);

    std.debug.print("Got {} catalogs\n", .{catalogs.len});

    for (catalogs) |cat| {
        std.log.debug("{s}", .{cat});
    }

}
