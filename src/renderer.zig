const std = @import("std");
const zm = @import("zmath");
const zmesh = @import("zmesh");
const SDL = @import("sdl2");
const pow = std.math.pow;
const PI = std.math.pi;
const print = std.debug.print;
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
const Settings = @import("settings.zig").Settings;

const BaryMat = @import("hittables.zig").BarycentricMat;
const BVH = @import("bvh.zig");

const Scene = @import("scenes.zig").Scene;

const Model = @import("model.zig").Model;

fn luminance(color: @Vector(3, f32)) f32 {
    return color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
}

fn tonemapReinhardLuminance(color: @Vector(3, f32), maxLuminance: f32) @Vector(3, f32) {
    var l = luminance(color);

    var tonemappedReinhardLuminance = l * (1 + (l / (maxLuminance * maxLuminance)));
    tonemappedReinhardLuminance /= (1.0 + l);

    // Remapping luminance
    return color * @as(@Vector(3, f32), @splat(tonemappedReinhardLuminance / (l + 0.0000001)));
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    settings: *Settings,

    hitWorldLocations: [2][]@Vector(4, f32),
    pixels: [2][]@Vector(3, f32),
    sampleCounts: [2][]u32,
    renderThreads: RenderThread.RenderThreads,

    pub fn init(allocator: std.mem.Allocator, settings: *Settings) anyerror!Renderer {
        var pixels: [2][]@Vector(3, f32) = .{ try allocator.alloc(@Vector(3, f32), settings.pixelCount), try allocator.alloc(@Vector(3, f32), settings.pixelCount) };
        @memset(pixels[0], @Vector(3, f32){ 0.0, 0.0, 0.0 });
        @memset(pixels[1], @Vector(3, f32){ 0.0, 0.0, 0.0 });
        var hitWorldLocations: [2][]@Vector(4, f32) = .{ try allocator.alloc(@Vector(4, f32), settings.pixelCount), try allocator.alloc(@Vector(4, f32), settings.pixelCount) };
        @memset(hitWorldLocations[0], @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 });
        @memset(hitWorldLocations[1], @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 });
        var sampleCounts: [2][]u32 = .{ try allocator.alloc(u32, settings.pixelCount), try allocator.alloc(u32, settings.pixelCount) };
        @memset(sampleCounts[0], 0);
        @memset(sampleCounts[1], 0);

        return Renderer{ .allocator = allocator, .settings = settings, .pixels = pixels, .hitWorldLocations = hitWorldLocations, .sampleCounts = sampleCounts, .renderThreads = undefined };
    }

    pub fn deinit(self: *Renderer) void {
        _ = self;
    }

    pub fn reset(self: *Renderer) void {
        _ = self;
    }

    pub fn headlessRender(self: *Renderer, scene: *Scene) anyerror!void {
        print("Utilising {any} threads\n", .{self.settings.cmdSettings.threads});

        var renderThreads = try RenderThread.RenderThreads.init(self.settings.cmdSettings.threads orelse 1, self.allocator, self.settings, &scene.camera, &self.pixels, &self.hitWorldLocations, &self.sampleCounts, scene.tlas);
        renderThreads.blockUntilDone();
    }

    pub fn render(self: *Renderer, scene: *Scene) anyerror!void {
        print("Utilising {any} threads\n", .{self.settings.cmdSettings.threads});

        var renderThreads = try RenderThread.RenderThreads.init(self.settings.cmdSettings.threads orelse 1, self.allocator, self.settings, &scene.camera, &self.pixels, &self.hitWorldLocations, &self.sampleCounts, scene.tlas);
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

        var frameCounter: u64 = 0;
        mainLoop: while (true) {
            const frameStartTime = std.time.nanoTimestamp();

            if (@mod(frameCounter, 2) == 0) {
                while (SDL.pollEvent()) |ev| {
                    switch (ev) {
                        .quit => break :mainLoop,
                        else => {
                            if (scene.camera.handleInputEvent(ev)) {
                                RenderThread.invalidationSignal = true;
                                std.time.sleep(@as(u64, @intFromFloat(1000.0)));
                                RenderThread.invalidationSignal = false;
                            }
                        },
                    }
                }
            }
            frameCounter += 1;

            var pixel_data = try texture.lock(null);
            defer pixel_data.release();

            var maxLuminance: f32 = 0.0;
            var y: usize = self.settings.size[1];
            while (y > 0) {
                y -= 1;
                var x: usize = 0;
                while (x < self.settings.size[0]) : (x += 1) {
                    var i = y * self.settings.cmdSettings.width + x;
                    var chunkCol = @divTrunc(@as(u32, @intCast(x)), self.settings.cmdSettings.chunkSize);
                    var chunkRow = @divTrunc(@as(u32, @intCast(y)), self.settings.cmdSettings.chunkSize);
                    var chunkIndex = chunkCol + chunkRow * self.settings.chunkCountAlongAxis[0];
                    var chunk = self.settings.chunks[chunkIndex];

                    var color = self.pixels[chunk.currentBufferIndex][i];
                    maxLuminance = @max(luminance(color), maxLuminance);
                }
            }

            y = self.settings.size[1];
            while (y > 0) {
                y -= 1;
                var x: usize = 0;
                while (x < self.settings.size[0]) : (x += 1) {
                    var i = y * self.settings.cmdSettings.width + x;
                    const chunkCol = @divTrunc(@as(u32, @intCast(x)), self.settings.cmdSettings.chunkSize);
                    const chunkRow = @divTrunc(@as(u32, @intCast(y)), self.settings.cmdSettings.chunkSize);
                    const chunkIndex = chunkCol + chunkRow * self.settings.chunkCountAlongAxis[0];
                    const chunk = self.settings.chunks[chunkIndex];

                    const isChunkRendering = chunk.isProcessingReadonly;
                    var isBorderingPixel = x == chunkCol * self.settings.cmdSettings.chunkSize or x == (chunkCol + 1) * (self.settings.cmdSettings.chunkSize) - 1;
                    isBorderingPixel = isBorderingPixel or y == chunkRow * self.settings.cmdSettings.chunkSize or y == (chunkRow + 1) * self.settings.cmdSettings.chunkSize - 1;

                    var borderColor = @Vector(3, f32){ 1.0, 0.0, 0.0 };
                    var color = borderColor;
                    if (!isChunkRendering or !isBorderingPixel or self.settings.cmdSettings.sppPerPass < 16) {
                        //var tonemappedColor = tonemapReinhardLuminance(self.pixels[@mod(chunk.currentBufferIndex + 1, 2)][i], maxLuminance);
                        var tonemappedColor = tonemapReinhardLuminance(self.pixels[chunk.currentBufferIndex][i], maxLuminance);
                        tonemappedColor = @min(tonemappedColor, @Vector(3, f32){ 1.0, 1.0, 1.0 });

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
                    pixels[x * 4 + 0] = @as(u8, @truncate(@as(u32, @intFromFloat(color[0] * 255))));
                    pixels[x * 4 + 1] = @as(u8, @truncate(@as(u32, @intFromFloat(color[1] * 255))));
                    pixels[x * 4 + 2] = @as(u8, @truncate(@as(u32, @intFromFloat(color[2] * 255))));
                    pixels[x * 4 + 3] = 0;
                }
            }

            try sdlRenderer.copy(texture, null, null);
            sdlRenderer.present();

            const targetFrametime: u64 = @intFromFloat(33.333 * 1000000);
            const frameTime = std.time.nanoTimestamp() - frameStartTime;
            //print("Frametime: {d:.3}ms, fps: {d:.3}, waitTime: {d:.3}ms\n", .{ @as(f32, @floatFromInt(frameTime)) / 1000000.0, 1000000000.0 / @as(f32, @floatFromInt(frameTime)), @as(f32, @floatFromInt(@max(0, targetFrametime - frameTime))) / 1000000.0 });
            std.time.sleep(@as(u64, @intCast(@max(0, targetFrametime - frameTime))));
        }
    }

    pub fn ppmScreenshot(self: *Renderer, file: *const std.fs.File) !void {
        var writer = file.writer();

        try writer.print("P3\n", .{});
        try writer.print("{} {}\n", .{ self.settings.size[0], self.settings.size[1] });
        try writer.print("{}\n", .{255});

        var x: usize = 0;
        var y: usize = self.settings.size[1];
        while (y > 0) {
            y -= 1;
            x = 0;
            while (x < self.settings.size[0]) : (x += 1) {
                // TODO: wrong buffer
                var color = self.pixels[0][y * self.settings.size[0] + x];

                var tonemappedColor = tonemapReinhardLuminance(color, std.math.inf(f32));
                tonemappedColor = @min(tonemappedColor, @Vector(3, f32){ 1.0, 1.0, 1.0 });

                if (self.settings.cmdSettings.gamma == 2.0) {
                    color = @sqrt(tonemappedColor);
                } else {
                    var gammaExponent = 1.0 / self.settings.cmdSettings.gamma;
                    color[0] = pow(f32, tonemappedColor[0], gammaExponent);
                    color[1] = pow(f32, tonemappedColor[1], gammaExponent);
                    color[2] = pow(f32, tonemappedColor[2], gammaExponent);
                }

                var r = @as(u8, @truncate(@as(u32, @intFromFloat(color[0] * 255))));
                var g = @as(u8, @truncate(@as(u32, @intFromFloat(color[1] * 255))));
                var b = @as(u8, @truncate(@as(u32, @intFromFloat(color[2] * 255))));

                try writer.print("{} {} {}\n", .{ r, g, b });
            }
        }
    }
};
