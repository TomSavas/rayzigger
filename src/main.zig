const std = @import("std");
const zm = @import("zmath");
const zmesh = @import("zmesh");
const SDL = @import("sdl2");
const pow = std.math.pow;
const PI = std.math.pi;
const print = std.io.getStdOut().writer().print;
const printErr = std.io.getStdErr().writer().print;
const Vector = std.meta.Vector;
const Random = std.rand.Random;
const DefaultRandom = std.rand.DefaultPrng;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const OS = std.os;
const Mutex = Thread.Mutex;

const Sphere = @import("hittables.zig").Sphere;
const Triangle = @import("hittables.zig").Triangle;
const Ray = @import("ray.zig").Ray;
const Hit = @import("ray.zig").Hit;
const Material = @import("materials.zig").Material;
const LambertianMat = @import("materials.zig").LambertianMat;
const MetalMat = @import("materials.zig").MetalMat;
const DielectricMat = @import("materials.zig").DielectricMat;
const EmissiveMat = @import("materials.zig").EmissiveMat;

const RenderThread = @import("render_thread.zig");
const Camera = @import("camera.zig").Camera;
const Chunk = @import("render_thread.zig").Chunk;
const RenderThreadCtx = @import("render_thread.zig").RenderThreadCtx;
const Ppm = @import("ppm.zig");
const Settings = @import("settings.zig").Settings;

const BaryMat = @import("hittables.zig").BarycentricMat;
const BVH = @import("bvh.zig");

const Model = @import("model.zig").Model;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    zmesh.init(allocator);
    defer zmesh.deinit();

    var settings = Settings.init(allocator);
    defer settings.deinit();

    const cameraPos = Vector(4, f32){ 0.0, 3.0, 6.0, 0.0 };
    const lookTarget = Vector(4, f32){ 0.0, 2.0, 0.0, 0.0 };
    var camera = Camera.init(cameraPos, lookTarget, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 }, PI / 2.0, settings.aspectRatio, 0.0, 10.0);
    camera.recalculateRotation();

    const greyDiffuseMat = LambertianMat.init(Vector(3, f32){ 0.5, 0.5, 0.5 });
    var model = Model.init(allocator, &greyDiffuseMat.material, "assets/suzanne/Suzanne.gltf");
    defer model.deinit();

    var accumulatedPixels: []Vector(3, f32) = try allocator.alloc(Vector(3, f32), settings.pixelCount);
    defer allocator.free(accumulatedPixels);
    std.mem.set(Vector(3, f32), accumulatedPixels, Vector(3, f32){ 0.0, 0.0, 0.0 });

    const threadCount = 10;
    var renderThreads = try RenderThread.RenderThreads.init(threadCount, allocator, &settings, &camera, accumulatedPixels, model.bvh);
    defer renderThreads.deinit();

    try SDL.init(.{
        .video = true,
        .events = true,
        .audio = true,
    });
    defer SDL.quit();

    var window = try SDL.createWindow(
        "Rayzigger",
        .{ .centered = {} },
        .{ .centered = {} },
        settings.size[0],
        settings.size[1],
        .{ .shown = true, .resizable = true },
        //.{ .shown = true },
    );
    defer window.destroy();

    var renderer = try SDL.createRenderer(window, null, .{ .accelerated = true });
    defer renderer.destroy();
    var texture = try SDL.createTexture(renderer, SDL.PixelFormatEnum.abgr8888, SDL.Texture.Access.streaming, settings.size[0], settings.size[1]);

    mainLoop: while (true) {
        while (SDL.pollEvent()) |ev| {
            switch (ev) {
                .quit => break :mainLoop,
                else => {
                    if (camera.handleInputEvent(ev)) {
                        RenderThread.invalidationSignal = true;
                        std.time.sleep(@floatToInt(u64, 1 * 10000.0));
                        RenderThread.invalidationSignal = false;
                    } else if (ev == .key_down and ev.key_down.keycode == .p) {
                        try print("pos: {}\n", .{camera.origin});
                        try Ppm.outputImage(settings.size, accumulatedPixels, settings.gamma);
                    }
                },
            }
        }

        try renderer.setColorRGB(0xA0, 0xA0, 0xA0);
        try renderer.clear();

        var pixel_data = try texture.lock(null);
        defer pixel_data.release();

        var y: usize = settings.size[1];
        while (y > 0) {
            y -= 1;
            var x: usize = 0;
            while (x < settings.size[0]) : (x += 1) {
                var i = y * settings.width + x;
                var color = accumulatedPixels[i];

                var chunkCol = @divTrunc(@intCast(u32, x), settings.chunkSize[0]);
                var chunkRow = @divTrunc(@intCast(u32, y), settings.chunkSize[1]);
                var chunkIndex = chunkCol + chunkRow * settings.chunkCountAlongAxis;

                var isChunkRendering = settings.chunks[chunkIndex].isProcessingReadonly;
                var isBorderingPixel = x == chunkCol * settings.chunkSize[0] or x == (chunkCol + 1) * (settings.chunkSize[0]) - 1;
                isBorderingPixel = isBorderingPixel or y == chunkRow * settings.chunkSize[1] or y == (chunkRow + 1) * settings.chunkSize[1] - 1;

                var borderColor = Vector(3, f32){ 0.0, 0.0, 0.0 };
                if (isChunkRendering and isBorderingPixel and settings.spp >= 16) {
                    borderColor[0] = 1 - color[0];
                    borderColor[1] = 0 - color[1];
                    borderColor[2] = 0 - color[2];
                }

                // Invert the y... Different coordinate systems like always
                var pixels = pixel_data.scanline(settings.size[1] - y, u8);

                pixels[x * 4 + 0] = @truncate(u8, @floatToInt(u32, pow(f32, @minimum(color[0], 1.0) + borderColor[0], 1.0 / settings.gamma) * 255));
                pixels[x * 4 + 1] = @truncate(u8, @floatToInt(u32, pow(f32, @minimum(color[1], 1.0) + borderColor[1], 1.0 / settings.gamma) * 255));
                pixels[x * 4 + 2] = @truncate(u8, @floatToInt(u32, pow(f32, @minimum(color[2], 1.0) + borderColor[2], 1.0 / settings.gamma) * 255));
                pixels[x * 4 + 3] = 0;
            }
        }

        try renderer.copy(texture, null, null);
        renderer.present();

        const frametime_ms: f32 = 16.666;
        std.time.sleep(@floatToInt(u64, frametime_ms * 1000000.0));
    }
}

fn sdlPanic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";
    @panic(std.mem.sliceTo(str, 0));
}
