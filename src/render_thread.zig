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

const Camera = @import("camera.zig").Camera;
const Settings = @import("settings.zig").Settings;

// TODO: implement atmospheric scattering
fn background(r: Ray) Vector(3, f32) {
    var y = zm.normalize3(r.dir)[1];
    // -1; 1 -> 0; 1
    y = (y + 1.0) * 0.5;

    var percentage = 0.2 + y * 0.8;

    const white = Vector(3, f32){ 1.0, 1.0, 1.0 };
    const blue = Vector(3, f32){ 0.5, 0.7, 1.0 };

    return zm.lerp(white, blue, percentage);
}

fn traceRay(ray: Ray, spheres: []Sphere, remainingBounces: u32, rng: Random) Vector(3, f32) {
    if (remainingBounces <= 0) {
        return Vector(3, f32){ 0.0, 0.0, 0.0 };
    }

    var nearestHit: ?Hit = null;
    var hitMaterial: ?*const Material = null;
    for (spheres) |sphere| {
        var maxDistance: f32 = 1000000.0;
        if (nearestHit) |hit| {
            maxDistance = hit.rayFactor;
        }

        var maybeHit = sphere.hittable.testHit(ray, 0.005, maxDistance);
        if (maybeHit) |hit| {
            nearestHit = hit;
            hitMaterial = sphere.material;
        }
    }

    if (nearestHit) |hit| {
        var scatteredRay = hitMaterial.?.scatter(&hit, ray, rng);
        return scatteredRay.attenuation * traceRay(scatteredRay.ray, spheres, remainingBounces - 1, rng);
    } else {
        return background(ray);
    }
}

pub const Chunk = struct {
    chunkTopRightPixelIndices: Vector(2, u32),
    chunkSize: Vector(2, u32),

    processingLock: Mutex,
    processed: bool,
    sampleCount: f32,
    isProcessingReadonly: bool,

    pub fn init(topRightPixelIndices: Vector(2, u32), chunkSize: Vector(2, u32)) Chunk {
        return Chunk{ .chunkTopRightPixelIndices = topRightPixelIndices, .chunkSize = chunkSize, .processingLock = Mutex{}, .processed = false, .sampleCount = 0, .isProcessingReadonly = false };
    }

    pub fn render(self: *Chunk, ctx: *RenderThreadCtx) void {
        self.isProcessingReadonly = true;

        var previousSampleCount = self.sampleCount;
        self.sampleCount += @intToFloat(f32, ctx.spp);

        var yOffset: usize = 0;
        while (yOffset < self.chunkSize[1]) : (yOffset += 1) {
            const y = self.chunkTopRightPixelIndices[1] + yOffset;

            var xOffset: usize = 0;
            while (xOffset < self.chunkSize[0]) : (xOffset += 1) {
                const x = self.chunkTopRightPixelIndices[0] + xOffset;

                var color = Vector(3, f32){ 0.0, 0.0, 0.0 };
                var sample: u32 = 0;
                while (sample < ctx.spp) : (sample += 1) {
                    //printErr("Rendering {} {} {}\n", .{ x, y, sample }) catch {};
                    var u = (@intToFloat(f32, x) + ctx.rng.float(f32)) / @intToFloat(f32, ctx.size[0]);
                    var v = (@intToFloat(f32, y) + ctx.rng.float(f32)) / @intToFloat(f32, ctx.size[1]);

                    var ray = ctx.camera.generateRay(u, v, ctx.rng);
                    color += traceRay(ray, ctx.spheres, ctx.maxBounces, ctx.rng);
                }

                // Rolling average
                var ssp = self.sampleCount;
                if (self.sampleCount <= 0) ssp = 1;
                ctx.pixels[y * ctx.size[0] + x] = (ctx.pixels[y * ctx.size[0] + x] * @splat(3, previousSampleCount) + color) / @splat(3, ssp);
            }

            if (invalidationSignal) {
                //self.sampleCount = 0;
                break;
            }
        }
        self.isProcessingReadonly = false;
    }
};

pub var invalidationSignal: bool = false;
pub const RenderThreadCtx = struct {
    id: u32,
    chunks: []Chunk,
    rng: Random,
    camera: *Camera,
    spheres: []Sphere,
    pixels: []Vector(3, f32),

    size: Vector(2, u32),
    spp: u32,
    gamma: f32,
    maxBounces: u32,
};

pub fn renderThreadFn(ctx: *RenderThreadCtx) void {
    while (true) {
        var leastProcessedChunk: ?*Chunk = null;

        for (ctx.chunks) |*chunk| {
            if (chunk.processingLock.tryLock()) {
                var leastSamples: f32 = chunk.sampleCount;
                if (leastProcessedChunk) |oldChunk| {
                    leastSamples = oldChunk.sampleCount;
                }

                if (chunk.sampleCount <= leastSamples) {
                    if (leastProcessedChunk) |oldChunk| {
                        oldChunk.processingLock.unlock();
                    }

                    leastProcessedChunk = chunk;
                } else {
                    chunk.processingLock.unlock();
                }
            }
        }

        if (leastProcessedChunk) |chunk| {
            //printErr("Rendering {}\n", .{ctx.id}) catch {};
            chunk.render(ctx);
            chunk.processingLock.unlock();
        }

        while (invalidationSignal) {
            for (ctx.chunks) |*chunk| {
                chunk.sampleCount = 0;
            }
            std.time.sleep(10000.0);
        }
    }
}

pub const RenderThreads = struct {
    ctxs: []RenderThreadCtx,
    threads: []Thread,
    rngs: []DefaultRandom,

    allocator: std.mem.Allocator,

    pub fn init(threadCount: u32, allocator: std.mem.Allocator, settings: *Settings, camera: *Camera, accumulatedPixels: []Vector(3, f32), spheres: []Sphere) anyerror!RenderThreads {
        var renderThreads = RenderThreads{
            .ctxs = try allocator.alloc(RenderThreadCtx, threadCount),
            .threads = try allocator.alloc(Thread, threadCount),
            .rngs = try allocator.alloc(DefaultRandom, threadCount),
            .allocator = allocator,
        };

        var threadId: u32 = 0;
        while (threadId < threadCount) : (threadId += 1) {
            renderThreads.rngs[threadId] = DefaultRandom.init(threadId);

            renderThreads.ctxs[threadId] = RenderThreadCtx{
                .id = threadId,
                .chunks = settings.chunks,
                .rng = renderThreads.rngs[threadId].random(),
                .pixels = accumulatedPixels,

                .camera = camera,
                .spheres = spheres,

                .size = settings.size,
                .spp = settings.spp,
                .gamma = settings.gamma,
                .maxBounces = settings.maxBounces,
            };

            renderThreads.threads[threadId] = try Thread.spawn(.{}, renderThreadFn, .{&renderThreads.ctxs[threadId]});
            renderThreads.threads[threadId].detach();
        }

        return renderThreads;
    }

    pub fn deinit(self: *RenderThreads) void {
        self.allocator.free(self.ctxs);
        self.allocator.free(self.threads);
        self.allocator.free(self.rngs);
    }
};
