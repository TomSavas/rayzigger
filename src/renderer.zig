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

const args = @import("args");

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

const Scene = @import("scenes.zig").Scene;

const Model = @import("model.zig").Model;

fn luminance(color: Vector(3, f32)) f32 {
    return color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
}

fn tonemapReinhardLuminance(color: Vector(3, f32), maxLuminance: f32) Vector(3, f32) {
    var l = luminance(color);

    var tonemappedReinhardLuminance = l * (1 + (l / (maxLuminance * maxLuminance)));
    tonemappedReinhardLuminance /= 1.0 + l;

    // Remapping luminance
    return color * @splat(3, tonemappedReinhardLuminance / (l + 0.0000001));
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    settings: *Settings,

    pixels: []Vector(3, f32),
    renderThreads: RenderThread.RenderThreads,

    pub fn init(allocator: std.mem.Allocator, settings: *Settings) anyerror!Renderer {
        var pixels: []Vector(3, f32) = try allocator.alloc(Vector(3, f32), settings.pixelCount);
        std.mem.set(Vector(3, f32), pixels, Vector(3, f32){ 0.0, 0.0, 0.0 });

        return Renderer{ .allocator = allocator, .settings = settings, .pixels = pixels, .renderThreads = undefined };
    }

    pub fn deinit(self: *Renderer) void {
        _ = self;
    }

    pub fn reset(self: *Renderer) void {
        _ = self;
    }

    pub fn headlessRender(self: *Renderer, scene: *Scene) anyerror!void {
        print("Utilising {any} threads\n", .{self.settings.cmdSettings.threads});

        var renderThreads = try RenderThread.RenderThreads.init(self.settings.cmdSettings.threads orelse 1, self.allocator, self.settings, &scene.camera, self.pixels, scene.models.items[0].bvh);
        renderThreads.blockUntilDone();
    }

    pub fn render(self: *Renderer, scene: *Scene) anyerror!void {
        print("Utilising {any} threads\n", .{self.settings.cmdSettings.threads});

        var renderThreads = try RenderThread.RenderThreads.init(self.settings.cmdSettings.threads orelse 1, self.allocator, self.settings, &scene.camera, self.pixels, scene.models.items[0].bvh);
        defer renderThreads.deinit();

        // TODO: reallocate pixels if size has changed

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
            //settings.size[0],
            //settings.size[1],
            1920,
            1080,
            .{},
        );
        defer window.destroy();

        var sdlRenderer = try SDL.createRenderer(window, null, .{ .accelerated = true });
        defer sdlRenderer.destroy();
        var texture = try SDL.createTexture(sdlRenderer, SDL.PixelFormatEnum.abgr8888, SDL.Texture.Access.streaming, self.settings.size[0], self.settings.size[1]);

        mainLoop: while (true) {
            while (SDL.pollEvent()) |ev| {
                switch (ev) {
                    .quit => break :mainLoop,
                    else => {
                        if (scene.camera.handleInputEvent(ev)) {
                            RenderThread.invalidationSignal = true;
                            std.time.sleep(@floatToInt(u64, 1 * 10000.0));
                            RenderThread.invalidationSignal = false;
                        } else if (ev == .key_down and ev.key_down.keycode == .p) {
                            print("pos: {}\n", .{scene.camera.origin});
                            try Ppm.outputImage(self.settings.size, self.pixels, self.settings.cmdSettings.gamma);
                        }
                    },
                }
            }

            try sdlRenderer.setColorRGB(0xA0, 0xA0, 0xA0);
            try sdlRenderer.clear();

            var pixel_data = try texture.lock(null);
            defer pixel_data.release();

            var maxLuminance = std.math.inf(f32);
            var y: usize = self.settings.size[1];
            while (y > 0) {
                y -= 1;
                var x: usize = 0;
                while (x < self.settings.size[0]) : (x += 1) {
                    var i = y * self.settings.cmdSettings.width + x;
                    var color = self.pixels[i];
                    maxLuminance = @max(luminance(color), maxLuminance);
                }
            }

            y = self.settings.size[1];
            while (y > 0) {
                y -= 1;
                var x: usize = 0;
                while (x < self.settings.size[0]) : (x += 1) {
                    var i = y * self.settings.cmdSettings.width + x;
                    var chunkCol = @divTrunc(@intCast(u32, x), self.settings.cmdSettings.chunkSize);
                    var chunkRow = @divTrunc(@intCast(u32, y), self.settings.cmdSettings.chunkSize);
                    var chunkIndex = chunkCol + chunkRow * self.settings.chunkCountAlongAxis[0];

                    var isChunkRendering = self.settings.chunks[chunkIndex].isProcessingReadonly;
                    var isBorderingPixel = x == chunkCol * self.settings.cmdSettings.chunkSize or x == (chunkCol + 1) * (self.settings.cmdSettings.chunkSize) - 1;
                    isBorderingPixel = isBorderingPixel or y == chunkRow * self.settings.cmdSettings.chunkSize or y == (chunkRow + 1) * self.settings.cmdSettings.chunkSize - 1;

                    var borderColor = Vector(3, f32){ 1.0, 0.0, 0.0 };
                    var color = borderColor;
                    if (!isChunkRendering or !isBorderingPixel or self.settings.cmdSettings.sppPerPass < 16) {
                        var tonemappedColor = tonemapReinhardLuminance(self.pixels[i], maxLuminance);
                        tonemappedColor = @min(tonemappedColor, Vector(3, f32){ 1.0, 1.0, 1.0 });

                        if (self.settings.cmdSettings.gamma == 2.0) {
                            color = @sqrt(tonemappedColor);
                        } else {
                            var gammaExponent = 1.0 / self.settings.cmdSettings.gamma;
                            color[0] = pow(f32, tonemappedColor[0], gammaExponent);
                            color[1] = pow(f32, tonemappedColor[1], gammaExponent);
                            color[2] = pow(f32, tonemappedColor[2], gammaExponent);
                        }
                    }

                    // Invert the y... Different coordinate systems like always
                    var pixels = pixel_data.scanline(self.settings.size[1] - y - 1, u8);
                    pixels[x * 4 + 0] = @truncate(u8, @floatToInt(u32, color[0] * 255));
                    pixels[x * 4 + 1] = @truncate(u8, @floatToInt(u32, color[1] * 255));
                    pixels[x * 4 + 2] = @truncate(u8, @floatToInt(u32, color[2] * 255));
                    pixels[x * 4 + 3] = 0;
                }
            }

            try sdlRenderer.copy(texture, null, null);
            sdlRenderer.present();

            const frametime_ms: f32 = 16.666;
            std.time.sleep(@floatToInt(u64, frametime_ms * 1000000.0));
        }
    }

    pub fn screenshot(self: *Renderer, path: []const u8) void {
        _ = self;
        _ = path;
    }
};
