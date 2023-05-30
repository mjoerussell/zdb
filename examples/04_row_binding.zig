const std = @import("std");
const zdb = @import("zdb");

const Connection = zdb.Connection;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    // This example is the same as create_and_query_table, except we're going to see how to use RowIterator to fetch results instead of
    // ItemIterator.
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

        _ = try cursor.executeDirect(allocator, "CREATE DATABASE create_example WITH OWNER = postgres", .{});
    }

    var db_connect_config = basic_connect_config;
    db_connect_config.database = "create_example";

    {
        try conn.connectWithConfig(allocator, db_connect_config);
        defer conn.disconnect();

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = try cursor.executeDirect(allocator,
            \\CREATE TABLE zdb_test
            \\(
            \\  id serial primary key,
            \\  first_name text,
            \\  age integer default 0
            \\)
        , .{});

        const ZdbTest = struct {
            first_name: []const u8,
            age: u32,
        };

        _ = try cursor.insert(
            allocator,
            \\INSERT INTO zdb_test (first_name, age)
            \\VALUES (?, ?)
        ,
            [_]ZdbTest{
                .{ .first_name = "Joe", .age = 20 },
                .{ .first_name = "Jane", .age = 35 },
                .{ .first_name = "GiGi", .age = 85 },
            },
        );

        var result_set = try cursor.executeDirect(allocator, "select * from zdb_test where age < ?", .{40});

        // Here's where the example starts to be meaningfully different than 03 - when getting the results from the ResultSet,
        // we use rowIterator instead of itemIterator. Notice that there's no need to specify a type here. All results will be
        // mapped to the built in ResultSet.Row type.
        var result_iter = try result_set.rowIterator(allocator);
        defer result_iter.deinit(allocator);

        // Just like with ItemIterator we can iterate over all of the results.
        while (try result_iter.next()) |row| {
            // Instead of being able to get data as fields, we have to specify a name and data type in the "get" function
            const id = try row.get(u32, "id");
            // Columns can also be fetched by index. Column indicies are 1-based.
            const first_name = try row.getWithIndex([]const u8, 2);

            std.debug.print("{}: {s}\n", .{ id, first_name });

            // The main use of RowIterator is for getting result sets from unknown queries, where you can't specify
            // a struct type to use ahead of time. This means that it's also very likely that you won't know what
            // data types to use when extracting column values! For that use case there's Row.printColumn().
            //
            // printColumn writes whatever value was fetched as a string using a user-defined writer. You can specify
            // custom format strings based on the SQLType of the column, which can be checked on the Row struct. There are default
            // format strings defined for all SQLTypes already, so in most cases you don't have to specify anything and the data should
            // print in a predictable way
            var stdout_writer = std.io.getStdOut().writer();
            try row.printColumn("age", .{}, stdout_writer);

            std.debug.print("\n", .{});

            // Just as an example, let's specify some format options. We'll add a prefix and print the age as a hex value
            // We'll also print the age column using its index rather than the column name
            try row.printColumnAtIndex(3, .{ .integer = "Hex Value: {x}\n" }, stdout_writer);
        }
    }

    {
        try conn.connectWithConfig(allocator, db_connect_config);
        defer conn.disconnect();

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        _ = cursor.executeDirect(allocator, "DROP DATABASE create_example", .{}) catch {
            const errors = cursor.getErrors(allocator);
            defer allocator.free(errors);

            for (errors) |e| {
                std.debug.print("Error: {s}\n", .{e.error_message});
            }
        };
    }
}
