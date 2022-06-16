const std = @import("std");
const zm = @import("zmath");
const zmesh = @import("zmesh");
const print = std.io.getStdOut().writer().print;
const Vector = std.meta.Vector;
const DefaultRandom = std.rand.DefaultPrng;
const ArrayList = std.ArrayList;

const Material = @import("materials.zig").Material;
const LambertianTexMat = @import("materials.zig").LambertianTexMat;
const Triangle = @import("hittables.zig").Triangle;
const BVH = @import("bvh.zig");

pub const Model = struct {
    // TODO: split into meshes and build individual BVH for BLAS
    allocator: std.mem.Allocator,
    triangles: ArrayList(Triangle),
    bvh: BVH.BVHNode,

    pub fn init(allocator: std.mem.Allocator, material: *const Material, path: [:0]const u8) Model {
        var chunks: [64][]const u8 = undefined;
        var chunkCount: u32 = 0;
        var iterator = std.mem.split(u8, path, "/");
        while (iterator.next()) |chunk| {
            print("{s}\n", .{chunk}) catch unreachable;
            chunks[chunkCount] = chunk;
            chunkCount += 1;
        }
        var filepathRoot = std.mem.join(allocator, "/", chunks[0 .. chunkCount - 1]) catch unreachable;
        defer allocator.free(filepathRoot);

        print("{}\n", .{chunkCount}) catch unreachable;
        print("{s}\n", .{filepathRoot}) catch unreachable;

        var filepath = std.fs.cwd().realpathAlloc(allocator, path) catch unreachable;
        var terminatedFilepath: []u8 = allocator.realloc(filepath, filepath.len + 1) catch unreachable;
        terminatedFilepath[terminatedFilepath.len - 1] = 0;

        const data = zmesh.io.parseAndLoadFile(terminatedFilepath[0..filepath.len :0]) catch unreachable;
        allocator.free(terminatedFilepath);
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
                    print("{} {} has indices: {}, type: {}\n", .{ i, j, indicesAccessor.count, indicesAccessor.type }) catch unreachable;

                    var indices: []f32 = allocator.alloc(f32, indicesAccessor.count) catch unreachable;
                    defer allocator.free(indices);
                    _ = indicesAccessor.unpackFloats(indices);

                    var positions: []f32 = undefined;
                    defer allocator.free(positions);
                    var uvs: []f32 = undefined;
                    defer allocator.free(uvs);

                    var gltfMat: ?*LambertianTexMat = null;
                    if (mesh.primitives[j].material) |mat| {
                        if (mat.has_pbr_metallic_roughness != 0) {
                            print("mat: {}\n", .{mat.pbr_metallic_roughness}) catch unreachable;
                            if (mat.pbr_metallic_roughness.base_color_texture.texture) |tex| {
                                if (tex.image) |img| {
                                    if (img.uri) |uri| {
                                        print("img uri: {s}\n", .{uri}) catch unreachable;

                                        var uriLen = std.mem.indexOfSentinel(u8, 0, uri);
                                        var uriSlice = uri[0..uriLen];

                                        var cs: [2][]u8 = .{ filepathRoot, uriSlice };
                                        var p = std.mem.join(allocator, "/", cs[0..]) catch unreachable;

                                        var fp = std.fs.cwd().realpathAlloc(allocator, p) catch unreachable;
                                        print("calculated path: {s}\n", .{fp}) catch unreachable;

                                        gltfMat = allocator.create(LambertianTexMat) catch unreachable;
                                        gltfMat.?.* = LambertianTexMat.init(fp);

                                        allocator.free(p);
                                        allocator.free(fp);
                                    }
                                }
                            }
                        }
                    }

                    var k: u32 = 0;
                    while (k < mesh.primitives[j].attributes_count) : (k += 1) {
                        var attribute = &mesh.primitives[j].attributes[k];

                        var attributeCount = attribute.data.type.numComponents() * attribute.data.count;
                        switch (attribute.type) {
                            .position => {
                                positions = allocator.alloc(f32, attributeCount) catch unreachable;
                                _ = attribute.data.unpackFloats(positions);
                            },
                            .texcoord => {
                                uvs = allocator.alloc(f32, attributeCount) catch unreachable;
                                _ = attribute.data.unpackFloats(uvs);
                            },
                            else => {},
                        }
                    }

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

                        var uva = Vector(2, f32){ uvs[@floatToInt(u32, indices[l]) * 2], uvs[@floatToInt(u32, indices[l]) * 2 + 1] };
                        var uvb = Vector(2, f32){ uvs[@floatToInt(u32, indices[l + 1]) * 2], uvs[@floatToInt(u32, indices[l + 1]) * 2 + 1] };
                        var uvc = Vector(2, f32){ uvs[@floatToInt(u32, indices[l + 2]) * 2], uvs[@floatToInt(u32, indices[l + 2]) * 2 + 1] };

                        //model.triangles.append(Triangle.init(material, a, b, c, .{ uva, uvb, uvc })) catch unreachable;
                        if (gltfMat) |mat| {
                            model.triangles.append(Triangle.init(&mat.material, a, b, c, .{ uva, uvb, uvc })) catch unreachable;
                        } else {
                            model.triangles.append(Triangle.init(material, a, b, c, .{ uva, uvb, uvc })) catch unreachable;
                        }
                    }

                    //var k: u32 = 0;
                    //while (k < mesh.primitives[j].attributes_count) : (k += 1) {
                    //    var positionCount = mesh.primitives[j].attributes[k].data.type.numComponents() * mesh.primitives[j].attributes[k].data.count;

                    //    print("{} {}, is sparse: {}, components: {}, count: {}, total count: {}\n", .{ k, mesh.primitives[j].attributes[k].type, mesh.primitives[j].attributes[k].data.is_sparse, mesh.primitives[j].attributes[k].data.type.numComponents(), mesh.primitives[j].attributes[k].data.count, positionCount }) catch unreachable;
                    //    if (mesh.primitives[j].attributes[k].type != .position) {
                    //        continue;
                    //    }

                    //    //var positionCount = mesh.primitives[j].attributes[k].data.type.numComponents() * mesh.primitives[j].attributes[k].data.count;
                    //    var positions: []f32 = allocator.alloc(f32, positionCount) catch unreachable;
                    //    defer allocator.free(positions);
                    //    _ = mesh.primitives[j].attributes[k].data.unpackFloats(positions);

                    //    var l: u32 = 0;
                    //    while (l < indices.len) : (l += 3) {
                    //        var a = Vector(4, f32){ positions[@floatToInt(u32, indices[l]) * 3], positions[@floatToInt(u32, indices[l]) * 3 + 1], positions[@floatToInt(u32, indices[l]) * 3 + 2], 1 };
                    //        var b = Vector(4, f32){ positions[@floatToInt(u32, indices[l + 1]) * 3], positions[@floatToInt(u32, indices[l + 1]) * 3 + 1], positions[@floatToInt(u32, indices[l + 1]) * 3 + 2], 1 };
                    //        var c = Vector(4, f32){ positions[@floatToInt(u32, indices[l + 2]) * 3], positions[@floatToInt(u32, indices[l + 2]) * 3 + 1], positions[@floatToInt(u32, indices[l + 2]) * 3 + 2], 1 };

                    //        a = zm.mul(a, transform);
                    //        a[3] = 0;

                    //        b = zm.mul(b, transform);
                    //        b[3] = 0;

                    //        c = zm.mul(c, transform);
                    //        c[3] = 0;

                    //        model.triangles.append(Triangle.init(material, a, b, c)) catch unreachable;
                    //    }
                    //}
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
