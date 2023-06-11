const std = @import("std");
const Vector = std.meta.Vector;

const zm = @import("zmath");

const Ray = @import("ray.zig").Ray;
const Hit = @import("ray.zig").Hit;
const Material = @import("materials.zig").Material;

pub const AABB = struct {
    min: Vector(4, f32) = Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 },
    max: Vector(4, f32) = Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 },

    pub fn fromPoints(a: Vector(4, f32), b: Vector(4, f32)) AABB {
        return AABB{
            .min = .{
                @min(a[0], b[0]),
                @min(a[1], b[1]),
                @min(a[2], b[2]),
                0.0,
            },
            .max = .{
                @max(a[0], b[0]),
                @max(a[1], b[1]),
                @max(a[2], b[2]),
                0.0,
            },
        };
    }

    pub fn enclosingAABB(self: AABB, b: AABB) AABB {
        return AABB{
            .min = .{
                @min(self.min[0], b.min[0]),
                @min(self.min[1], b.min[1]),
                @min(self.min[2], b.min[2]),
                0.0,
            },
            .max = .{
                @max(self.max[0], b.max[0]),
                @max(self.max[1], b.max[1]),
                @max(self.max[2], b.max[2]),
                0.0,
            },
        };
    }

    pub fn extend(self: AABB, point: Vector(4, f32)) AABB {
        return AABB{
            .min = .{
                @min(self.min[0], point[0]),
                @min(self.min[1], point[1]),
                @min(self.min[2], point[2]),
                0.0,
            },
            .max = .{
                @max(self.max[0], point[0]),
                @max(self.max[1], point[1]),
                @max(self.max[2], point[2]),
                0.0,
            },
        };
    }

    pub fn overlaps(self: AABB, r: Ray, minDist: f32, maxDist: f32) bool {
        var i: u32 = 0;

        var tmin: f32 = minDist;
        var tmax: f32 = maxDist;
        while (i < 3) : (i += 1) {
            //if (self.max[i] - self.min[i] < 0.0001) continue;

            var a = self.min[i] - r.origin[i];
            var b = self.max[i] - r.origin[i];

            var t0 = @min(a, b);
            var t1 = @max(a, b);

            if (r.dir[i] < 0) std.mem.swap(f32, &t0, &t1);

            tmin = @max(t0 / r.dir[i], tmin);
            tmax = @min(t1 / r.dir[i], tmax);

            if (tmax <= tmin) return false;
        }
        return true;
    }

    pub fn longestDimension(self: AABB) usize {
        // Doesn't include w!!!
        var maxLength = self.max[0] - self.min[0];
        var maxDimensionIndex: usize = 0;

        var i: usize = 1;
        while (i < 4) : (i += 1) {
            var length = self.max[i] - self.min[i];
            if (length > maxLength) {
                maxDimensionIndex = i;
                maxLength = length;
            }
        }

        return maxDimensionIndex;
    }

    pub fn surfaceArea(self: AABB) f32 {
        // Doesn't include w!!!
        var sizes: [3]f32 = .{ self.max[0] - self.min[0], self.max[1] - self.min[1], self.max[2] - self.min[2] };
        return 2.0 * (sizes[0] * sizes[1] + sizes[0] * sizes[2] + sizes[1] * sizes[2]);
    }
};

pub const Hittable = struct {
    testHitFn: *const fn (*const Hittable, Ray, f32, f32) ?Hit,
    aabbFn: *const fn (*const Hittable) AABB,

    pub fn testHit(self: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        return self.testHitFn(self, r, minDist, maxDist);
    }

    pub fn aabb(self: *const Hittable) AABB {
        return self.aabbFn(self);
    }
};

pub const Sphere = struct {
    center: Vector(4, f32),
    radius: f32,
    hittable: Hittable,
    material: *const Material,

    pub fn init(mat: *const Material, center: Vector(4, f32), radius: f32) Sphere {
        return Sphere{ .material = mat, .center = center, .radius = radius, .hittable = Hittable{ .testHitFn = testHit, .aabbFn = aabb } };
    }

    pub fn testHit(hittable: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        const self = @fieldParentPtr(Sphere, "hittable", hittable);

        var toOrigin = r.origin - self.center;
        var a = zm.dot3(r.dir, r.dir)[1];
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

        return Hit{ .location = location, .normal = normal, .rayFactor = x, .hitFrontFace = hitFrontFace, .uv = .{} };
    }

    pub fn aabb(hittable: *const Hittable) AABB {
        const self = @fieldParentPtr(Sphere, "hittable", hittable);

        var radiusVec = Vector(4, f32){ self.radius, self.radius, self.radius, 0.0 };
        return AABB{ .min = self.center - radiusVec, .max = self.center + radiusVec };
    }
};

pub const Triangle = struct {
    points: [3]Vector(4, f32),
    uvs: [3]Vector(2, f32),

    normal: Vector(4, f32),
    // As in "normal * p = d" plane equation
    d: f32,

    hittable: Hittable,
    material: *const Material,

    pub fn init(mat: *const Material, points: [3]Vector(4, f32), uvs: [3]Vector(2, f32)) Triangle {
        var edge0 = points[1] - points[0];
        var edge1 = points[2] - points[0];
        var normal = zm.normalize3(zm.cross3(edge0, edge1));
        var d = zm.dot3(normal, points[0])[0];

        return Triangle{ .material = mat, .points = points, .uvs = uvs, .normal = normal, .d = d, .hittable = Hittable{ .testHitFn = testHit, .aabbFn = aabb } };
    }

    fn barycentric(self: Triangle, p: Vector(4, f32)) Vector(4, f32) {
        var areaABC = zm.dot3(self.normal, zm.cross3((self.points[1] - self.points[0]), (self.points[2] - self.points[0])))[0];
        var areaPBC = zm.dot3(self.normal, zm.cross3((self.points[1] - p), (self.points[2] - p)))[0];
        var areaPCA = zm.dot3(self.normal, zm.cross3((self.points[2] - p), (self.points[0] - p)))[0];

        var x = areaPBC / areaABC;
        var y = areaPCA / areaABC;
        var z = 1.0 - x - y;
        return Vector(4, f32){ x, y, z, 0.0 };
    }

    pub fn centroid(self: Triangle) Vector(4, f32) {
        const a = self.hittable.aabb();
        const len = a.max - a.min;

        return .{ a.min[0] + len[0] / 2.0, a.min[1] + len[1] / 2.0, a.min[2] + len[2] / 2.0, a.min[3] + len[3] / 2.0 };
    }

    pub fn testHit(hittable: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        const self = @fieldParentPtr(Triangle, "hittable", hittable);

        var t = (self.d - zm.dot3(self.normal, r.origin)[0]) / (zm.dot3(r.dir, self.normal)[0]);
        if (t < 0 or t < minDist or t > maxDist) {
            return null;
        }

        var bary = self.barycentric(r.at(t));
        if (bary[0] > 1 or bary[0] < 0 or bary[1] > 1 or bary[1] < 0 or bary[2] > 1 or bary[2] < 0) {
            return null;
        }

        var normal = self.normal;
        var hitFrontFace = true;
        if (zm.dot3(normal, r.dir)[0] >= 0) {
            normal = -normal;
            hitFrontFace = false;
        }

        var uv = self.uvs[0] * @splat(2, bary[0]) + self.uvs[1] * @splat(2, bary[1]) + self.uvs[2] * @splat(2, bary[2]);

        return Hit{ .location = r.at(t), .normal = normal, .rayFactor = t, .hitFrontFace = hitFrontFace, .uv = uv };
    }

    pub fn aabb(hittable: *const Hittable) AABB {
        const self = @fieldParentPtr(Triangle, "hittable", hittable);

        return AABB{
            .min = .{
                @min(self.points[0][0], @min(self.points[1][0], self.points[2][0])),
                @min(self.points[0][1], @min(self.points[1][1], self.points[2][1])),
                @min(self.points[0][2], @min(self.points[1][2], self.points[2][2])),
                0.0,
            },
            .max = .{
                @max(self.points[0][0], @max(self.points[1][0], self.points[2][0])),
                @max(self.points[0][1], @max(self.points[1][1], self.points[2][1])),
                @max(self.points[0][2], @max(self.points[1][2], self.points[2][2])),
                0.0,
            },
        };
    }
};
