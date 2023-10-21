const std = @import("std");
const zm = @import("zmath");
const printErr = std.io.getStdErr().writer().print;

const Random = std.rand.Random;
const DefaultRandom = std.rand.DefaultPrng;

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

    hittables: ?[]*Hittable,

    hittable: Hittable,

    fn init(allocator: std.mem.Allocator, aabb: AABB) BVHNode {
        return BVHNode{
            .allocator = allocator,
            .aabb = aabb,
            .children = null,
            .hittables = null,
            .hittable = Hittable{ .testHitFn = testHit, .aabbFn = aabbFn, .material = null },
        };
    }

    pub fn deinit(self: *BVHNode) void {
        if (self.children != null) {
            self.children.?[0].deinit();
            self.children.?[1].deinit();
            self.allocator.free(self.children.?);
        }
    }

    pub fn testHit(hittable: *const Hittable, r: *const Ray, minDist: f32, maxDist: f32) ?Hit {
        const self = @fieldParentPtr(BVHNode, "hittable", hittable);
        return self.testHitBVH(r, minDist, maxDist);
    }

    pub fn testHitBVH(self: *const BVHNode, r: *const Ray, minDist: f32, maxDist: f32) ?Hit {
        if (!self.aabb.overlaps(r, minDist, maxDist)) {
            return null;
        }

        if (self.children) |children| {
            var closestHit: ?Hit = null;
            var closestHitDist = maxDist;
            for (children) |*child| {
                var maybeHit = child.testHitBVH(r, minDist, closestHitDist);

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

        if (self.hittables == null) {
            return null;
        }

        var nearestHit: ?Hit = null;
        for (self.hittables.?) |hittable| {
            var maxDistance: f32 = maxDist;
            if (nearestHit) |hit| {
                maxDistance = @min(maxDistance, hit.rayFactor);
            }

            var maybeHit = hittable.testHit(r, 0.005, maxDistance);
            if (maybeHit) |hit| {
                nearestHit = hit;
                nearestHit.?.material = hittable.material;
            }
        }
        return nearestHit;
    }

    pub fn aabbFn(hittable: *const Hittable) AABB {
        const self = @fieldParentPtr(BVHNode, "hittable", hittable);
        return self.aabb;
    }
};

pub fn buildTLAS(allocator: std.mem.Allocator, bvhs: []*BVHNode) anyerror!BVHNode {
    var node = BVHNode.init(allocator, .{});
    node.children = try allocator.alloc(BVHNode, bvhs.len);

    var i: u32 = 0;
    for (bvhs) |bvh| {
        node.aabb = AABB.enclosingAABB(node.aabb, bvh.aabb);
        node.children.?[i] = bvh.*;
        i += 1;
    }

    return node;
}

fn triangleComparator(axisMask: @Vector(4, f32), a: Triangle, b: Triangle) bool {
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

fn hittableComparator(axisMask: @Vector(4, f32), a: *Hittable, b: *Hittable) bool {
    var minA: f32 = std.math.inf(f32);
    var minB: f32 = std.math.inf(f32);

    var aaabb = a.aabb();
    var baabb = b.aabb();

    var minMaskedA = aaabb.min * axisMask;
    var minMaskedB = baabb.min * axisMask;
    var maxMaskedA = aaabb.max * axisMask;
    var maxMaskedB = baabb.max * axisMask;

    minA = @min(minMaskedA[0] + minMaskedA[1] + minMaskedA[2] + minMaskedA[3], maxMaskedA[0] + maxMaskedA[1] + maxMaskedA[2] + maxMaskedA[3]);
    minB = @min(minMaskedB[0] + minMaskedB[1] + minMaskedB[2] + minMaskedB[3], maxMaskedB[0] + maxMaskedB[1] + maxMaskedB[2] + maxMaskedB[3]);

    return minA < minB;
}

//fn buildLeafBVH(allocator: std.mem.Allocator, triangles: []Triangle) anyerror!BVHNode {
fn buildLeafBVH(allocator: std.mem.Allocator, hittables: []*Hittable) anyerror!BVHNode {
    var node = BVHNode.init(allocator, .{});
    node.hittables = try allocator.alloc(*Hittable, hittables.len);
    node.aabb = hittables[0].aabb();

    var i: u32 = 0;
    for (hittables) |hittable| {
        node.aabb = AABB.enclosingAABB(node.aabb, hittable.aabb());
        node.hittables.?[i] = hittable;
        i += 1;
    }

    return node;
}

pub fn buildSimpleBVH(rng: Random, allocator: std.mem.Allocator, hittables: []*Hittable, remainingBVHDepth: u32) anyerror!BVHNode {
    if (remainingBVHDepth <= 0 or hittables.len <= 4) {
        return buildLeafBVH(allocator, hittables);
    }

    var randomF = rng.float(f32);
    var sortAxis = @Vector(4, f32){ 0.0, 0.0, 1.0, 0.0 };
    if (randomF <= 0.33) {
        sortAxis = @Vector(4, f32){ 1.0, 0.0, 0.0, 0.0 };
    } else if (randomF <= 0.66) {
        sortAxis = @Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 };
    }
    //std.sort.sort(*Hittable, hittables, sortAxis, hittableComparator);
    std.mem.sort(*Hittable, hittables, sortAxis, hittableComparator);

    var node = BVHNode.init(allocator, .{});
    node.children = try allocator.alloc(BVHNode, 2);
    node.children.?[0] = try buildSimpleBVH(rng, allocator, hittables[0 .. hittables.len / 2], remainingBVHDepth - 1);
    node.children.?[1] = try buildSimpleBVH(rng, allocator, hittables[hittables.len / 2 ..], remainingBVHDepth - 1);
    node.aabb = node.children.?[0].aabb.enclosingAABB(node.children.?[1].aabb);

    return node;
}

const SAHBucket = struct {
    triangleCount: usize,
    aabb: AABB,
};

//pub fn buildSAHBVH(rng: Random, allocator: std.mem.Allocator, triangles: []Triangle, bucketCount: u32, remainingBVHDepth: u32) anyerror!BVHNode {
//    if (remainingBVHDepth <= 0) {
//        std.debug.print("Reached max depth, triangle count: {}\n", .{triangles.len});
//    }
//    if (remainingBVHDepth <= 0 or triangles.len <= 4) {
//        return buildLeafBVH(allocator, triangles);
//    }
//
//    // Centroid of triangle cluster
//    var centroidAABB = AABB.fromPoints(triangles[0].centroid(), triangles[1].centroid());
//    var i: usize = 2;
//    while (i < triangles.len) : (i += 1) {
//        centroidAABB = centroidAABB.extend(triangles[i].centroid());
//    }
//
//    // We split along the longest AABB side for now
//    const longestDimension = centroidAABB.longestDimension();
//
//    // Calculate buckets
//    var buckets: []SAHBucket = try allocator.alloc(SAHBucket, bucketCount);
//    const longestSide = centroidAABB.max[longestDimension] - centroidAABB.min[longestDimension];
//    const bucketWidth = longestSide / @intToFloat(f32, bucketCount);
//    defer allocator.free(buckets);
//    i = 0;
//    while (i < bucketCount) : (i += 1) {
//        buckets[i].triangleCount = 0;
//    }
//
//    for (triangles) |triangle| {
//        const offset = triangle.centroid()[longestDimension] - centroidAABB.min[longestDimension];
//        const bucketIndex: usize = @min(bucketCount - 1, @floatToInt(usize, offset / bucketWidth));
//        if (buckets[bucketIndex].triangleCount == 0) {
//            buckets[bucketIndex].aabb = triangle.hittable.aabb();
//        } else {
//            buckets[bucketIndex].aabb = buckets[bucketIndex].aabb.enclosingAABB(triangle.hittable.aabb());
//        }
//        buckets[bucketIndex].triangleCount += 1;
//    }
//
//    // Calculate costs of different splits and find the minimal one
//    var costAtSplit: []f32 = try allocator.alloc(f32, bucketCount);
//    defer allocator.free(costAtSplit);
//    var minSplitAfterBucket: usize = 0;
//
//    i = 0;
//    while (i < bucketCount - 1) : (i += 1) {
//        var bucketAABBs: [2]AABB = .{ buckets[0].aabb, buckets[bucketCount - 1].aabb };
//        var triangleCounts: [2]usize = .{ 0, 0 };
//
//        var j: usize = 0;
//        while (j <= i) : (j += 1) {
//            bucketAABBs[0] = bucketAABBs[0].enclosingAABB(buckets[j].aabb);
//            triangleCounts[0] += buckets[j].triangleCount;
//        }
//
//        while (j < bucketCount) : (j += 1) {
//            bucketAABBs[1] = bucketAABBs[1].enclosingAABB(buckets[j].aabb);
//            triangleCounts[1] += buckets[j].triangleCount;
//        }
//
//        costAtSplit[i] = 0.125 +
//            (@intToFloat(f32, triangleCounts[0]) * bucketAABBs[0].surfaceArea() + @intToFloat(f32, triangleCounts[1]) * bucketAABBs[1].surfaceArea()) /
//            centroidAABB.surfaceArea();
//        if (costAtSplit[i] < costAtSplit[minSplitAfterBucket]) {
//            minSplitAfterBucket = i;
//        }
//    }
//
//    // Split triangles on the bucket boundary
//    var pivotValue = centroidAABB.min[longestDimension] + @intToFloat(f32, minSplitAfterBucket + 1) * bucketWidth;
//
//    // Partition triangles around the pivot
//    i = 0;
//    var j: usize = triangles.len - 1;
//    while (i < j) {
//        while (i < triangles.len and triangles[i].centroid()[longestDimension] <= pivotValue) : (i += 1) {}
//        while (j > 0 and triangles[j].centroid()[longestDimension] > pivotValue) : (j -= 1) {}
//
//        if (i < j) {
//            var swapped = triangles[i];
//            triangles[i] = triangles[j];
//            triangles[j] = swapped;
//
//            i += 1;
//            j -= 1;
//        }
//    }
//    var leftPartitionSize = j + 1;
//
//    // Recurse down
//    var node = BVHNode.init(allocator, .{});
//    node.children = try allocator.alloc(BVHNode, 2);
//    node.children.?[0] = try buildSAHBVH(rng, allocator, triangles[0..leftPartitionSize], bucketCount, remainingBVHDepth - 1);
//    node.children.?[1] = try buildSAHBVH(rng, allocator, triangles[leftPartitionSize..], bucketCount, remainingBVHDepth - 1);
//
//    node.aabb = node.children.?[0].aabb.enclosingAABB(node.children.?[1].aabb);
//    return node;
//}
