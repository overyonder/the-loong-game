const std = @import("std");

// The wasmtime C API comes from the nix dev shell (WASMTIME_INCLUDE and
// WASMTIME_LIB), or from the -Dwasmtime-include / -Dwasmtime-lib options.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_dir = b.option([]const u8, "wasmtime-include", "wasmtime C API include directory") orelse
        b.graph.environ_map.get("WASMTIME_INCLUDE") orelse @panic("set WASMTIME_INCLUDE or -Dwasmtime-include");
    const lib_dir = b.option([]const u8, "wasmtime-lib", "directory holding libwasmtime") orelse
        b.graph.environ_map.get("WASMTIME_LIB") orelse @panic("set WASMTIME_LIB or -Dwasmtime-lib");

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root.addIncludePath(.{ .cwd_relative = include_dir });
    root.addLibraryPath(.{ .cwd_relative = lib_dir });
    root.addRPath(.{ .cwd_relative = lib_dir });
    root.linkSystemLibrary("wasmtime", .{ .preferred_link_mode = .static });
    // The lockstep mode's second engine: our port of the organisers' engine.
    root.addIncludePath(b.path("../engine"));
    root.addCSourceFile(.{ .file = b.path("../engine/host.cc"), .flags = &.{ "-std=c++20", "-O2" } });
    root.link_libcpp = true;
    root.linkSystemLibrary("unwind", .{ .preferred_link_mode = .static });

    const exe = b.addExecutable(.{
        .name = "loong-judge",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the judge");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
