const cTime = @cImport(@cInclude("time.h"));
const std = @import("std");
const zmesh = @import("zmesh");
const print = std.debug.print;
const scenes = @import("scenes.zig");
const comptimeUtils = @import("comptime_utils.zig");

const Scene = scenes.Scene;
const Settings = @import("settings.zig").Settings;
const Renderer = @import("renderer.zig").Renderer;

pub const BenchmarkResult = struct {
    scene: []const u8,
    times: std.StringHashMap(f64),
    resultFilenamePrefix: []const u8,

    pub fn writeToDisk(self: *const BenchmarkResult, renderer: *Renderer) anyerror!void {
        var buf: [1024]u8 = undefined;
        var fixedAllocator = std.heap.FixedBufferAllocator.init(&buf);
        var allocator = fixedAllocator.allocator();

        const unitTime = formattedTime: {
            // TODO: remove C dependency once Zig has it's own time formatter
            var timeBuf: [32]u8 = undefined;
            const localTime = cTime.localtime(&std.time.timestamp());
            const timeLength = cTime.strftime(@ptrCast([*c]u8, @alignCast(@alignOf(u8), &timeBuf)), 32, "%Y_%m_%d-%H:%M:%S", localTime);
            break :formattedTime try std.fmt.allocPrint(allocator, "{s}", .{timeBuf[0..timeLength]});
        };
        const benchPath = try std.fs.path.join(allocator, &.{ "./benchmarks", unitTime });
        try std.fs.cwd().makePath(benchPath);

        {
            const resultFilename = try std.mem.concat(allocator, u8, &.{ self.resultFilenamePrefix, ".bench.csv" });
            const resultPath = try std.fs.path.join(allocator, &.{ benchPath, resultFilename });
            print("Writing benchmark info to: {s}\n", .{resultPath});

            const file = try std.fs.cwd().createFile(
                resultPath,
                .{ .read = true },
            );
            var writer = file.writer();
            defer file.close();

            var timesIt = self.times.iterator();
            while (timesIt.next()) |entry| {
                try writer.print("{s}, {s}, {d}\n", .{ self.scene, entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        {
            const screenshotFilename = try std.mem.concat(allocator, u8, &.{ self.resultFilenamePrefix, ".ppm" });
            const screenshotPath = try std.fs.path.join(allocator, &.{ benchPath, screenshotFilename });
            print("Writing screenshot     to: {s}\n", .{screenshotPath});

            const file = try std.fs.cwd().createFile(
                screenshotPath,
                .{ .read = true },
            );
            defer file.close();
            try renderer.ppmScreenshot(&file);
        }
    }
};

pub fn benchmark(allocator: std.mem.Allocator, scene: *Scene, renderer: *Renderer) anyerror!BenchmarkResult {
    var result = BenchmarkResult{ .scene = scene.title, .times = std.StringHashMap(f64).init(allocator), .resultFilenamePrefix = scene.title };

    print("--------------------\n", .{});
    print("Benchmarking scene: {s}\n", .{scene.title});

    var timer = try std.time.Timer.start();
    try scene.buildBlases();
    const blasBuildTime = timer.lap();
    try scene.buildTlas();
    const tlasBuildTime = timer.lap();
    // Assumes we're in a non-interactive mode and terminate after rendering
    try renderer.headlessRender(scene);
    const renderTime = timer.lap();

    try result.times.put("blas", @intToFloat(f64, blasBuildTime) / 1000000.0);
    try result.times.put("tlas", @intToFloat(f64, tlasBuildTime) / 1000000.0);
    try result.times.put("as", @intToFloat(f64, blasBuildTime + tlasBuildTime) / 1000000.0);
    try result.times.put("render", @intToFloat(f64, renderTime) / 1000000.0);

    var timesIt = result.times.iterator();
    while (timesIt.next()) |entry| {
        print("{s:20} {d:.3}ms\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    return result;
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    zmesh.init(allocator);
    defer zmesh.deinit();

    var settings = try Settings.init(allocator);
    defer settings.deinit();

    var renderer = try Renderer.init(allocator, &settings);
    defer renderer.deinit();

    if (settings.cmdSettings.benchmark) |benchMode| {
        if (settings.cmdSettings.targetSpp == null) {
            settings.cmdSettings.targetSpp = 128;
            print("No targetSpp set in benchmark mode. Defaulting to {} spp.\n", .{settings.cmdSettings.targetSpp.?});
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        var arenaAllocator = arena.allocator();

        var sceneConstructors = switch (benchMode) {
            .dev => &([_]*const fn (std.mem.Allocator) anyerror!Scene{scenes.devScene}),
            .full => comptime comptimeUtils.getFuncsWithReturnType(@import("scenes.zig"), std.mem.Allocator, anyerror!Scene),
        };

        for (sceneConstructors) |sceneConstructor| {
            _ = arena.reset(.free_all);

            var scene = try sceneConstructor(arenaAllocator);
            defer scene.deinit();

            renderer.reset();
            const benchmarkResult = try benchmark(arenaAllocator, &scene, &renderer);
            try benchmarkResult.writeToDisk(&renderer);
        }
    } else {
        var defaultScene = try scenes.devScene(allocator);
        defer defaultScene.deinit();

        try defaultScene.buildFully();
        try renderer.render(&defaultScene);
    }
}
