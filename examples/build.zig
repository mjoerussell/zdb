const std = @import("std");
const buildZdb = @import("build_pkg.zig").buildPkgPath;

const examples = &[_][3][]const u8{
    .{ "basic-connect", "src/01_basic_connect.zig", "Beginner example - configure a connection string and connect to a DB" },
    .{ "connect-create", "src/02_connect_and_create_db.zig", "Connect to a DB, create a new DB, and then reconnect to that new DB" },
    .{ "create-table", "src/03_create_and_query_table.zig", "Create a new table, insert data into the table, and query data from the table" },
    .{ "row-binding", "src/04_row_binding.zig", "Query data and extract results using a RowIterator" },
};

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    inline for (examples) |example| {
        const example_exe = b.addExecutable(example[0], example[1]);
        example_exe.setTarget(target);
        example_exe.setBuildMode(mode);
        try buildZdb(example_exe, "zdb", "..");
        example_exe.install();

        const run_cmd = example_exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step(example[0], example[2]);
        run_step.dependOn(&run_cmd.step);
    }

}
