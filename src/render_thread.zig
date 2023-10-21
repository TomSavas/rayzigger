const std = @import("std");
const zm = @import("zmath");
const SDL = @import("sdl2");
const pow = std.math.pow;
const PI = std.math.pi;
const print = std.debug.print;
const printErr = std.io.getStdErr().writer().print;
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
const CameraTransform = @import("camera.zig").CameraTransform;
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
//fn atmosphere(r: Ray, sunPos: @Vector(4, f32), samples: usize, rayleighColor: @Vector(3, f32), mieColor: @Vector(3, f32)) @Vector(3, f32) {
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
fn background(r: *const Ray) @Vector(3, f32) {
    var y = zm.normalize3(r.dir)[1];
    // -1; 1 -> 0; 1
    y = (y + 1.0) * 0.5;

    var percentage = 0.2 + y * 0.8;

    //const white = @Vector(3, f32){ 0.01, 0.01, 0.01 };
    //const blue = @Vector(3, f32){ 0.0, 0.0, 0.05 };
    const white = @Vector(3, f32){ 1.0, 1.0, 1.0 };
    const blue = @Vector(3, f32){ 0.2, 0.3, 1.0 };

    return zm.lerp(white, blue, percentage);
}

const TraceResult = struct {
    color: @Vector(3, f32),
    location: @Vector(4, f32),
};

fn traceRay(ray: *const Ray, bvh: *const BVH, remainingBounces: u32, rng: Random) TraceResult {
    if (remainingBounces <= 0) {
        return TraceResult{ .color = @Vector(3, f32){ 0.0, 0.0, 0.0 }, .location = @Vector(4, f32){ 100000000.0, 100000000.0, 100000000.0, 0.0 } };
    }

    var nearestHitDistance: f32 = std.math.inf(f32);
    var bvhHit = bvh.hittable.testHit(ray, 0.001, nearestHitDistance);
    if (bvhHit == null) {
        return TraceResult{ .color = background(ray), .location = @Vector(4, f32){ 200000000.0, 200000000.0, 200000000.0, 0.0 } };
    }

    var scatteredRay = bvhHit.?.material.?.scatter(&bvhHit.?, ray, rng);
    return TraceResult{ .color = scatteredRay.emissiveness + scatteredRay.attenuation * traceSecondaryRay(&scatteredRay.ray, bvh, remainingBounces - 1, rng), .location = bvhHit.?.location };
}

fn traceSecondaryRay(ray: *const Ray, bvh: *const BVH, remainingBounces: u32, rng: Random) @Vector(3, f32) {
    if (remainingBounces <= 0) {
        return @Vector(3, f32){ 0.0, 0.0, 0.0 };
    }

    var nearestHitDistance: f32 = std.math.inf(f32);
    var bvhHit = bvh.hittable.testHit(ray, 0.001, nearestHitDistance);
    if (bvhHit == null) {
        return background(ray);
    }

    var scatteredRay = bvhHit.?.material.?.scatter(&bvhHit.?, ray, rng);
    return scatteredRay.emissiveness + scatteredRay.attenuation * traceSecondaryRay(&scatteredRay.ray, bvh, remainingBounces - 1, rng);
}

pub const Chunk = struct {
    chunkTopRightPixelIndices: @Vector(2, u32),
    chunkSize: @Vector(2, u32),

    cameraTransforms: [2]CameraTransform,

    currentBufferIndex: u32,

    processingLock: Mutex,
    processed: bool,
    sampleCount: ?u32,
    isProcessingReadonly: bool,
    justInvalidated: bool,

    pub fn init(topRightPixelIndices: @Vector(2, u32), chunkSize: @Vector(2, u32)) Chunk {
        return Chunk{
            .chunkTopRightPixelIndices = topRightPixelIndices,
            .chunkSize = chunkSize,
            .cameraTransforms = .{ undefined, undefined },
            .currentBufferIndex = 0,
            .processingLock = Mutex{},
            .processed = false,
            .sampleCount = 0,
            .isProcessingReadonly = false,
            .justInvalidated = false,
        };
    }

    pub fn reprojectFromLastFrame(self: *Chunk, ctx: *RenderThreadCtx) bool {
        var reprojectedAnyPixels = false;

        const previousBufferIndex = self.currentBufferIndex;
        self.currentBufferIndex = @mod(previousBufferIndex + 1, 2);

        self.sampleCount = self.sampleCount orelse 0;

        const previousCameraTransform = self.cameraTransforms[previousBufferIndex];
        const pixelCount = ctx.settings.size[0] * ctx.settings.size[1];

        var yOffset: usize = 0;
        while (yOffset < self.chunkSize[1]) : (yOffset += 1) {
            const y = self.chunkTopRightPixelIndices[1] + yOffset;

            var xOffset: usize = 0;
            while (xOffset < self.chunkSize[0]) : (xOffset += 1) {
                const x = self.chunkTopRightPixelIndices[0] + xOffset;
                const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(ctx.settings.size[0]));
                const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(ctx.settings.size[1]));
                // TODO: this has a bug when reprojecting into another pixel. We might be using the wrong "old" camera transform
                // and we might be sampling the wrong buffers...
                const index = y * ctx.settings.size[0] + x;

                ctx.sampleCounts[self.currentBufferIndex][index] = 0;

                const ray = ctx.camera.generateRay(u, v, ctx.rng);
                const bvhHit = ctx.bvh.hittable.testHit(&ray, 0.001, std.math.inf(f32));
                if (bvhHit == null) {
                    continue;
                }

                const oldReconstructedRay = Ray{ .origin = previousCameraTransform.origin, .dir = zm.normalize3(bvhHit.?.location - previousCameraTransform.origin) };
                const oldUv = previousCameraTransform.uvFromRay(oldReconstructedRay);
                const validOldTexCoords = oldUv[0] >= 0.0 and oldUv[0] <= 1.0 and oldUv[1] >= 0.0 and oldUv[1] <= 1.0;

                if (validOldTexCoords and ctx.sampleCounts[previousBufferIndex][index] > 0) {
                    const oldTexCoords = @Vector(2, i32){
                        @as(i32, @intFromFloat(oldUv[0] * @as(f32, @floatFromInt(ctx.settings.size[0])))),
                        @as(i32, @intFromFloat(oldUv[1] * @as(f32, @floatFromInt(ctx.settings.size[1])))),
                    };
                    const oldIndex = @as(usize, @intCast(oldTexCoords[1] * @as(i32, @intCast(ctx.settings.size[0])) + oldTexCoords[0]));

                    const distDiffSq = @fabs(zm.lengthSq3(bvhHit.?.location - ctx.hitWorldLocations[previousBufferIndex][oldIndex])[0]);
                    if (oldIndex >= 0 and oldIndex < pixelCount and distDiffSq < 0.01) {
                        ctx.pixels[self.currentBufferIndex][index] = ctx.pixels[previousBufferIndex][oldIndex];
                        ctx.hitWorldLocations[self.currentBufferIndex][index] = ctx.hitWorldLocations[previousBufferIndex][oldIndex];
                        ctx.sampleCounts[self.currentBufferIndex][index] = ctx.sampleCounts[previousBufferIndex][oldIndex];

                        reprojectedAnyPixels = true;
                    }
                }
            }
        }

        return reprojectedAnyPixels;
    }

    pub fn render(self: *Chunk, ctx: *RenderThreadCtx) void {
        self.isProcessingReadonly = true;
        defer self.isProcessingReadonly = false;

        if (self.sampleCount == null and self.reprojectFromLastFrame(ctx)) {
            return;
        }

        const previousBufferIndex = self.currentBufferIndex;
        self.currentBufferIndex = @mod(previousBufferIndex + 1, 2);

        const targetSampleCount = (self.sampleCount orelse 0) + ctx.settings.cmdSettings.sppPerPass;

        var yOffset: usize = 0;
        topLoop: while (yOffset < self.chunkSize[1]) : (yOffset += 1) {
            const y = self.chunkTopRightPixelIndices[1] + yOffset;

            var xOffset: usize = 0;
            while (xOffset < self.chunkSize[0]) : (xOffset += 1) {
                const x = self.chunkTopRightPixelIndices[0] + xOffset;
                const u = (@as(f32, @floatFromInt(x)) + ctx.rng.float(f32)) / @as(f32, @floatFromInt(ctx.settings.size[0]));
                const index = y * ctx.settings.size[0] + x;

                const previousSampleCount = ctx.sampleCounts[previousBufferIndex][index];

                var sampleValue = TraceResult{ .color = @Vector(3, f32){ 0.0, 0.0, 0.0 }, .location = @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 } };
                var sampleCount: u32 = previousSampleCount;
                while (sampleCount < targetSampleCount) : (sampleCount += 1) {
                    const v = (@as(f32, @floatFromInt(y)) + ctx.rng.float(f32)) / @as(f32, @floatFromInt(ctx.settings.size[1]));

                    const ray = ctx.camera.generateRay(u, v, ctx.rng);
                    const traceResult = traceRay(&ray, &ctx.bvh, ctx.settings.cmdSettings.maxBounces, ctx.rng);
                    sampleValue.color += traceResult.color;
                    sampleValue.location += traceResult.location;
                }

                // Rolling average
                const previousSampleCountSplat3: @Vector(3, f32) = @splat(@as(f32, @floatFromInt(previousSampleCount)));
                const previousSampleCountSplat4: @Vector(4, f32) = @splat(@as(f32, @floatFromInt(previousSampleCount)));
                const sampleCountSplat3: @Vector(3, f32) = @splat(@as(f32, @floatFromInt(sampleCount)));
                const sampleCountSplat4: @Vector(4, f32) = @splat(@as(f32, @floatFromInt(sampleCount)));
                ctx.pixels[self.currentBufferIndex][index] = (ctx.pixels[previousBufferIndex][index] * previousSampleCountSplat3 + sampleValue.color) / sampleCountSplat3;
                ctx.hitWorldLocations[self.currentBufferIndex][index] = (ctx.hitWorldLocations[previousBufferIndex][index] * previousSampleCountSplat4 + sampleValue.location) / sampleCountSplat4;
                ctx.sampleCounts[self.currentBufferIndex][index] = sampleCount;

                if (invalidationSignal) {
                    break :topLoop;
                }
            }
        }

        self.sampleCount = targetSampleCount;
        self.cameraTransforms[self.currentBufferIndex] = ctx.camera.transform;
    }
};

pub var invalidationSignal: bool = false;
pub const RenderThreadCtx = struct {
    id: u32,
    chunks: []Chunk,
    rng: Random,
    camera: *Camera,
    bvh: BVH,
    pixels: [][]@Vector(3, f32),
    hitWorldLocations: [][]@Vector(4, f32),
    sampleCounts: [][]u32,

    settings: *const Settings,

    shouldTerminate: bool = false,
    invalidationSignal: bool = false,
    uninvalidatedThreadCount: *std.atomic.Atomic(u32),
};

const SpiralChunkIterator = struct {
    chunks: []Chunk,
    chunkCount: @Vector(2, i32),

    currentChunkIndex: @Vector(2, i32),
    currentChunkOffset: @Vector(2, i32) = @Vector(2, i32){ 0, 0 },

    step: i32 = 1,
    edgeLengths: @Vector(2, i32) = @Vector(2, i32){ 0, 0 },
    unboundedEdgeLength: i32 = 0,

    pub fn init(chunks: []Chunk, chunkCount: @Vector(2, u32)) SpiralChunkIterator {
        var signedChunkCount = @Vector(2, i32){ @intCast(chunkCount[0]), @intCast(chunkCount[1]) };
        return .{
            .chunks = chunks,
            .chunkCount = signedChunkCount,
            .currentChunkIndex = @Vector(2, i32){ @intCast(@divTrunc(chunkCount[0], 2)), @intCast(@divTrunc(chunkCount[1], 2)) },
        };
    }

    pub fn currentChunk(self: *SpiralChunkIterator) *Chunk {
        const gridIndex = self.currentChunkIndex + self.currentChunkOffset;
        return &self.chunks[@intCast(gridIndex[0] + gridIndex[1] * self.chunkCount[0])];
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
        self.currentChunkOffset = @Vector(2, i32){ 0, 0 };
        self.step *= -1;
        self.unboundedEdgeLength += 1;

        if (self.unboundedEdgeLength > @max(self.chunkCount[0], self.chunkCount[1])) {
            return null;
        }

        var newEdgeLenghts = @Vector(2, i32){
            @min(@max(self.unboundedEdgeLength, 0), self.chunkCount[0] - 1),
            @min(@max(self.unboundedEdgeLength, 0), self.chunkCount[1] - 1),
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
                var leastSamples: u32 = std.math.maxInt(u32);
                if (leastProcessedChunk) |oldChunk| {
                    leastSamples = oldChunk.sampleCount orelse 0;
                }

                if ((chunk.sampleCount orelse 0) < leastSamples) {
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
            // The least processed chunk is rendered to target spp, we're done
            if (ctx.settings.cmdSettings.targetSpp) |targetSpp| {
                if ((chunk.sampleCount orelse 0) >= targetSpp) {
                    chunk.processingLock.unlock();

                    // But not in benchmark, idle until invalidation happens
                    if (ctx.settings.cmdSettings.benchmark == null) {
                        continue;
                    } else {
                        break;
                    }
                }
            }

            chunk.render(ctx);
            chunk.processingLock.unlock();
        } else {
            print("Thread couldn't find a chunk to process, potentially more threads than chunks.\n", .{});
        }

        if (invalidationSignal) {
            _ = ctx.uninvalidatedThreadCount.fetchSub(1, .Monotonic);
            while (ctx.uninvalidatedThreadCount.load(.Monotonic) > 0) {
                for (ctx.chunks) |*chunk| {
                    chunk.sampleCount = null;
                }
            }
            invalidationSignal = false;
        }
    }
}

pub const RenderThreads = struct {
    ctxs: []RenderThreadCtx,
    threads: []Thread,
    rngs: []DefaultRandom,

    allocator: std.mem.Allocator,
    uninvalidatedThreadCount: std.atomic.Atomic(u32),

    pub fn init(threadCount: u32, allocator: std.mem.Allocator, settings: *Settings, camera: *Camera, accumulatedPixels: [][]@Vector(3, f32), hitWorldLocations: [][]@Vector(4, f32), sampleCounts: [][]u32, bvh: BVH) anyerror!RenderThreads {
        var renderThreads = RenderThreads{
            .ctxs = try allocator.alloc(RenderThreadCtx, threadCount),
            .threads = try allocator.alloc(Thread, threadCount),
            .rngs = try allocator.alloc(DefaultRandom, threadCount),
            .allocator = allocator,
            .uninvalidatedThreadCount = std.atomic.Atomic(u32){ .value = 0 },
        };

        var threadId: u32 = 0;
        while (threadId < threadCount) : (threadId += 1) {
            renderThreads.rngs[threadId] = DefaultRandom.init(threadId);

            renderThreads.ctxs[threadId] = RenderThreadCtx{
                .id = threadId,
                .chunks = settings.chunks,
                .rng = renderThreads.rngs[threadId].random(),
                .pixels = accumulatedPixels,
                .hitWorldLocations = hitWorldLocations,
                .sampleCounts = sampleCounts,

                .camera = camera,
                .bvh = bvh,

                .settings = settings,
                .uninvalidatedThreadCount = &renderThreads.uninvalidatedThreadCount,
            };

            renderThreads.threads[threadId] = try Thread.spawn(.{}, renderThreadFn, .{&renderThreads.ctxs[threadId]});
        }

        return renderThreads;
    }

    pub fn blockUntilDone(self: *RenderThreads) void {
        var threadId: usize = 0;
        while (threadId < self.threads.len) : (threadId += 1) {
            self.threads[threadId].join();
        }
    }

    pub fn deinit(self: *RenderThreads) void {
        var threadId: usize = 0;
        while (threadId < self.threads.len) : (threadId += 1) {
            self.ctxs[threadId].shouldTerminate = true;
        }
        self.blockUntilDone();

        self.allocator.free(self.ctxs);
        self.allocator.free(self.threads);
        self.allocator.free(self.rngs);
    }

    pub fn invalidate(self: *RenderThreads) void {
        self.uninvalidatedThreadCount.store(@intCast(self.threads.len), .Monotonic);
        invalidationSignal = true;
    }
};
