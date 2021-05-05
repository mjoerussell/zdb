# zdb

A library for interacting with databases in Zig. Builds on top of [zig-odbc](https://github.com/mjoerussell/zig-odbc) to provide a higher-level
interaction between the developer and the DB.

**Important!: In it's current stage, this is not ready for any serious use-cases. Its features are limited and the implementation has issues.**

## Using this Library

To use zdb, follow these steps:

1. Include this repo in your project path.
2. Add this to your project's `build.zig`:

```zig
exe.addPackagePath("zdb", "zdb/src/zdb.zig");
exe.linkLibC();
exe.linkSystemLibrary("odbc32");
```

3. Wherever you use zdb, include `const zdb = @import("zdb");`.

## Current Features

Currently this library is in alpha and is limited in scope. The currently available features include:

### Connect to Database

It's easy to connect to a database using a connection string:

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var connection = try DBConnection.init(allocator, "ODBC;driver=PostgreSQL Unicode(x64);DSN=PostgreSQL35W");
    defer connection.deinit();
}
```

### Prepared Statements

Once you have a connection, you can create prepared statements and add parameters to them.

```zig
var prepared_statement = try connection.prepareStatement("SELECT * FROM odbc_zig_test WHERE age >= ?");
defer prepared_statement.deinit();

try prepared_statement.addParam(1, 30);
```

Results can then be fetched from the statement by providing a target type and calling `fetch()`.

```zig
const OdbcTestType = struct {
    id: u8,
    name: []u8,
    occupation: []u8,
    age: u32,
};

var result_set = try prepared_statement.fetch(OdbcTestType);
defer result_set.deinit();

std.debug.print("Rows fetched: {}\n", .{result_set.rows_fetched});

while (try result_set.next()) |result| {
    std.debug.print("Id: {}\n", .{result.id});
    std.debug.print("Name: {s}\n", .{result.name});
    std.debug.print("Occupation: {s}\n", .{result.occupation});
    std.debug.print("Age: {}\n", .{result.age});
}
```
