const std = @import("std");
const zm = @import("zmath");
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

const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
};

fn outputPPMHeader(size: Vector(2, u32)) anyerror!void {
    try print("P3\n", .{});
    try print("{} {}\n", .{ size[0], size[1] });
    try print("{}\n", .{255});
}

fn outputPixels(size: Vector(2, u32), pixels: []Pixel) anyerror!void {
    var x: usize = 0;
    var y: usize = size[1];
    while (y > 0) {
        y -= 1;
        x = 0;
        while (x < size[0]) : (x += 1) {
            var index = y * size[0] + x;
            try print("{} {} {}\n", pixels[index]);
        }
    }
}

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

        var maybeHit = sphere.hittable.testHit(ray, 0.001, maxDistance);
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

const Camera = struct {
    origin: Vector(4, f32),
    right: Vector(4, f32),
    up: Vector(4, f32),
    focusPlaneLowerLeft: Vector(4, f32),
    lensRadius: f32,

    pub fn init(pos: Vector(4, f32), lookAt: Vector(4, f32), requestedUp: Vector(4, f32), vfov: f32, aspectRatio: f32, aperture: f32, focusDist: f32) Camera {
        const h = @sin(vfov / 2.0) / @cos(vfov / 2.0);
        const viewportHeight = 2.0 * h;
        const viewportSize = Vector(2, f32){ viewportHeight * aspectRatio, viewportHeight };

        var forward = zm.normalize3(lookAt - pos);
        var right = zm.normalize3(zm.cross3(forward, requestedUp));
        var up = zm.cross3(right, forward);

        right = @splat(4, viewportSize[0] * focusDist) * right;
        up = @splat(4, viewportHeight * focusDist) * up;
        const focusPlaneLowerLeft = pos - right * zm.f32x4s(0.5) - up * zm.f32x4s(0.5) + @splat(4, focusDist) * forward;

        return Camera{ .origin = pos, .right = right, .up = up, .focusPlaneLowerLeft = focusPlaneLowerLeft, .lensRadius = aperture / 2.0 };
    }

    pub fn generateRay(self: Camera, u: f32, v: f32, rng: Random) Ray {
        const onLenseOffset = zm.normalize3(self.up) * @splat(4, self.lensRadius * rng.float(f32)) + zm.normalize3(self.right) * @splat(4, self.lensRadius * rng.float(f32));

        const offsetOrigin = self.origin + onLenseOffset;
        const dir = self.focusPlaneLowerLeft + @splat(4, u) * self.right + @splat(4, v) * self.up - offsetOrigin;
        return Ray{ .origin = offsetOrigin, .dir = zm.normalize3(dir) };
    }
};

const RenderThreadCtx = struct {
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

const Chunk = struct {
    chunkTopRightPixelIndices: Vector(2, u32),
    chunkSize: Vector(2, u32),

    processingLock: Mutex,
    processed: bool,

    pub fn init(topRightPixelIndices: Vector(2, u32), chunkSize: Vector(2, u32)) Chunk {
        return Chunk{ .chunkTopRightPixelIndices = topRightPixelIndices, .chunkSize = chunkSize, .processingLock = Mutex{}, .processed = false };
    }

    pub fn render(self: *Chunk, ctx: *const RenderThreadCtx) void {
        var yOffset: usize = 0;
        while (yOffset < self.chunkSize[1]) : (yOffset += 1) {
            const y = self.chunkTopRightPixelIndices[1] + yOffset;

            var xOffset: usize = 0;
            while (xOffset < self.chunkSize[0]) : (xOffset += 1) {
                const x = self.chunkTopRightPixelIndices[0] + xOffset;

                var color = Vector(3, f32){ 0.0, 0.0, 0.0 };
                var sample: u32 = 0;
                while (sample < ctx.spp) : (sample += 1) {
                    var u = (@intToFloat(f32, x) + ctx.rng.float(f32)) / @intToFloat(f32, ctx.size[0]);
                    var v = (@intToFloat(f32, y) + ctx.rng.float(f32)) / @intToFloat(f32, ctx.size[1]);

                    var ray = ctx.camera.generateRay(u, v, ctx.rng);
                    color += traceRay(ray, ctx.spheres, ctx.maxBounces, ctx.rng);
                }

                ctx.pixels[y * ctx.size[0] + x] += color;
            }
        }
        self.processed = true;
    }
};

fn renderThreadFn(ctx: *RenderThreadCtx) void {
    var areUnprocessedChunks = true;
    while (areUnprocessedChunks) {
        areUnprocessedChunks = false;

        for (ctx.chunks) |*chunk| {
            if (!chunk.processed and chunk.processingLock.tryLock()) {
                printErr("Rendering (thread_{}): {}\n", .{ ctx.id, chunk.chunkTopRightPixelIndices }) catch {};

                chunk.render(ctx);
                chunk.processingLock.unlock();
                areUnprocessedChunks = true;
            }
        }
    }
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const aspectRatio = 16.0 / 9.0;
    const width = 768;
    //const width = 1920;
    //const width = 2560;
    //const width = 3840;
    const size = Vector(2, u32){ width, width / aspectRatio };
    const pixelCount = size[0] * size[1];
    const spp = 32;
    const maxBounces = 16;
    const gamma = 2.2;

    const cameraPos = Vector(4, f32){ 13.0, 2.0, 3.0, 0.0 };
    const lookTarget = Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 };
    var camera = Camera.init(cameraPos, lookTarget, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 }, PI / 8.0, aspectRatio, 0.1, 10.0);

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

    const chunkCountAlongAxis = 16;
    const chunkCount = chunkCountAlongAxis * chunkCountAlongAxis;
    var chunks: [chunkCount]Chunk = undefined;
    const chunkSize = Vector(2, u32){ size[0] / chunkCountAlongAxis, size[1] / chunkCountAlongAxis };
    var chunkIndex: u32 = 0;
    while (chunkIndex < chunkCount) : (chunkIndex += 1) {
        const chunkCol = @mod(chunkIndex, chunkCountAlongAxis);
        const chunkRow = @divTrunc(chunkIndex, chunkCountAlongAxis);

        const chunkStartIndices = Vector(2, u32){ chunkCol * chunkSize[0], chunkRow * chunkSize[1] };
        chunks[chunkIndex] = Chunk.init(chunkStartIndices, chunkSize);
    }

    var accumulatedPixels: []Vector(3, f32) = try allocator.alloc(Vector(3, f32), pixelCount);
    defer allocator.free(accumulatedPixels);
    std.mem.set(Vector(3, f32), accumulatedPixels, Vector(3, f32){ 0.0, 0.0, 0.0 });

    const threadCount = 12;
    var ctxs: [threadCount]RenderThreadCtx = undefined;
    var tasks: [threadCount]Thread = undefined;
    var threadId: u32 = 0;
    while (threadId < threadCount) : (threadId += 1) {
        var ctx = RenderThreadCtx{
            .id = threadId,
            .chunks = &chunks,
            .rng = DefaultRandom.init(threadId).random(),
            .pixels = accumulatedPixels,

            .camera = &camera,
            .spheres = spheres,

            .size = size,
            .spp = spp,
            .gamma = gamma,
            .maxBounces = maxBounces,
        };
        ctxs[threadId] = ctx;

        tasks[threadId] = try Thread.spawn(.{}, renderThreadFn, .{&ctxs[threadId]});
    }

    threadId = 0;
    while (threadId < threadCount) : (threadId += 1) {
        tasks[threadId].join();
    }

    try printErr("Writing...\n", .{});
    try outputPPMHeader(size);
    var img: []Pixel = try allocator.alloc(Pixel, pixelCount);
    defer allocator.free(img);

    var y: usize = size[1];
    while (y > 0) {
        y -= 1;
        var x: usize = 0;
        while (x < size[0]) : (x += 1) {
            var color = accumulatedPixels[y * width + x];
            img[y * width + x] = Pixel{
                .r = @truncate(u8, @floatToInt(u32, pow(f32, color[0] / spp, 1.0 / gamma) * 255)),
                .g = @truncate(u8, @floatToInt(u32, pow(f32, color[1] / spp, 1.0 / gamma) * 255)),
                .b = @truncate(u8, @floatToInt(u32, pow(f32, color[2] / spp, 1.0 / gamma) * 255)),
            };
        }
    }
    try outputPixels(size, img);
}
