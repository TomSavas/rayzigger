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
const Triangle = @import("hittables.zig").Triangle;
const Ray = @import("ray.zig").Ray;
const Hit = @import("ray.zig").Hit;
const Material = @import("materials.zig").Material;
const LambertianMat = @import("materials.zig").LambertianMat;
const MetalMat = @import("materials.zig").MetalMat;
const DielectricMat = @import("materials.zig").DielectricMat;

const Camera = @import("camera.zig").Camera;
const Settings = @import("settings.zig").Settings;

const BVH = @import("bvh.zig").BVHNode;

//fn henyeyGreensteinPhase(theta: f32, g: f32) f32 {
//    var gSqr = g * g;
//    var cosTheta = @cos(theta);
//    var cosSqrTheta = @cos(cosTheta);
//
//    var phase = (3.0 * (1.0 - gSqr)) / (2.0 * (2.0 + gSqr));
//    phase *= (1 + cosSqrTheta) / std.math.pow(f32, 1.0 + gSqr - 2 * g * cosTheta, 3.0 / 2.0);
//}
//
//fn rayleighPhase(cosSqrTheta: f32) f32 {
//    return 3.0 / (16.0 * std.math.pi) * (1.0 + cosSqrTheta);
//}
//
//fn miePhase(cosTheta: f32, cosSqrTheta: f32, g: f32, gSqr: f32) f32 {
//
//}
//
//fn atmosphere(r: Ray, sunPos: Vector(4, f32), samples: usize, rayleighColor: Vector(3, f32), mieColor: Vector(3, f32)) Vector(3, f32) {
//    var samplePoint = 1;
//    while (samples > 0) : (samples -= 1) {
//
//    }
//
//    var sunDir = sunPos - r.origin;
//    var cosTheta = zm.dot3(r.dir, sunDir)[0];
//    var cosSqrTheta = cosTheta * cosTheta;
//
//    var color = rayleighPhase(cosSqrTheta) * rayleighColor + miePhase(cosTheta, cosSqrTheta, g, gSqr) * mieColor;
//}

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

fn traceRay(ray: Ray, bvh: BVH, remainingBounces: u32, rng: Random) Vector(3, f32) {
    if (remainingBounces <= 0) {
        return Vector(3, f32){ 0.0, 0.0, 0.0 };
    }

    var nearestHit: ?Hit = null;
    var hitMaterial: ?*const Material = null;
    var nearestHitDistance: f32 = std.math.inf(f32);
    if (nearestHit) |hit| {
        nearestHitDistance = hit.rayFactor;
    }

    var bvhHit = bvh.hittable.testHit(ray, 0.001, nearestHitDistance);
    if (bvhHit != null) {
        nearestHit = bvhHit;
        hitMaterial = bvhHit.?.material;
    }

    if (nearestHit) |hit| {
        var scatteredRay = hitMaterial.?.scatter(&hit, ray, rng);
        return scatteredRay.emissiveness + scatteredRay.attenuation * traceRay(scatteredRay.ray, bvh, remainingBounces - 1, rng);
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
        self.sampleCount += @intToFloat(f32, ctx.settings.spp);

        var yOffset: usize = 0;
        topLoop: while (yOffset < self.chunkSize[1]) : (yOffset += 1) {
            const y = self.chunkTopRightPixelIndices[1] + yOffset;

            var xOffset: usize = 0;
            while (xOffset < self.chunkSize[0]) : (xOffset += 1) {
                const x = self.chunkTopRightPixelIndices[0] + xOffset;

                var color = Vector(3, f32){ 0.0, 0.0, 0.0 };
                var sample: u32 = 0;
                while (sample < ctx.settings.spp) : (sample += 1) {
                    var u = (@intToFloat(f32, x) + ctx.rng.float(f32)) / @intToFloat(f32, ctx.settings.size[0]);
                    var v = (@intToFloat(f32, y) + ctx.rng.float(f32)) / @intToFloat(f32, ctx.settings.size[1]);

                    var ray = ctx.camera.generateRay(u, v, ctx.rng);
                    color += traceRay(ray, ctx.bvh, ctx.settings.maxBounces, ctx.rng);
                }

                // Rolling average
                var ssp = self.sampleCount;
                if (self.sampleCount <= 0) ssp = 1;
                ctx.pixels[y * ctx.settings.size[0] + x] = (ctx.pixels[y * ctx.settings.size[0] + x] * @splat(3, previousSampleCount) + color) / @splat(3, ssp);

                if (invalidationSignal) {
                    break :topLoop;
                }
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
    bvh: BVH,
    pixels: []Vector(3, f32),

    settings: *const Settings,

    shouldTerminate: bool = false,
    invalidationSignal: bool = false,
};

const SpiralChunkIterator = struct {
    chunks: []Chunk,
    chunkCount: Vector(2, i32),

    currentChunkIndex: Vector(2, i32),
    currentChunkOffset: Vector(2, i32) = Vector(2, i32){ 0, 0 },

    step: i32 = 1,
    edgeLengths: Vector(2, i32) = Vector(2, i32){ 0, 0 },
    unboundedEdgeLength: i32 = 0,

    pub fn init(chunks: []Chunk, chunkCount: Vector(2, u32)) SpiralChunkIterator {
        var signedChunkCount = Vector(2, i32){ @intCast(i32, chunkCount[0]), @intCast(i32, chunkCount[1]) };
        return .{
            .chunks = chunks,
            .chunkCount = signedChunkCount,
            .currentChunkIndex = Vector(2, i32){ @intCast(i32, @divTrunc(chunkCount[0], 2)), @intCast(i32, @divTrunc(chunkCount[1], 2)) },
        };
    }

    pub fn currentChunk(self: *SpiralChunkIterator) *Chunk {
        const gridIndex = self.currentChunkIndex + self.currentChunkOffset;
        return &self.chunks[@intCast(u32, gridIndex[0] + gridIndex[1] * self.chunkCount[0])];
    }

    pub fn next(self: *SpiralChunkIterator) ?*Chunk {
        self.currentChunkOffset[0] += self.step;
        if (-self.edgeLengths[0] <= self.currentChunkOffset[0] and self.currentChunkOffset[0] <= self.edgeLengths[0]) {
            return self.currentChunk();
        }
        self.currentChunkOffset[0] -= self.step;

        self.currentChunkOffset[1] += self.step;
        if (-self.edgeLengths[1] <= self.currentChunkOffset[1] and self.currentChunkOffset[1] <= self.edgeLengths[1]) {
            return self.currentChunk();
        }
        self.currentChunkOffset[1] -= self.step;

        self.currentChunkIndex += self.currentChunkOffset;
        self.currentChunkOffset = Vector(2, i32){ 0, 0 };
        self.step *= -1;
        self.unboundedEdgeLength += 1;

        if (self.unboundedEdgeLength > @maximum(self.chunkCount[0], self.chunkCount[1])) {
            return null;
        }

        var newEdgeLenghts = Vector(2, i32){
            @minimum(@maximum(self.unboundedEdgeLength, 0), self.chunkCount[0] - 1),
            @minimum(@maximum(self.unboundedEdgeLength, 0), self.chunkCount[1] - 1),
        };
        self.edgeLengths = newEdgeLenghts;

        return self.currentChunk();
    }
};

pub fn renderThreadFn(ctx: *RenderThreadCtx) void {
    while (!ctx.shouldTerminate) {
        var leastProcessedChunk: ?*Chunk = null;

        // Order chunks in a counter-clockwise spiral starting at the center. Central chunks contain
        // the objects of focus, so we want lower latency on them.
        // TODO: sort once, drop the iterator
        var chunks = SpiralChunkIterator.init(ctx.chunks, ctx.settings.chunkCountAlongAxis);
        while (chunks.next()) |chunk| {
            if (chunk.processingLock.tryLock()) {
                var leastSamples: f32 = std.math.inf(f32);
                if (leastProcessedChunk) |oldChunk| {
                    leastSamples = oldChunk.sampleCount;
                }

                if (chunk.sampleCount < leastSamples) {
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

    pub fn init(threadCount: u32, allocator: std.mem.Allocator, settings: *Settings, camera: *Camera, accumulatedPixels: []Vector(3, f32), bvh: BVH) anyerror!RenderThreads {
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
                .bvh = bvh,

                .settings = settings,

                //.size = settings.size,
                //.spp = settings.spp,
                //.gamma = settings.gamma,
                //.maxBounces = settings.maxBounces,
            };

            renderThreads.threads[threadId] = try Thread.spawn(.{}, renderThreadFn, .{&renderThreads.ctxs[threadId]});
        }

        return renderThreads;
    }

    pub fn deinit(self: *RenderThreads) void {
        var threadid: u32 = 0;
        while (threadid < 1) : (threadid += 1) {
            self.ctxs[threadid].shouldTerminate = true;
        }
        threadid = 0;
        while (threadid < 1) : (threadid += 1) {
            self.threads[threadid].join();
        }

        self.allocator.free(self.ctxs);
        self.allocator.free(self.threads);
        self.allocator.free(self.rngs);
    }
};
