const std = @import("std");
const zm = @import("zmath");
const zmesh = @import("zmesh");
const print = std.io.getStdOut().writer().print;
const Vector = std.meta.Vector;
const DefaultRandom = std.rand.DefaultPrng;
const ArrayList = std.ArrayList;

const Material = @import("materials.zig").Material;
const Triangle = @import("hittables.zig").Triangle;
const BVH = @import("bvh.zig");

pub const Model = struct {
    // TODO: split into meshes and build individual BVH for BLAS
    allocator: std.mem.Allocator,
    triangles: ArrayList(Triangle),
    bvh: BVH.BVHNode,

    pub fn init(allocator: std.mem.Allocator, material: *const Material, path: [:0]const u8) Model {
        const data = zmesh.io.parseAndLoadFile(path) catch unreachable;
        defer zmesh.io.cgltf.free(data);

        var model = Model{ .allocator = allocator, .triangles = ArrayList(Triangle).init(allocator), .bvh = undefined };

        var i: u32 = 0;
        while (i < data.nodes_count) : (i += 1) {
            var j: u32 = 0;

            var node = data.nodes.?[i];
            if (node.mesh == null) continue;
            var mesh = node.mesh.?;

            var nodeTransform = node.transformWorld();
            var transform = zm.loadMat(nodeTransform[0..]);
            while (j < mesh.primitives_count) : (j += 1) {
                if (mesh.primitives[j].indices) |indicesAccessor| {
                    //print("{} {} has indices: {}, type: {}\n", .{ i, j, indicesAccessor.count, indicesAccessor.type }) catch unreachable;

                    var indices: []f32 = allocator.alloc(f32, indicesAccessor.count) catch unreachable;
                    defer allocator.free(indices);
                    _ = indicesAccessor.unpackFloats(indices);

                    var k: u32 = 0;
                    while (k < mesh.primitives[j].attributes_count) : (k += 1) {
                        //print("{} {}, is sparse: {}\n", .{ k, mesh.primitives[j].attributes[k].type, mesh.primitives[j].attributes[k].data.is_sparse }) catch unreachable;
                        if (mesh.primitives[j].attributes[k].type != .position) {
                            continue;
                        }

                        var positionCount = mesh.primitives[j].attributes[k].data.type.numComponents() * mesh.primitives[j].attributes[k].data.count;
                        var positions: []f32 = allocator.alloc(f32, positionCount) catch unreachable;
                        defer allocator.free(positions);
                        _ = mesh.primitives[j].attributes[k].data.unpackFloats(positions);

                        var l: u32 = 0;
                        while (l < indices.len) : (l += 3) {
                            var a = Vector(4, f32){ positions[@floatToInt(u32, indices[l]) * 3], positions[@floatToInt(u32, indices[l]) * 3 + 1], positions[@floatToInt(u32, indices[l]) * 3 + 2], 1 };
                            var b = Vector(4, f32){ positions[@floatToInt(u32, indices[l + 1]) * 3], positions[@floatToInt(u32, indices[l + 1]) * 3 + 1], positions[@floatToInt(u32, indices[l + 1]) * 3 + 2], 1 };
                            var c = Vector(4, f32){ positions[@floatToInt(u32, indices[l + 2]) * 3], positions[@floatToInt(u32, indices[l + 2]) * 3 + 1], positions[@floatToInt(u32, indices[l + 2]) * 3 + 2], 1 };

                            a = zm.mul(a, transform);
                            a[3] = 0;

                            b = zm.mul(b, transform);
                            b[3] = 0;

                            c = zm.mul(c, transform);
                            c[3] = 0;

                            model.triangles.append(Triangle.init(material, a, b, c)) catch unreachable;
                        }
                    }
                }
            }
        }

        var rng = DefaultRandom.init(0).random();
        model.bvh = BVH.BuildSimpleBVH(rng, allocator, model.triangles.items, 16);
        return model;
    }

    pub fn deinit(self: *Model) void {
        self.triangles.deinit();
        self.bvh.deinit();
    }
};
