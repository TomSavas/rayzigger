const std = @import("std");
const zmath = @import("libs/zmath/build.zig");
const zmesh = @import("libs/zmesh/build.zig");
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
    const mode = b.standardReleaseOptions();

    const sdk = sdl_sdk.init(b);

    const exe = b.addExecutable("rayzigger", "src/main.zig");

    exe.addCSourceFile("libs/stb_image/stb_image_impl.c", &[_][]const u8{"-std=c99"});
    exe.addIncludeDir("libs/stb_image");

    exe.setTarget(target);
    exe.setBuildMode(mode);

    sdk.link(exe, .dynamic);

    const exe_options = b.addOptions();
    exe.addOptions(options_pkg_name, exe_options);

    const zmesh_options = zmesh.BuildOptionsStep.init(b, .{});
    const zmesh_pkg = zmesh.getPkg(&.{zmesh_options.getPkg()});
    exe.addPackage(zmesh_pkg);
    zmesh.link(exe, zmesh_options);

    exe.addPackage(zmath.pkg);
    exe.addPackage(sdk.getWrapperPackage("sdl2"));

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
