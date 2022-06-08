const std = @import("std");
const zm = @import("zmath");
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
const Ray = @import("ray.zig").Ray;
const Hit = @import("ray.zig").Hit;
const Material = @import("materials.zig").Material;
const LambertianMat = @import("materials.zig").LambertianMat;
const MetalMat = @import("materials.zig").MetalMat;
const DielectricMat = @import("materials.zig").DielectricMat;

const RenderThread = @import("render_thread.zig");
const Camera = @import("camera.zig").Camera;
const Chunk = @import("render_thread.zig").Chunk;
const RenderThreadCtx = @import("render_thread.zig").RenderThreadCtx;
const Ppm = @import("ppm.zig");
const Settings = @import("settings.zig").Settings;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var settings = Settings.init(allocator);
    defer settings.deinit();

    const cameraPos = Vector(4, f32){ 13.0, 2.0, 3.0, 0.0 };
    const lookTarget = Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 };
    var camera = Camera.init(cameraPos, lookTarget, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 }, PI / 2.0, settings.aspectRatio, 0.0, 10.0);

    const materialCount = 16;
    var diffuseMats: [materialCount]LambertianMat = undefined;
    var metalMats: [materialCount]MetalMat = undefined;
    var dielectricMats: [materialCount]DielectricMat = undefined;
    {
        var rng = DefaultRandom.init(0).random();

        var materialIndex: u32 = 0;
        while (materialIndex < materialCount) : (materialIndex += 1) {
            diffuseMats[materialIndex] = LambertianMat.init(Vector(3, f32){ 0.1 + rng.float(f32) * 0.9, 0.1 + rng.float(f32) * 0.9, 0.1 + rng.float(f32) * 0.9 });
            metalMats[materialIndex] = MetalMat.init(Vector(3, f32){ 0.1 + rng.float(f32) * 0.9, 0.1 + rng.float(f32) * 0.9, 0.1 + rng.float(f32) * 0.9 }, rng.float(f32) * 0.4);
            dielectricMats[materialIndex] = DielectricMat.init(Vector(3, f32){ 0.6 + rng.float(f32) * 0.4, 0.6 + rng.float(f32) * 0.4, 0.6 + rng.float(f32) * 0.4 }, 1.5);
        }
    }

    const sphereCount = 256 + 4;
    var spheres: []Sphere = try allocator.alloc(Sphere, sphereCount);
    defer allocator.free(spheres);

    const dielectricMat = DielectricMat.init(Vector(3, f32){ 1.0, 1.0, 1.0 }, 1.5);
    spheres[0] = Sphere.init(&dielectricMat.material, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 }, 1.0);
    const bronzeMetalMat = MetalMat.init(Vector(3, f32){ 0.7, 0.5, 0.1 }, 0.0);
    spheres[2] = Sphere.init(&bronzeMetalMat.material, Vector(4, f32){ 4.0, 1.0, 0.0, 0.0 }, 1.0);
    const greyDiffuseMat = LambertianMat.init(Vector(3, f32){ 0.5, 0.5, 0.5 });
    spheres[1] = Sphere.init(&greyDiffuseMat.material, Vector(4, f32){ -4.0, 1.0, 0.0, 0.0 }, 1.0);
    const greenDiffuseMat = LambertianMat.init(Vector(3, f32){ 0.35, 0.6, 0.2 });
    spheres[3] = Sphere.init(&greenDiffuseMat.material, Vector(4, f32){ 0.0, -2000.0, 0.0, 0.0 }, 2000);
    {
        var rng = DefaultRandom.init(0).random();

        var sphereIndex: u32 = 4;
        var x: f32 = 16 + 1;
        while (x > 1) {
            x -= 1;

            var z: f32 = 16 + 1;
            while (z > 1) {
                z -= 1;

                var radius = 0.05 + rng.float(f32) * 0.2;
                var randomPos = Vector(4, f32){ (x + (rng.float(f32) - 0.5) - 12.0) * 2, radius, z + (rng.float(f32) - 0.5) - 8.0 };

                const materialIndex = @floatToInt(u32, @round(rng.float(f32) * (materialCount - 1)));
                var material = switch (rng.float(f32)) {
                    0.0...0.5 => &diffuseMats[materialIndex].material,
                    0.5...0.8 => &metalMats[materialIndex].material,
                    else => &dielectricMats[materialIndex].material,
                };
                spheres[sphereIndex] = Sphere.init(material, randomPos, radius);

                sphereIndex += 1;
            }
        }
    }

    var accumulatedPixels: []Vector(3, f32) = try allocator.alloc(Vector(3, f32), settings.pixelCount);
    defer allocator.free(accumulatedPixels);
    std.mem.set(Vector(3, f32), accumulatedPixels, Vector(3, f32){ 0.0, 0.0, 0.0 });

    const threadCount = 10;
    var renderThreads = try RenderThread.RenderThreads.init(threadCount, allocator, &settings, &camera, accumulatedPixels, spheres);
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
                if (isChunkRendering and isBorderingPixel and settings.spp > 16) {
                    borderColor[0] = 1 - color[0];
                    borderColor[1] = 0 - color[1];
                    borderColor[2] = 0 - color[2];
                }

                // Invert the y... Different coordinate systems like always
                var pixels = pixel_data.scanline(settings.size[1] - y, u8);

                pixels[x * 4 + 0] = @truncate(u8, @floatToInt(u32, pow(f32, color[0] + borderColor[0], 1.0 / settings.gamma) * 255));
                pixels[x * 4 + 1] = @truncate(u8, @floatToInt(u32, pow(f32, color[1] + borderColor[1], 1.0 / settings.gamma) * 255));
                pixels[x * 4 + 2] = @truncate(u8, @floatToInt(u32, pow(f32, color[2] + borderColor[2], 1.0 / settings.gamma) * 255));
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
