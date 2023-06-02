const std = @import("std");
const builtin = @import("builtin");
const CompileStep = std.build.CompileStep;

pub fn buildPkg(b: *std.Build, exe: *CompileStep, package_name: []const u8, zdb_path: []const u8) !void {
    exe.linkLibC();

    const odbc_library_name = if (builtin.os.tag == .windows) "odbc32" else "odbc";
    if (builtin.os.tag == .macos) {
        exe.addIncludeDir("/usr/local/include");
        exe.addIncludeDir("/usr/local/lib");
    }

    exe.linkSystemLibrary(odbc_library_name);

    const allocator = b.allocator;

    const zdb_root = try std.fmt.allocPrint(allocator, "{s}/src/zdb.zig", .{zdb_path});
    const zig_odbc_root = try std.fmt.allocPrint(allocator, "{s}/zig-odbc/src/lib.zig", .{zdb_path});

    const module = b.createModule(.{
        .source_file = .{ .path = zdb_root },
        .dependencies = &[_]std.Build.ModuleDependency{
            .{
                .name = "odbc",
                .module = b.createModule(.{
                    .source_file = .{ .path = zig_odbc_root },
                }),
            },
        },
    });

    exe.addModule(package_name, module);
}
