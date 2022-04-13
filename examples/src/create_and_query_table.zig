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

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = try cursor.executeDirect(
            allocator,
            \\CREATE TABLE zdb_test
            \\(
            \\  id serial primary key,
            \\  first_name text,
            \\  age integer default 0
            \\)
            , .{}
        );

        const ZdbTest = struct {
            first_name: []const u8,
            age: u32,
        };

        _ = try cursor.insert(
            allocator,
            \\INSERT INTO zdb_test (first_name, age)
            \\VALUES (?, ?)
            , [_]ZdbTest{ .{ .first_name = "Joe", .age = 20 }, .{ .first_name = "Jane", .age = 35 } },
        );

        const InsertTuple = std.meta.Tuple(&.{ []const u8, u32 });
        _ = try cursor.insert(
            allocator,
            \\INSERT INTO zdb_test (first_name, age)
            \\VALUES (?, ?)
            , [_]InsertTuple{ .{ "GiGi", 85 }}
        );

        var result_set = try cursor.executeDirect(allocator, "select first_name, age from zdb_test where age < ?", .{40});
        var result_iter = try result_set.itemIterator(ZdbTest, allocator);
        defer result_iter.deinit();

        while (try result_iter.next()) |item| {
            std.debug.print("First Name: {s}\n", .{item.first_name});
            std.debug.print("Age: {}\n", .{item.age});    
        }

    }

    {
        try conn.connectExtended(pg_connection_string);

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = try cursor.executeDirect(allocator, "DROP DATABASE create_example", .{});
    }

}
