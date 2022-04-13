const std = @import("std");
const buildZdb = @import("build_pkg.zig").buildPkgPath;

const examples = &[_][2][]const u8{
    .{ "basic-connect", "src/basic_connect.zig" },
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
        const run_step = b.step(example[0], "Run example \"" ++ example[0] ++ "\"");
        run_step.dependOn(&run_cmd.step);
    }

}
