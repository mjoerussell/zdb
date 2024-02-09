# zdb

A library for interacting with databases in Zig. Builds on top of [zig-odbc](https://github.com/mjoerussell/zig-odbc) to provide a higher-level
interaction between the developer and the DB.

**Important!: This project is still not fully production-ready. The biggest missing piece as of now is that ODBC operations can only run synchronously.**

## Using this Library

To use zdb, follow these steps:

### 0. Dependencies

Make sure you have an ODBC driver and driver manager installed already. On Windows, this should be pre-installed. On other
systems, a good option is [`unixODBC`](http://www.unixodbc.org).

### 1. Add to `build.zig.zon`

```zig
.{
    .name = "",
    .version = "",
    .dependencies = .{
        .zdb = .{
            .url = "https://github.com/mjoerussell/zdb/<sha>.tar.gz",
            .hash = "<hash>",
        }
    }
}
```

### 2. Add zdb module & artifact to your project

```zig

pub fn build(b: *std.build.Builder) void {
    // Create executable "exe"
    
    var zdb_dep = b.dependency("zdb", .{
        .target = target,
        .optimize = optimize,
    }); 

    const zdb_module = zdb_dep.module("zdb");
    const zdb_lib = zdb_dep.artifact("zdb");

    exe.addModule("zdb", zdb_module);
    exe.linkLibrary(zdb_lib);
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

## Nix Development Flake

### Develop with Zig latest release

```shell
> nix develop -c $SHELL
> zig version
0.11.0
```

### Develop with Zig master

```shell
> nix develop .#master -c $SHELL
> zig version
0.12.0-dev.2644+42fcca49c
```

### Build

```shell
> zig build
```

### Tests

```shell
> zig build test
```
