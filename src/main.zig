const std = @import("std");
const zm = @import("zmath");
const pow = std.math.pow;
const print = std.io.getStdOut().writer().print;
const printErr = std.io.getStdErr().writer().print;
const Vector = std.meta.Vector;
const Random = std.rand.Random;
const DefaultRandom = std.rand.DefaultPrng;
const Ray = @import("ray.zig").Ray;

var rng: Random = undefined;

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
    const pixelCount = size[0] * size[1];

    var x: usize = 0;
    var y: usize = size[1];
    while (y > 0) {
        try printErr("Writing: {}/{}\n", .{ x * (size[1] - y), pixelCount });

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

const Hit = struct {
    location: Vector(4, f32),
    normal: Vector(4, f32),
    rayFactor: f32,
};

const Hittable = struct {
    testHitFn: fn (*const Hittable, Ray, f32, f32) ?Hit,

    pub fn testHit(self: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        return self.testHitFn(self, r, minDist, maxDist);
    }
};

const Sphere = struct {
    center: Vector(4, f32),
    radius: f32,
    hittable: Hittable,

    pub fn init(center: Vector(4, f32), radius: f32) Sphere {
        return Sphere{ .center = center, .radius = radius, .hittable = Hittable{ .testHitFn = testHit } };
    }

    pub fn testHit(hittable: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        const self = @fieldParentPtr(Sphere, "hittable", hittable);

        var toOrigin = r.origin - self.center;
        var a = zm.dot3(r.dir, r.dir)[1];
        var b = 2.0 * zm.dot3(r.dir, toOrigin)[1];
        var c = zm.dot3(toOrigin, toOrigin)[1] - self.radius * self.radius;

        var discriminant = b * b - 4 * a * c;
        if (discriminant < 0)
            return null;

        var x = (-b - @sqrt(discriminant)) / (2.0 * a);
        if (x < minDist or x > maxDist) {
            x = (-b + @sqrt(discriminant)) / (2.0 * a);
            if (x < minDist or x > maxDist) {
                return null;
            }
        }

        var location = r.at(x);
        var normal = zm.normalize3(location - self.center);
        return Hit{ .location = location, .normal = normal, .rayFactor = x };
    }
};

fn randomInUnitSphere() Vector(4, f32) {
    while (true) {
        var vec = Vector(4, f32){ rng.float(f32), rng.float(f32), rng.float(f32), 0 };
        if (zm.lengthSq3(vec)[0] >= 1.0) continue;
        return vec;
    }
}

fn traceRay(ray: Ray, spheres: []Sphere, remainingBounces: u32) Vector(3, f32) {
    if (remainingBounces <= 0) {
        return Vector(3, f32){ 0.0, 0.0, 0.0 };
    }

    var nearestHit: ?Hit = null;
    for (spheres) |sphere| {
        var maxDistance: f32 = 1000000.0;
        if (nearestHit) |hit| {
            maxDistance = hit.rayFactor;
        }

        var maybeHit = sphere.hittable.testHit(ray, 0.001, maxDistance);
        if (maybeHit) |hit| {
            nearestHit = hit;
        }
    }

    if (nearestHit) |hit| {
        var newDir = hit.location + hit.normal + randomInUnitSphere();
        var bouncedRay = Ray{ .origin = hit.location, .dir = zm.normalize3(newDir) };

        return Vector(3, f32){ 0.5, 0.5, 0.5 } * traceRay(bouncedRay, spheres, remainingBounces - 1);
    } else {
        return background(ray);
    }
}

pub fn main() anyerror!void {
    rng = DefaultRandom.init(0).random();

    const aspectRatio = 16.0 / 9.0;
    const width = 512;
    const size = Vector(2, u32){ width, width / aspectRatio };
    const pixelCount = size[0] * size[1];
    const spp = 64;
    const maxBounces = 16;
    const gamma = 2.2;

    const viewportHeight = 2.0;
    const viewportSize = Vector(2, f32){ viewportHeight * aspectRatio, viewportHeight };
    const focalLength = 1.0;

    const origin = Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 };
    const forward = Vector(4, f32){ 0.0, 0.0, -focalLength, 0.0 };
    const right = Vector(4, f32){ viewportSize[0], 0.0, 0.0, 0.0 };
    const up = Vector(4, f32){ 0.0, viewportSize[1], 0.0, 0.0 };
    const lowerLeft = origin - (right / Vector(4, f32){ 2.0, 2.0, 2.0, 2.0 }) - (up / Vector(4, f32){ 2.0, 2.0, 2.0, 2.0 }) + forward;

    var spheres = [_]Sphere{
        Sphere.init(Vector(4, f32){ 0.0, 0.0, -1.0, 0.0 }, 0.5),
        Sphere.init(Vector(4, f32){ 0.0, -100.5, -1.0, 0.0 }, 100),
    };

    try outputPPMHeader(size);

    var img: [pixelCount]Pixel = undefined;
    var x: usize = 0;
    var y: usize = size[1];

    while (y > 0) {
        try printErr("Rendering: {}/{} at {}spp\n", .{ x * (size[1] - y), pixelCount, spp });
        y -= 1;
        x = 0;
        while (x < size[0]) : (x += 1) {
            var sample: u32 = 0;
            var color = Vector(3, f32){ 0.0, 0.0, 0.0 };

            while (sample < spp) : (sample += 1) {
                var u = (@intToFloat(f32, x) + rng.float(f32)) / @intToFloat(f32, size[0]);
                var v = (@intToFloat(f32, y) + rng.float(f32)) / @intToFloat(f32, size[1]);

                var dir = lowerLeft + @splat(4, u) * right + @splat(4, v) * up - origin;
                var ray = Ray{ .origin = origin, .dir = dir };

                color += traceRay(ray, &spheres, maxBounces);
            }

            img[y * width + x] = Pixel{
                .r = @truncate(u8, @floatToInt(u32, pow(f32, color[0] / spp, 1.0 / gamma) * 255)),
                .g = @truncate(u8, @floatToInt(u32, pow(f32, color[1] / spp, 1.0 / gamma) * 255)),
                .b = @truncate(u8, @floatToInt(u32, pow(f32, color[2] / spp, 1.0 / gamma) * 255)),
            };
        }
    }

    try outputPixels(size, &img);
}
