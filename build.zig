const std = @import("std");
const zmath = @import("libs/zmath/build.zig");
const zmesh = @import("libs/zmesh/build.zig");
const zigargs = @import("libs/zig-args/build.zig");
const sdl_sdk = @import("libs/SDL.zig/Sdk.zig");

const options_pkg_name = "build_options";
const use_32bit_indices = false;

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const sdk = sdl_sdk.init(b, null);

    const exe = b.addExecutable(.{
        .name = "rayzigger",
        .root_source_file = .{ .path = "./src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.addCSourceFile(std.Build.LibExeObjStep.CSourceFile{
        .file = std.Build.FileSource.relative("libs/stb_image/stb_image_impl.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });
    exe.addIncludePath(std.Build.FileSource.relative("libs/stb_image"));

    sdk.link(exe, .dynamic);

    const exe_options = b.addOptions();
    exe.addOptions(options_pkg_name, exe_options);

    const zmesh_pkg = zmesh.package(b, target, optimize, .{});
    //exe.addModule("zmesh", zmesh_pkg.zmesh);
    zmesh_pkg.link(exe);

    const zmath_pkg = zmath.package(b, target, optimize, .{
        .options = .{ .enable_cross_platform_determinism = true },
    });
    //exe.addModule("zmath", zmath_pkg.zmath);
    zmath_pkg.link(exe);

    exe.addModule("sdl2", sdk.getWrapperModule());

    const zigargs_mod = b.createModule(.{
        .source_file = .{ .path = "./libs/zig-args/args.zig" },
        .dependencies = &.{},
    });
    exe.addModule("args", zigargs_mod);

    b.installArtifact(exe);
    //exe.installArtifact();

    //const run_cmd = exe.run();
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
