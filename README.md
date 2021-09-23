# zdb

A library for interacting with databases in Zig. Builds on top of [zig-odbc](https://github.com/mjoerussell/zig-odbc) to provide a higher-level
interaction between the developer and the DB.

**Important!: In it's current stage, this is not ready for any serious use-cases. Its features are limited and the implementation has issues.**

## Using this Library

To use zdb, follow these steps:

### 0. Dependencies

Make sure you have an ODBC driver and driver manager installed already. On Windows, this should be pre-installed. On other
systems, a good option is [`unixODBC`](unixodbc.org).

### 1. Clone

Include this repo in your project path. Best way to do this is by running

```
$ git submodule add https://github.com/mjoerussell/zdb --recurse-submodules
$ cd zdb
$ git submodule update --init --recursive
```

After this you should have **zdb** and also it's dependencies fully pulled into your project.

### 2. Add to your project

Add this to your project's `build.zig`:

```zig

const build_zdb = @import("zdb/build_pkg.zig");

pub fn build(b: *std.build.Builder) void {
    // ...
    build_zdb.buildPkg(exe, "zdb");
}
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
    var cursor = try connection.getCursor();
    defer cursor.deinit();

    try cursor.insert(OdbcTestType, "odbc_test_zig", &.{
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

### Execute Statements Directly

If you only want to execute a statement once, the fastest way to do that is to use `executeDirect`. Once you have
a cursor you can use `executeDirect` like this:

```zig
const OdbcTestType = struct {
    id: u8,
    name: []u8,
    occupation: []u8,
    age: u32,
};

var result_set = try cursor.executeDirect(
    OdbcTestType,
    .{ 20 },
    "SELECT * FROM odbc_zig_test WHERE age >= ?"
);
defer result_set.deinit();
```

### Prepared Statements

Once you have a cursor, you can create prepared statements and add parameters to them.

```zig
try cursor.prepare(
    .{ 20 },
    "SELECT * FROM odbc_zig_test WHERE age >= ?"
);
```

Results can then be fetched from the statement by providing a target type and calling `fetch()`.

```zig
var result_set = try cursor.execute(OdbcTestType);
defer result_set.deinit();

std.debug.print("Rows fetched: {}\n", .{result_set.rows_fetched});

while (try result_set.next()) |result| {
    std.debug.print("Id: {}\n", .{result.id});
    std.debug.print("Name: {s}\n", .{result.name});
    std.debug.print("Occupation: {s}\n", .{result.occupation});
    std.debug.print("Age: {}\n", .{result.age});
}
```

### Custom Row Mapping

Sometimes you want to use structs that don't directly correspond with a table or result set from a SQL query. Currently, you can do
that with a `fromRow` function. To get started, define a function on your target struct in this way:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const zdb = @import("zdb");
const Row = zdb.Row;

const Target = struct {
    fieldA: u32,
    fieldB: struct {
        inner: []const u8,
    },
    fieldC: []const u8,

    // Column-wise binding will be used if the struct has a function with this signature on it
    pub fn fromRow(row: *Row, allocator: *Allocator) !Target {
        var t: Target = undefined;

        // Get data by calling row.get with the desired return type and the column name
        t.fieldA = row.get(u32, "a") catch |_| 0;
        t.fieldB.inner = try row.get([]const u8, "column_b");

        const c = row.get(f32, "c") orelse 1.0;
        t.fieldC = try std.fmt.allocPrint(allocator, "Column C is {d:.2}", .{c});

        return t;
    }
}
```

The Cursor functions (`executeDirect`, `prepare`, etc) and the ResultSet functions (`next`, `getAllRows`) work the same whether your target
struct is using default field-based binding or `fromRow` bindings. So when you're fetching data, you shouldn't have to worry about which
type ends up being used.

### ODBC Fallthrough

If you want to use this package in it's current state, then it would probably be necessary to use the ODBC bindings directly to
supplement missing features. You can access the bindings by importing them like this:

```
const odbc = @import("zdb").odbc;
```

Please see [zig-odbc](https://github.com/mjoerussell/zig-odbc) for more information about these bindings.
