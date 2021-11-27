const std = @import("std");
const builtin = @import("builtin");
const LibExeObjStep = std.build.LibExeObjStep;
const Pkg = std.build.Pkg;

pub fn buildPkg(exe: *LibExeObjStep, package_name: []const u8) void {
    exe.linkLibC();

    const odbc_library_name = if (builtin.os.tag == .windows) "odbc32" else "odbc";
    if (builtin.os.tag == .macos) {
        exe.addIncludeDir("/usr/local/include");
        exe.addIncludeDir("/usr/local/lib");
    }

    exe.linkSystemLibrary(odbc_library_name);

    const self_pkg = Pkg{ .name = package_name, .path = .{ .path = "zdb/src/zdb.zig" }, .dependencies = &.{Pkg{
        .name = "odbc",
        .path = .{ .path = "zdb/zig-odbc/src/lib.zig" },
    }} };

    exe.addPackage(self_pkg);
}
