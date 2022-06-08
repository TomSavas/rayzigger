const std = @import("std");
const Vector = std.meta.Vector;

const zm = @import("zmath");

const Ray = @import("ray.zig").Ray;
const Hit = @import("ray.zig").Hit;
const Material = @import("materials.zig").Material;

pub const Hittable = struct {
    testHitFn: fn (*const Hittable, Ray, f32, f32) ?Hit,

    pub fn testHit(self: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        return self.testHitFn(self, r, minDist, maxDist);
    }
};

pub const Sphere = struct {
    center: Vector(4, f32),
    radius: f32,
    hittable: Hittable,
    material: *const Material,

    pub fn init(mat: *const Material, center: Vector(4, f32), radius: f32) Sphere {
        return Sphere{ .material = mat, .center = center, .radius = radius, .hittable = Hittable{ .testHitFn = testHit } };
    }

    pub fn testHit(hittable: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        const self = @fieldParentPtr(Sphere, "hittable", hittable);

        var toOrigin = r.origin - self.center;
        var a = zm.dot3(r.dir, r.dir)[1];
        //var b = 2.0 * zm.dot3(r.dir, toOrigin)[1];
        var b = 2.0 * zm.dot3(toOrigin, r.dir)[1];
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

        var hitFrontFace = true;
        if (zm.dot3(r.dir, normal)[0] >= 0.0) {
            normal = -normal;
            hitFrontFace = false;
        }

        return Hit{ .location = location, .normal = normal, .rayFactor = x, .hitFrontFace = hitFrontFace };
    }
};
