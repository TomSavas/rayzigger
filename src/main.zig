const std = @import("std");
const zm = @import("zmath");
const zmesh = @import("zmesh");
const SDL = @import("sdl2");
const pow = std.math.pow;
const PI = std.math.pi;
const print = std.debug.print;
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
const LambertianTexMat = @import("materials.zig").LambertianTexMat;
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

fn luminance(color: Vector(3, f32)) f32 {
    return color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
}

fn tonemapReinhardLuminance(color: Vector(3, f32), maxLuminance: f32) Vector(3, f32) {
    var l = luminance(color);

    var tonemappedReinhardLuminance = l * (1 + (l / (maxLuminance * maxLuminance)));
    tonemappedReinhardLuminance /= 1.0 + l;

    // Remapping luminance
    return color * @splat(3, tonemappedReinhardLuminance / l);
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    zmesh.init(allocator);
    defer zmesh.deinit();

    var settings = try Settings.init(allocator);
    defer settings.deinit();

    const cameraPos = Vector(4, f32){ -1.87689530e+00, 1.54253983e+00, -4.15354937e-01, 0.0e+00 };
    const lookTarget = Vector(4, f32){ 0.0, 2, 0.0, 0.0 };
    var camera = Camera.init(cameraPos, lookTarget, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 }, PI / 2.0, settings.aspectRatio, 0.0, 10.0);
    camera.recalculateRotation();

    const defaultMat = DielectricMat.init(Vector(3, f32){ 0.85, 0.5, 0.1 }, 1.5);
    //const defaultMat = LambertianMat.init(.{ 0.3, 0.3, 0.5 });

    //var model = try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/GearboxAssy/glTF/GearboxAssy.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/DragonAttenuation/glTF/DragonAttenuation.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/SciFiHelmet/glTF/SciFiHelmet.gltf");
    var model = try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/Sponza/glTF/Sponza.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Atlas.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Complex.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Complex_SeparateTex.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/box/Box.gltf");
    //var model = try Model.init(allocator, &defaultMat.material, "assets/suzanne/Suzanne.gltf");
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
        .{},
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
                        print("pos: {}\n", .{camera.origin});
                        try Ppm.outputImage(settings.size, accumulatedPixels, settings.gamma);
                    }
                },
            }
        }

        try renderer.setColorRGB(0xA0, 0xA0, 0xA0);
        try renderer.clear();

        var pixel_data = try texture.lock(null);
        defer pixel_data.release();

        var maxLuminance = std.math.inf(f32);
        var y: usize = settings.size[1];
        while (y > 0) {
            y -= 1;
            var x: usize = 0;
            while (x < settings.size[0]) : (x += 1) {
                var i = y * settings.width + x;
                var color = accumulatedPixels[i];
                maxLuminance = @max(luminance(color), maxLuminance);
            }
        }

        y = settings.size[1];
        while (y > 0) {
            y -= 1;
            var x: usize = 0;
            while (x < settings.size[0]) : (x += 1) {
                var i = y * settings.width + x;
                var chunkCol = @divTrunc(@intCast(u32, x), settings.chunkSize[0]);
                var chunkRow = @divTrunc(@intCast(u32, y), settings.chunkSize[1]);
                var chunkIndex = chunkCol + chunkRow * settings.chunkCountAlongAxis[0];

                var isChunkRendering = settings.chunks[chunkIndex].isProcessingReadonly;
                var isBorderingPixel = x == chunkCol * settings.chunkSize[0] or x == (chunkCol + 1) * (settings.chunkSize[0]) - 1;
                isBorderingPixel = isBorderingPixel or y == chunkRow * settings.chunkSize[1] or y == (chunkRow + 1) * settings.chunkSize[1] - 1;

                var borderColor = Vector(3, f32){ 1.0, 0.0, 0.0 };
                var color = borderColor;
                if (!isChunkRendering or !isBorderingPixel or settings.spp < 16) {
                    var tonemappedColor = tonemapReinhardLuminance(accumulatedPixels[i], maxLuminance);
                    tonemappedColor = @min(tonemappedColor, Vector(3, f32){ 1.0, 1.0, 1.0 });

                    if (settings.gamma == 2.0) {
                        color = @sqrt(tonemappedColor);
                    } else {
                        var gammaExponent = 1.0 / settings.gamma;
                        color[0] = pow(f32, tonemappedColor[0], gammaExponent);
                        color[1] = pow(f32, tonemappedColor[1], gammaExponent);
                        color[2] = pow(f32, tonemappedColor[2], gammaExponent);
                    }
                }

                // Invert the y... Different coordinate systems like always
                var pixels = pixel_data.scanline(settings.size[1] - y - 1, u8);
                pixels[x * 4 + 0] = @truncate(u8, @floatToInt(u32, color[0] * 255));
                pixels[x * 4 + 1] = @truncate(u8, @floatToInt(u32, color[1] * 255));
                pixels[x * 4 + 2] = @truncate(u8, @floatToInt(u32, color[2] * 255));
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
