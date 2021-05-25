const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const db_connection = @import("connection.zig");
const DBConnection = db_connection.DBConnection;
const ConnectionInfo = db_connection.ConnectionInfo;

const Row = @import("result_set.zig").Row;

const OdbcTestType = struct {
    id: u32,
    name: []const u8,
    occupation: []const u8,
    age: u32,

    fn deinit(self: *OdbcTestType, allocator: *Allocator) void {
        allocator.free(self.name);
        allocator.free(self.occupation);
    }
};

// const OdbcTestType = struct {
//     name: []const u8,
//     age: []const u8,
//     job_info: struct {
//         job_name: []const u8
//     },

//     pub fn fromRow(row: *Row, allocator: *Allocator) !OdbcTestType {
//         var result: OdbcTestType = undefined;
//         result.name = try row.get([]const u8, "name");
        
//         const age = try row.get(u32, "age");
//         result.age = try std.fmt.allocPrint(allocator, "{} years old", .{age});

//         result.job_info.job_name = try row.get([]const u8, "occupation");

//         return result;
//     }

//     fn deinit(self: *OdbcTestType, allocator: *Allocator) void {
//         allocator.free(self.name);
//         allocator.free(self.age);
//         allocator.free(self.job_info.job_name);
//     }
// };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var connection_info = try ConnectionInfo.initWithConfig(allocator, .{
        .driver = "PostgreSQL Unicode(x64)",
        .dsn = "PostgreSQL35W"
    });
    defer connection_info.deinit();

    var connection = try DBConnection.initWithInfo(allocator, &connection_info);
    defer connection.deinit();

    // try connection.insert(OdbcTestType, "odbc_zig_test", &.{
    //     .{
    //         .id = 5,
    //         .name = "Jeff",
    //         .occupation = "Accountant",
    //         .age = 45
    //     }
    // });

    // var prepared_statement = try connection.prepareStatement("SELECT * FROM odbc_zig_test WHERE occupation = ?");
    // // var prepared_statement = try connection.prepareStatement("SELECT * FROM odbc_zig_test");
    // var prepared_statement = try connection.prepareStatement(
    //     \\SELECT *  
    //     \\FROM odbc_zig_test 
    //     \\WHERE name = ? OR age < ?
    // );
    // defer prepared_statement.deinit();

    // try prepared_statement.addParams(.{
    //     .{1, "Reese"},
    //     .{2, 30},
    // });

    // var result_set = try prepared_statement.execute(OdbcTestType);
    // defer result_set.deinit();
    
    // var result_set = try connection.executeDirect(
    //     OdbcTestType,
    //     .{ "Reese", 30 },
    //     \\SELECT *
    //     \\FROM odbc_zig_test
    //     \\WHERE name = ? OR age < ?
    // );
    // defer {
    //     result_set.close() catch |_| {};
    //     result_set.deinit();
    // }
    var cursor = try connection.getCursor();
    defer cursor.deinit() catch |_| {};

    // var result_set = try cursor.executeDirect(
    //     OdbcTestType,
    //     .{ "Reese", 30 },
    //     \\SELECT *
    //     \\FROM odbc_zig_test
    //     \\WHERE name < ? OR age < ?
    // );
    // defer result_set.deinit();

    // const query_results: []OdbcTestType = try result_set.getAllRows();
    // defer {
    //     for (query_results) |*q| q.deinit(allocator);
    //     allocator.free(query_results);
    // }

    try cursor.prepare(
        .{ "Reese", 30 },
        \\SELECT *
        \\FROM odbc_zig_test
        \\WHERE name < ? OR age < ?
    );

    var result_set = try cursor.execute(OdbcTestType);
    defer result_set.deinit();

    const query_results = try result_set.getAllRows();
    defer {
        for (query_results) |*q| q.deinit(allocator);
        allocator.free(query_results);
    }


    for (query_results) |result| {
        // std.debug.print("Id: {}\n", .{result.id});
        std.debug.print("Name: {s}\n", .{result.name});
        std.debug.print("Occupation: {s}\n", .{result.occupation});
        // std.debug.print("Occupation: {s}\n", .{result.job_info.job_name});
        std.debug.print("Age: {}\n\n", .{result.age});
    }

    // const table_columns = try connection.getColumns("zig-test", "public", "odbc_zig_test");
    // defer allocator.free(table_columns);

    // std.debug.print("Found {} columns\n", .{table_columns.len});
    // for (table_columns) |*column| {
    //     std.debug.print("Column Name: {s}\n", .{column.column_name});
    //     std.debug.print("Column Type: {s}\n", .{@tagName(column.sql_data_type)});
    //     std.debug.print("Column Nullable? {s}\n", .{@tagName(column.nullable)});
    //     std.debug.print("Decimal Digits: {}\n\n", .{column.decimal_digits});
    //     column.deinit(allocator);
    // }

}
