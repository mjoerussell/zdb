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
//         result.name = try row.get([]const u8, allocator, "name");
        
//         const age = try row.get(u32, allocator, "age");
//         result.age = try std.fmt.allocPrint(allocator, "{} years old", .{age});

//         result.job_info.job_name = try row.get([]const u8, allocator, "occupation");

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

    const connection_string = try connection_info.toConnectionString(allocator);
    defer allocator.free(connection_string);

    var connection = try DBConnection.initWithConnectionString(connection_string);
    defer connection.deinit();

    try connection.setCommitMode(.manual);

    var cursor = try connection.getCursor(allocator);
    defer cursor.deinit() catch {};

    // _ = try cursor.insert(
    //     OdbcTestType, 
    //     \\INSERT INTO odbc_zig_test (id, name, occupation, age)
    //     \\VALUES (?, ?, ?, ?)
    //     , &[_]OdbcTestType{
    //     .{
    //         .id = 7,
    //         .name = "Greg",
    //         .occupation = "Programmer",
    //         .age = 35
    //     }
    // });

    // try cursor.commit();

    // try cursor.prepare(
    //     .{ "Reese", 30 },
    //     \\SELECT *
    //     \\FROM odbc_zig_test
    //     \\WHERE name = ? OR age < ?
    // );

    var result_set = try cursor.executeDirect(OdbcTestType, .{}, "select * from odbc_zig_test");
    defer result_set.deinit();

    const query_results = try result_set.getAllRows();
    defer {
        for (query_results) |*q| q.deinit(allocator);
        allocator.free(query_results);
    }


    for (query_results) |result| {
        std.debug.print("Id: {}\n", .{result.id});
        std.debug.print("Name: {s}\n", .{result.name});
        std.debug.print("Occupation: {s}\n", .{result.occupation});
        std.debug.print("Age: {}\n\n", .{result.age});
    }

    try cursor.close();

    // const tables = try cursor.tablePrivileges("zig-test", "public", "odbc_zig_test");
    // defer allocator.free(tables);

    // for (tables) |*table| {
    //     std.debug.print("{}\n", .{table});
    //     table.deinit(allocator);
    // }

    // try cursor.close();

    // const table_columns = try cursor.columns("zig-test", "public", "odbc_zig_test");
    // defer allocator.free(table_columns);

    // for (table_columns) |*column| {
    //     std.debug.print("{}\n", .{column});
    //     column.deinit(allocator);
    // }

}
