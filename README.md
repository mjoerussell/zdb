# zdb

A library for interacting with databases in Zig. Builds on top of [zig-odbc](https://github.com/mjoerussell/zig-odbc) to provide a higher-level
interaction between the developer and the DB.

**Important!: This project is still not fully production-ready. The biggest missing piece as of now is that ODBC operations can only run synchronously.**

## Using this Library

To use zdb, follow these steps:

### 0. Dependencies

Make sure you have an ODBC driver and driver manager installed already. On Windows, this should be pre-installed. On other
systems, a good option is [`unixODBC`](http://www.unixodbc.org).

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
const zdb = @import("zdb");
const Connection = zdb.Connection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var connection = try Connection.init(.{});
    defer connection.deinit();

    try connection.connectExtended("ODBC;driver=PostgreSQL Unicode(x64);DSN=PostgreSQL35W");
}
```

You can also use a configuration struct to connect:

```zig  
try connection.connectWithConfig(allocator, .{ .driver = "PostgeSQL Unicode(x64)", .dsn = "PostgeSQL35W" });
```

### Execute Statements

Arbitrary SQL statements can be executed with `Cursor.executeDirect`. Prepared statements can also be created and then executed with `Cursor.prepare` and `Cursor.execute`, respectively.

```zig
// An example of executing a statement directly

//.....

var cursor = try connection.getCursor(allocator);
defer cursor.deinit();

var result_set = try cursor.executeDirect(allocator, "select * from example_table", .{});

// use results.......
```

Both direct executions and prepared executions support statement parameters. `Cursor.executeDirect` and `Cursor.prepare` support passing parameters as a tuple. Prepared statements can be used with multiple sets of parameters by calling `Cursor.bindParameters` in-between executions.

```zig
// An example of executing a query with parameters

var cursor = try connection.getCursor(allocator);
defer cursor.deinit(allocator);

var result_set = try cursor.executeDirect(allocator, "select * from example_table where value > ?", .{10});

// use results.....
```

### Insert Data

You can use `Cursor.executeDirect` and the prepared statement alternative to execute **INSERT** statements just as described in the previous section; however, one often wants to insert multiple values at once. It's also very common to model tables as structs in code, and to want to push entire structs to a table. Because of this zdb has a convenient way to run **INSERT** queries.

For a complete example of how this feature can be used please refer to the example [03_create_and_query_table](./examples/src/03_create_and_query_table.zig).

### ODBC Fallthrough

If you want to use this package in it's current state, then it would probably be necessary to use the ODBC bindings directly to
supplement missing features. You can access the bindings by importing them like this:

```
const odbc = @import("zdb").odbc;
```

Please see [zig-odbc](https://github.com/mjoerussell/zig-odbc) for more information about these bindings.
