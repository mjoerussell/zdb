# zdb

A library for interacting with databases in Zig. Builds on top of [zig-odbc](https://github.com/mjoerussell/zig-odbc) to provide a higher-level
interaction between the developer and the DB.

**Important!: In it's current stage, this is not ready for any serious use-cases. Its features are limited and the implementation has issues.**

## Using this Library

To use zdb, follow these steps:

### 1. Clone

Include this repo in your project path. Best way to do this is by running `git submodule add https://github.com/mjoerussell/zdb --recurse-submodules`.

### 2. (a) Windows

Add this to your project's `build.zig`:

```zig
exe.addPackagePath("zdb", "zdb/src/zdb.zig");
exe.linkLibC();
exe.linkSystemLibrary("odbc32");
```

### 2. (b) MacOS

Install [`unixODBC`](unixodbc.org) if you have not already.

Add this to your project's `build.zig`:

```zig
exe.addPackagePath("zdb", "zdb/src/zdb.zig");
exe.linkLibC();
exe.addIncludeDir("/usr/local/include");
exe.addIncludeDir("/usr/local/lib");
exe.linkSystemLibrary("odbc");
```

### 3. Usage in Code

Wherever you use zdb, include `const zdb = @import("zdb");`.

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

### Insert Data

You can insert data simply by passing in an array of structs to `DBConnection.insert()`. There are a few caveats to remember:

1. The struct's fields must match the table column names, and they must all be present (unless the DB column has default values).
2. Not all field types are valid. A few general rules for what field types can be passed currently:
   - Numeric types
   - `[]const u8` 'strings'
   - Enums with numeric backing types
   - Optional types
   - Certain structs - see `odbc.Types.CType` and `odbc.Types.SqlType`.

Here's an example of inserting data

```zig
const OdbcTestType = struct {
    id: u8,
    name: []u8,
    occupation: []u8,
    age: u32,
};

fn main() {
    // ... initialize connection

    try connection.insert(OdbcTestType, "odbc_test_zig", &.{
        .{
            .id = 1,
            .name = "John",
            .occupation = "Plumber",
            .age = 30
        },
        .{
            .id = 2,
            .name = "Sara",
            .occupation = "Pilot",
            .age = 25
        }
    });
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

### ODBC Fallthrough

If you want to use this package in it's current state, then it would probably be necessary to use the ODBC bindings directly to
supplement missing features. You can access the bindings by importing them like this:

```
const odbc = @import("zdb").odbc;
```

Please see [zig-odbc](https://github.com/mjoerussell/zig-odbc) for more information about these bindings.
