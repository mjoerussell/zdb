const std = @import("std");
const builtin = std.builtin;
const CompileStep = std.build.CompileStep;

const test_files = .{
    "src/ParameterBucket.zig",
    "src/Connection.zig",
};

const Example = struct {
    name: []const u8,
    source_file: std.Build.FileSource,
    description: []const u8,
};

const examples = [_]Example{
    .{
        .name = "basic-connect",
        .source_file = .{ .path = "examples/01_basic_connect.zig" },
        .description = "Beginner example - configure a connection string and connect to a DB",
    },
    .{
        .name = "connect-create",
        .source_file = .{ .path = "examples/02_connect_and_create_db.zig" },
        .description = "Connect to a DB, create a new DB, and then reconnect to that new DB",
    },
    .{
        .name = "create-table",
        .source_file = .{ .path = "examples/03_create_and_query_table.zig" },
        .description = "Create a new table, insert data into the table, and query data from the table",
    },
    .{
        .name = "row-binding",
        .source_file = .{ .path = "examples/04_row_binding.zig" },
        .description = "Query data and extract results using a RowIterator",
    },
};

pub fn build(b: *std.build.Builder) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zig_odbc_dep = b.dependency("zig_odbc", .{
        .target = target,
        .optimize = optimize,
    });

    var zdb_module = b.createModule(.{
        .source_file = .{ .path = "src/zdb.zig" },
        .dependencies = &.{
            .{ .name = "odbc", .module = zig_odbc_dep.module("zig-odbc") },
        },
    });

    var lib = b.addStaticLibrary(.{
        .name = "zdb",
        .optimize = optimize,
        .target = target,
    });

    const odbc_lib = zig_odbc_dep.artifact("odbc");
    lib.linkLibrary(odbc_lib);

    inline for (examples) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = example.source_file,
            .optimize = optimize,
            .target = target,
        });

        example_exe.addModule("zdb", zdb_module);
        example_exe.linkLibrary(odbc_lib);

        const install_step = b.addInstallArtifact(example_exe, .{});

        const run_cmd = b.addRunArtifact(example_exe);
        run_cmd.step.dependOn(&install_step.step);
        const run_step = b.step(example.name, example.description);
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run library tests");
    inline for (test_files) |filename| {
        const tests = b.addTest(.{
            .root_source_file = .{ .path = filename },
            .optimize = optimize,
            .target = target,
        });

        tests.linkLibrary(odbc_lib);
        test_step.dependOn(&tests.step);
    }
}
