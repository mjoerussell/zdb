const std = @import("std");
const builtin = std.builtin;
const build_odbc = @import("zig-odbc/build_pkg.zig");

const test_files = .{ "src/main.zig", "src/connection.zig", "src/parameter.zig"};

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable("zdb", "src/main.zig");
    exe.setBuildMode(mode);
    exe.setTarget(target);
    exe.install();

    build_odbc.buildPkg(exe, "odbc");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const odbc_library_name = if (builtin.os.tag == .windows) "odbc32" else "odbc";
    const test_step = b.step("test", "Run library tests");
    inline for (test_files) |filename| {
        var tests = b.addTest(filename);
        tests.setBuildMode(mode);
        tests.setTarget(target);
        tests.linkLibC();
        tests.linkSystemLibrary(odbc_library_name);

        test_step.dependOn(&tests.step); 
    }
}
