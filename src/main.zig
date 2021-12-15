const std = @import("std");
const Allocator = std.mem.Allocator;

const odbc = @import("odbc");

const db_connection = @import("connection.zig");
const Connection = db_connection.Connection;
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var connection_info = try ConnectionInfo.initWithConfig(allocator, .{ .driver = "PostgreSQL Unicode(x64)", .dsn = "PostgreSQL35W" });
    defer connection_info.deinit();

    const connection_string = try connection_info.toConnectionString(allocator);
    defer allocator.free(connection_string);

    var connection = try Connection.init(.{});
    defer connection.deinit();

    try connection.connectExtended(connection_string);

    try connection.setCommitMode(.manual);

    var cursor = try connection.getCursor();
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

    var result_set = try cursor.executeDirect(allocator, "select * from odbc_zig_test", .{});

    // var result_iter = try result_set.itemIterator(OdbcTestType);
    // defer result_iter.deinit();

    // while (try result_iter.next()) |*result| {
    //     std.debug.print("Id: {}\n", .{result.id});
    //     std.debug.print("Name: {s}\n", .{result.name});
    //     std.debug.print("Occupation: {s}\n", .{result.occupation});
    //     std.debug.print("Age: {}\n\n", .{result.age});
    //     result.deinit(allocator);
    // }

    var result_iter = try result_set.rowIterator(allocator);
    defer result_iter.deinit();

    var stdout_writer = std.io.getStdOut().writer();

    while (try result_iter.next()) |row| {
        try row.printColumn("id", .{ .integer = "{x}" }, stdout_writer);
        try stdout_writer.writeAll("\n");
        try row.printColumn("name", .{}, stdout_writer);
        try stdout_writer.writeAll("\n");
        try row.printColumn("occupation", .{}, stdout_writer);
        try stdout_writer.writeAll("\n");
        try row.printColumn("age", .{}, stdout_writer);
        try stdout_writer.writeAll("\n\n");
        // std.debug.print("Id: {}\n", .{row.get(u32, "id")});
        // std.debug.print("Name: {s}\n", .{row.get([]const u8, "name")});
        // std.debug.print("Occupation: {s}\n", .{row.get([]const u8, "occupation")});
        // std.debug.print("Age: {}\n\n", .{row.get(u32, "age")});
    }

    try cursor.close();

    // const tables = try cursor.tablePrivileges("zig-test", "public", "odbc_zig_test");
    // defer allocator.free(tables);

    // for (tables) |*table| {
    //     std.debug.print("{}\n", .{table});
    //     table.deinit(allocator);
    // }

    // try cursor.close();

    // const tables = try cursor.tables("zig-test", "public");
    // defer allocator.free(tables);

    // for (tables) |*table| {
    //     std.debug.print("{}\n", .{table});
    //     table.deinit(allocator);
    // }
    const table_columns = try cursor.columns(allocator, "zig-test", "public", "odbc_zig_test");
    defer allocator.free(table_columns);

    for (table_columns) |*column| {
        std.debug.print("{}\n", .{column});
        column.deinit(allocator);
    }
}
