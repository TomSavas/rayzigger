const std = @import("std");
const zm = @import("zmath");
const print = std.io.getStdOut().writer().print;
const print_err = std.io.getStdErr().writer().print;
const Vector = std.meta.Vector;

const Ray = @import("ray.zig").Ray;

const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
};

fn output_ppm_header(size: Vector(2, u32)) anyerror!void {
    try print("P3\n", .{});
    try print("{} {}\n", .{ size[0], size[1] });
    try print("{}\n", .{255});
}

fn output_pixels(size: Vector(2, u32), pixels: []Pixel) anyerror!void {
    const pixel_count = size[0] * size[1];

    var x: usize = 0;
    var y: usize = size[1];
    while (y > 0) {
        try print_err("Rendering: {}/{}\n", .{ x * (size[1] - y), pixel_count });

        y -= 1;
        x = 0;
        while (x < size[0]) : (x += 1) {
            var index = y * size[0] + x;
            try print("{} {} {}\n", pixels[index]);
        }
    }
}

fn background(r: Ray) Pixel {
    var y = zm.normalize3(r.dir)[1];
    // -1; 1 -> 0; 1
    y = (y + 1.0) * 0.5;

    var percentage = 0.2 + y * 0.8;

    const white = Vector(3, f32){ 1.0, 1.0, 1.0 };
    const blue = Vector(3, f32){ 0.5, 0.7, 1.0 };
    var color = zm.lerp(white, blue, percentage);

    return Pixel{ .r = @truncate(u8, @floatToInt(u32, color[0] * 255.0)), .g = @truncate(u8, @floatToInt(u32, color[1] * 255.0)), .b = @truncate(u8, @floatToInt(u32, color[2] * 255.0)) };
}

const Hittable = struct {
    testHitFn: fn (*const Hittable, Ray) ?Hit,

    pub fn testHit(self: *const Hittable, r: Ray) ?Hit {
        return self.testHitFn(self, r);
    }
};

const Sphere = struct {
    center: Vector(4, f32),
    radius: f32,
    hittable: Hittable,

    pub fn init(center: Vector(4, f32), radius: f32) Sphere {
        return Sphere{ .center = center, .radius = radius, .hittable = Hittable{ .testHitFn = testHit } };
    }

    pub fn testHit(hittable: *const Hittable, r: Ray) ?Hit {
        const self = @fieldParentPtr(Sphere, "hittable", hittable);

        var to_origin = r.origin - self.center;
        var a = zm.dot3(r.dir, r.dir)[1];
        var b = 2.0 * zm.dot3(r.dir, to_origin)[1];
        var c = zm.dot3(to_origin, to_origin)[1] - self.radius * self.radius;

        var discriminant = b * b - 4 * a * c;
        if (discriminant < 0)
            return null;

        var x = (-b - @sqrt(discriminant)) / (2.0 * a);
        var location = r.at(x);
        var normal = zm.normalize3(location - self.center);
        return Hit{ .location = location, .normal = normal, .ray_factor = x };
    }
};

const Hit = struct {
    location: Vector(4, f32),
    normal: Vector(4, f32),
    ray_factor: f32,
};

const NO_HIT: f32 = -1.0;
fn hit_sphere(r: Ray, sphere_center: Vector(4, f32), radius: f32) ?Hit {
    var to_origin = r.origin - sphere_center;
    var a = zm.dot3(r.dir, r.dir)[1];
    var b = 2.0 * zm.dot3(r.dir, to_origin)[1];
    var c = zm.dot3(to_origin, to_origin)[1] - radius * radius;

    var discriminant = b * b - 4 * a * c;
    if (discriminant < 0)
        return null;

    var x = (-b - @sqrt(discriminant)) / (2.0 * a);
    var location = r.at(x);
    var normal = zm.normalize3(location - sphere_center);
    return Hit{ .location = location, .normal = normal, .ray_factor = x };
}

pub fn main() anyerror!void {
    const aspect_ratio = 16.0 / 9.0;
    const width = 512;
    const size = Vector(2, u32){ width, width / aspect_ratio };
    const pixel_count = size[0] * size[1];

    const viewport_height = 2.0;
    const viewport_size = Vector(2, f32){ viewport_height * aspect_ratio, viewport_height };
    const focal_length = 1.0;

    const origin = Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 };
    const forward = Vector(4, f32){ 0.0, 0.0, -focal_length, 0.0 };
    const right = Vector(4, f32){ viewport_size[0], 0.0, 0.0, 0.0 };
    const up = Vector(4, f32){ 0.0, viewport_size[1], 0.0, 0.0 };
    const lower_left = origin - (right / Vector(4, f32){ 2.0, 2.0, 2.0, 2.0 }) - (up / Vector(4, f32){ 2.0, 2.0, 2.0, 2.0 }) + forward;

    var spheres = [_]Sphere{
        Sphere.init(Vector(4, f32){ 0.0, -100.5, -1.0, 0.0 }, 100),
        Sphere.init(Vector(4, f32){ 0.0, 0.0, -1.0, 0.0 }, 0.5),
    };
    _ = spheres;

    try output_ppm_header(size);

    var img: [pixel_count]Pixel = undefined;
    var x: usize = 0;
    var y: usize = size[1];

    while (y > 0) {
        y -= 1;
        x = 0;
        while (x < size[0]) : (x += 1) {
            var u = @intToFloat(f32, x) / @intToFloat(f32, size[0]);
            var v = @intToFloat(f32, y) / @intToFloat(f32, size[1]);

            var dir = lower_left + @splat(4, u) * right + @splat(4, v) * up - origin;
            var ray = Ray{ .origin = origin, .dir = dir };

            var color = background(ray);
            var nearestHit: ?Hit = null;
            for (spheres) |sphere| {
                var maybe_hit = sphere.hittable.testHit(ray);
                if (maybe_hit) |hit| {
                    const nearerHit: bool = nearestHit == null or hit.ray_factor < nearestHit.?.ray_factor;
                    if (nearerHit) {
                        nearestHit = hit;
                    }
                }
            }

            if (nearestHit) |hit| {
                color = Pixel{
                    .r = @truncate(u8, @floatToInt(u32, (hit.normal[0] + 1.0) * 0.5 * 255)),
                    .g = @truncate(u8, @floatToInt(u32, (hit.normal[1] + 1.0) * 0.5 * 255)),
                    .b = @truncate(u8, @floatToInt(u32, (hit.normal[2] + 1.0) * 0.5 * 255)),
                };
            }

            img[y * width + x] = color;
        }
    }

    try output_pixels(size, &img);
}
