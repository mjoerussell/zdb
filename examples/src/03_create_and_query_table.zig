const std = @import("std");
const zdb = @import("zdb");

const Connection = zdb.Connection;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    // In this example we'll create a new DB just like create_and_connect, but we'll also perform some inserts and
    // queries on a new table.
    // Start by connecting and initializing just like before
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
        // Connect to the DB create_example
        try conn.connectExtended(example_connection_string);
        defer conn.disconnect();

        var cursor = try conn.getCursor(allocator);
        defer cursor.deinit(allocator) catch {};

        // We'll create a simple table called zdb_test with standard SQL. Just like the other queries that we've seen so far,
        // we're going to throw away the result set because we don't care about it here.
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

        // There are several ways to insert data into a table using zdb
        // If you want you can stick to executeDirect (although prepare + execute would probably make for sense in this case) and 
        // execute the statements just like before - there's nothing inherently different about running an insert query vs. a select query
        // from zdb's perspective.
        // 
        // Cursor provides a convenience function, "insert", that makes it a bit easier to insert several values at once. "insert" takes care
        // of binding parameters from a list of inserted items so that you don't have to handle it manually. However, "insert" does *not* write
        // queries for you - this isn't an ORM library.
        //  
        // In this first example, we'll use a struct to set parameters. The number of fields on the struct must match the number of parameter slots
        // on the query, otherwise you'll get an error. **The names of the struct fields do not have to match the column names of the table**.
        const ZdbTest = struct {
            first_name: []const u8,
            age: u32,
        };

        // Pass the insert query to run and pass an array of ZdbTest structs containing the params to bind.
        // "insert" will create a prepared statement and execute the query with your params.
        _ = try cursor.insert(
            allocator,
            \\INSERT INTO zdb_test (first_name, age)
            \\VALUES (?, ?)
            , [_]ZdbTest{ .{ .first_name = "Joe", .age = 20 }, .{ .first_name = "Jane", .age = 35 } },
        );

        // Another option is to use a tuple - this is a nice demonstration of how the parameter binding is positional, not related to the
        // field names. Here we create an explicit tuple type in order to properly type our param array
        const InsertTuple = std.meta.Tuple(&.{ []const u8, u32 });
        _ = try cursor.insert(
            allocator,
            \\INSERT INTO zdb_test (first_name, age)
            \\VALUES (?, ?)
            , [_]InsertTuple{ .{ "GiGi", 85 }}
        );

        // If you are only binding one parameter in the insert query, you don't have to create a struct/tuple to pass params. Single params can be passed
        // as an array/slice and they'll be inserted one-by-one.

        // Now that the data's been inserted, we can query the table.
        //
        // Here we're finally going to see an example of using the ResultSet return value from executeDirect. We can also see that we're binding a parameter
        // to this query. If this was a prepared statement, we could execute it multiple times with different parameters.
        //
        // We're selecting only first_name and age from the table so that the result set can match ZdbTest, however it's important to note that,
        // just like with insert, these bindings are *positional*, not name-based. If we reversed then order of these columns in the result set
        // then we would get an incorrect binding.
        var result_set = try cursor.executeDirect(allocator, "select first_name, age from zdb_test where age < ?", .{40});

        // ResultSet has two ways of fetching results from the DB - ItemIterator and RowIterator. In this example we're using ItemIterator. This 
        // will bind rows to structs, allowing you to directly convert query results to Zig data types. This is useful if you know what columns you'll
        // be extracting ahead of time and can design structs around your queries (or vice versa).
        //
        // RowIterator is useful for binding to arbitrary columns which you can then query on an individual basis. This might come in handy if you don't
        // know what queries are going to be run, or if a query is going to be returning large numbers of columns and you only want to look at a few of them
        // without having to model the entire result set.
        //
        // Both types of iterators are used in the same way - get a result set, call a function to get an iterator over the results, and then call iter.next() to
        // get each row in the format specified by the type of iterator.
        var result_iter = try result_set.itemIterator(ZdbTest, allocator);
        defer result_iter.deinit();

        while (try result_iter.next()) |item| {
            // Since we're getting ZdbTest's out of this iterator, we get to directly access our data through struct fields.
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
