const std = @import("std");
const zm = @import("zmath");
const printErr = std.io.getStdErr().writer().print;

const Random = std.rand.Random;
const DefaultRandom = std.rand.DefaultPrng;
const Vector = std.meta.Vector;

const Ray = @import("ray.zig").Ray;
const Hit = @import("ray.zig").Hit;
const Hittable = @import("hittables.zig").Hittable;
const Triangle = @import("hittables.zig").Triangle;
const AABB = @import("hittables.zig").AABB;

const Material = @import("materials.zig").Material;

pub const BVHNode = struct {
    allocator: std.mem.Allocator,
    aabb: AABB,
    children: ?[]BVHNode,
    triangles: ?[]*Triangle,

    hittable: Hittable,

    fn init(allocator: std.mem.Allocator, aabb: AABB) BVHNode {
        return BVHNode{
            .allocator = allocator,
            .aabb = aabb,
            .children = null,
            .triangles = null,
            .hittable = Hittable{ .testHitFn = testHit, .aabbFn = aabbFn },
        };
    }

    pub fn deinit(self: *BVHNode) void {
        if (self.triangles != null) {
            self.allocator.free(self.triangles.?);
        }

        if (self.children != null) {
            self.children.?[0].deinit();
            self.children.?[1].deinit();
            self.allocator.free(self.children.?);
        }
    }

    pub fn testHit(hittable: *const Hittable, r: Ray, minDist: f32, maxDist: f32) ?Hit {
        const self = @fieldParentPtr(BVHNode, "hittable", hittable);

        if (!self.aabb.overlaps(r, minDist, maxDist)) {
            return null;
        }

        if (self.children) |children| {
            var closestHit: ?Hit = null;
            var closestHitDist = maxDist;
            for (children) |child| {
                var maybeHit = child.hittable.testHit(r, minDist, closestHitDist);

                if (maybeHit) |hit| {
                    if (hit.rayFactor < closestHitDist) {
                        closestHit = hit;
                        closestHitDist = hit.rayFactor;
                    }
                }
            }

            if (closestHit) |_| {
                return closestHit;
            }
        }

        if (self.triangles == null) {
            return null;
            //unreachable;
        }

        var nearestHit: ?Hit = null;
        for (self.triangles.?) |triangle| {
            var maxDistance: f32 = maxDist;
            if (nearestHit) |hit| {
                maxDistance = @min(maxDistance, hit.rayFactor);
            }

            var maybeHit = triangle.hittable.testHit(r, 0.005, maxDistance);
            if (maybeHit) |hit| {
                nearestHit = hit;
                nearestHit.?.material = triangle.material;
            }
        }
        return nearestHit;
    }

    pub fn aabbFn(hittable: *const Hittable) AABB {
        const self = @fieldParentPtr(BVHNode, "hittable", hittable);
        return self.aabb;
    }
};

fn triangleComparator(axisMask: Vector(4, f32), a: Triangle, b: Triangle) bool {
    var minA: f32 = std.math.inf(f32);
    var minB: f32 = std.math.inf(f32);

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        var maskedA = a.points[i] * axisMask;
        var maskedB = b.points[i] * axisMask;

        minA = @min(minA, maskedA[0] + maskedA[1] + maskedA[2] + maskedA[3]);
        minB = @min(minB, maskedB[0] + maskedB[1] + maskedB[2] + maskedB[3]);
    }

    return minA < minB;
}

// TODO: TLAS from model BLASes
pub fn BuildSimpleBVH(rng: Random, allocator: std.mem.Allocator, triangles: []Triangle, remainingBVHDepth: u32) anyerror!BVHNode {
    var node = BVHNode.init(allocator, .{});
    if (remainingBVHDepth <= 0 or triangles.len <= 4) {
        node.triangles = try allocator.alloc(*Triangle, triangles.len);
        node.aabb = triangles[0].hittable.aabb();

        var i: u32 = 0;
        for (triangles) |*triangle| {
            node.aabb = AABB.enclosingAABB(node.aabb, triangle.hittable.aabb());
            node.triangles.?[i] = triangle;
            i += 1;
        }

        return node;
    }

    // TODO: Idiotic, but works. Replace with SAH
    //var sortAxis = switch (rng.float(f32)) {
    //    0.0...0.33 => Vector(4, f32){ 1.0, 0.0, 0.0, 0.0 },
    //    0.33...0.66 => Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 },
    //    0.66...1.00 => Vector(4, f32){ 0.0, 0.0, 1.0, 0.0 },
    //    else => unreachable,
    //};
    var randomF = rng.float(f32);
    var sortAxis = Vector(4, f32){ 0.0, 0.0, 1.0, 0.0 };
    if (randomF <= 0.33) {
        sortAxis = Vector(4, f32){ 1.0, 0.0, 0.0, 0.0 };
    } else if (randomF <= 0.66) {
        sortAxis = Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 };
    }
    std.sort.sort(Triangle, triangles, sortAxis, triangleComparator);

    node.children = try allocator.alloc(BVHNode, 2);
    node.children.?[0] = try BuildSimpleBVH(rng, allocator, triangles[0 .. triangles.len / 2], remainingBVHDepth - 1);
    node.children.?[1] = try BuildSimpleBVH(rng, allocator, triangles[triangles.len / 2 ..], remainingBVHDepth - 1);
    node.aabb = AABB.enclosingAABB(node.children.?[0].aabb, node.children.?[1].aabb);

    return node;
}
