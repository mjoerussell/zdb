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

    const self_pkg = Pkg{
        .name = package_name, 
        .path = .{ .path = "zdb/src/zdb.zig" },
        .dependencies = &.{
            Pkg{
                .name = "odbc",
                .path = .{ .path = "zdb/zig-odbc/src/lib.zig" },
            }
        }
    };

    exe.addPackage(self_pkg);
}

pub fn buildPkgPath(exe: *LibExeObjStep, package_name: []const u8, path_to_zdb: []const u8) !void {
    exe.linkLibC();

    const odbc_library_name = if (builtin.os.tag == .windows) "odbc32" else "odbc";
    if (builtin.os.tag == .macos) {
        exe.addIncludeDir("/usr/local/include");
        exe.addIncludeDir("/usr/local/lib");
    }

    var zdb_src_buf: [200]u8 = undefined;
    const zdb_src_path = try std.fmt.bufPrint(&zdb_src_buf, "{s}/src/zdb.zig", .{path_to_zdb});

    var zdb_odbc_src_buf: [200]u8 = undefined;
    const zdb_odbc_src_path = try std.fmt.bufPrint(&zdb_odbc_src_buf, "{s}/zig-odbc/src/lib.zig", .{path_to_zdb});

    exe.linkSystemLibrary(odbc_library_name);

    const self_pkg = Pkg{
        .name = exe.builder.dupe(package_name), 
        .path = .{ .path = exe.builder.dupe(zdb_src_path) },
        .dependencies = &.{
            // @todo Not sure why this (dupePkg) is needed now but without it we get a segfault when trying to build
            exe.builder.dupePkg(Pkg{
                .name = "odbc",
                .path = .{ .path = exe.builder.dupe(zdb_odbc_src_path) },
            })
        }
    };

    exe.addPackage(self_pkg);
}
