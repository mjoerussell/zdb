const std = @import("std");
const Allocator = std.mem.Allocator;

const DBConnection = @import("connection.zig").DBConnection;

const OdbcTestType = struct {
    id: u8,
    name: []u8,
    occupation: []u8,
    age: u32,

    fn deinit(self: *OdbcTestType, allocator: *Allocator) void {
        allocator.free(self.name);
        allocator.free(self.occupation);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var connection = try DBConnection.init(allocator, "ODBC;driver=PostgreSQL Unicode(x64);DSN=PostgreSQL35W");
    defer connection.deinit();

    var prepared_statement = try connection.prepareStatement("SELECT * FROM odbc_zig_test WHERE age >= ?");
    defer prepared_statement.deinit();

    try prepared_statement.addParam(1, 30);

    var result_set = try prepared_statement.fetch(OdbcTestType);
    defer result_set.deinit();

    std.debug.print("Rows fetched: {}\n", .{result_set.rows_fetched});

    var query_results = try result_set.getAllRows();
    defer {
        for (query_results) |*q| q.deinit(allocator);
        allocator.free(query_results);
    }

    // while (try result_set.next()) |*result| {
    for (query_results) |result| {
        std.debug.print("Id: {}\n", .{result.id});
        std.debug.print("Name: {s}\n", .{result.name});
        std.debug.print("Occupation: {s}\n", .{result.occupation});
        std.debug.print("Age: {}\n", .{result.age});
        // result.deinit(allocator);
    }

}
