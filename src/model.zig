const std = @import("std");
const zm = @import("zmath");
const zmesh = @import("zmesh");
const print = std.debug.print;
const Vector = std.meta.Vector;
const DefaultRandom = std.rand.DefaultPrng;
const ArrayList = std.ArrayList;

const Material = @import("materials.zig").Material;
const LambertianMat = @import("materials.zig").LambertianMat;
const LambertianTexMat = @import("materials.zig").LambertianTexMat;
const Triangle = @import("hittables.zig").Triangle;
const BVH = @import("bvh.zig");

pub const Model = struct {
    // TODO: split into meshes and build individual BVH for BLAS
    allocator: std.mem.Allocator,
    triangles: ArrayList(Triangle),
    materials: ArrayList(*Material),
    bvh: BVH.BVHNode,

    pub fn init(allocator: std.mem.Allocator, defaultMaterial: *const Material, path: [:0]const u8) !Model {
        const filepathRoot = std.fs.path.dirname(path) orelse return error.InvalidPath;
        print("Loading model: {s}\n", .{path});

        const data = try zmesh.io.parseAndLoadFile(path);
        defer zmesh.io.freeData(data);
        var model = Model{ .allocator = allocator, .triangles = ArrayList(Triangle).init(allocator), .materials = ArrayList(*Material).init(allocator), .bvh = undefined };

        if (data.nodes_count <= 0) {
            return error.NoNodes;
        }

        for ((data.nodes orelse return error.NoNodes)[0..data.nodes_count]) |node| {
            var mesh = node.mesh orelse continue;

            var nodeTransform = node.transformWorld();
            var transform = zm.loadMat(nodeTransform[0..]);

            for (mesh.primitives[0..mesh.primitives_count]) |primitive| {
                var indicesAccessor = primitive.indices orelse {
                    print("Primitive with no index accessor, skipping...", .{});
                    continue;
                };

                var positions: []f32 = undefined;
                defer allocator.free(positions);
                var maybeUvs: ?[]f32 = null;
                defer if (maybeUvs) |uvs| allocator.free(uvs);
                for (primitive.attributes[0..primitive.attributes_count]) |attribute| {
                    const attributeSize = attribute.data.type.numComponents() * attribute.data.count;
                    var attributeArr = try allocator.alloc(f32, attributeSize);
                    _ = attribute.data.unpackFloats(attributeArr);

                    switch (attribute.type) {
                        .position => {
                            positions = attributeArr;
                        },
                        .texcoord => {
                            maybeUvs = attributeArr;
                        },
                        else => {},
                    }
                }

                // TODO: use a texture pool
                var material: ?*Material = null;
                if (primitive.material) |primitiveMat| matBlk: {
                    if (primitiveMat.has_pbr_metallic_roughness == 0) break :matBlk;

                    if (primitiveMat.pbr_metallic_roughness.base_color_texture.texture) |tex| {
                        var img = tex.image orelse break :matBlk;
                        var uri = img.uri orelse break :matBlk;
                        var uriSlice = uri[0..std.mem.indexOfSentinel(u8, 0, uri)];

                        var texPath = std.fs.path.join(allocator, &.{ filepathRoot, uriSlice }) catch break :matBlk;
                        defer allocator.free(texPath);
                        var terminatedTexPath = std.cstr.addNullByte(allocator, texPath) catch break :matBlk;
                        defer allocator.free(terminatedTexPath);

                        var mat = allocator.create(LambertianTexMat) catch break :matBlk;

                        print("Loading texture: {s}\n", .{texPath});
                        mat.* = LambertianTexMat.init(terminatedTexPath) catch {
                            print("Failed loading texture\n", .{});
                            break :matBlk;
                        };
                        material = &mat.material;
                    } else {
                        var mat = allocator.create(LambertianMat) catch break :matBlk;

                        var baseColor = primitiveMat.pbr_metallic_roughness.base_color_factor;
                        mat.* = LambertianMat.init(.{ baseColor[0], baseColor[1], baseColor[2] });
                        material = &mat.material;
                    }

                    if (material) |mat| {
                        try model.materials.append(mat); //TODO: Mem leak -- needs deinit on material interface
                    }
                }

                var indices: []f32 = try allocator.alloc(f32, indicesAccessor.count);
                defer allocator.free(indices);
                _ = indicesAccessor.unpackFloats(indices);
                var i: u32 = 0;
                while (i < indices.len) : (i += 3) {
                    var trianglePoints = [3]Vector(4, f32){
                        Vector(4, f32){ positions[@floatToInt(u32, indices[i + 0]) * 3 + 0], positions[@floatToInt(u32, indices[i + 0]) * 3 + 1], positions[@floatToInt(u32, indices[i + 0]) * 3 + 2], 1 },
                        Vector(4, f32){ positions[@floatToInt(u32, indices[i + 1]) * 3 + 0], positions[@floatToInt(u32, indices[i + 1]) * 3 + 1], positions[@floatToInt(u32, indices[i + 1]) * 3 + 2], 1 },
                        Vector(4, f32){ positions[@floatToInt(u32, indices[i + 2]) * 3 + 0], positions[@floatToInt(u32, indices[i + 2]) * 3 + 1], positions[@floatToInt(u32, indices[i + 2]) * 3 + 2], 1 },
                    };
                    trianglePoints[0] = zm.mul(trianglePoints[0], transform);
                    trianglePoints[1] = zm.mul(trianglePoints[1], transform);
                    trianglePoints[2] = zm.mul(trianglePoints[2], transform);

                    var triangleUvs = [3]Vector(2, f32){ .{ 0.0, 0.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0 } };
                    if (maybeUvs) |uvs| {
                        triangleUvs = .{
                            Vector(2, f32){ uvs[@floatToInt(u32, indices[i + 0]) * 2 + 0], uvs[@floatToInt(u32, indices[i + 0]) * 2 + 1] },
                            Vector(2, f32){ uvs[@floatToInt(u32, indices[i + 1]) * 2 + 0], uvs[@floatToInt(u32, indices[i + 1]) * 2 + 1] },
                            Vector(2, f32){ uvs[@floatToInt(u32, indices[i + 2]) * 2 + 0], uvs[@floatToInt(u32, indices[i + 2]) * 2 + 1] },
                        };
                    }

                    try model.triangles.append(Triangle.init(material orelse defaultMaterial, trianglePoints, triangleUvs));
                }
            }
        }

        var rng = DefaultRandom.init(0);
        //model.bvh = try BVH.buildSimpleBVH(rng.random(), allocator, model.triangles.items, 64);
        model.bvh = try BVH.buildSAHBVH(rng.random(), allocator, model.triangles.items, 64, 128);
        return model;
    }

    pub fn deinit(self: *Model) void {
        self.triangles.deinit();

        // TODO: add deinit to material interface
        //for (self.materials) |mat| {
        //    mat.deinit();
        //}
        self.materials.deinit();

        self.bvh.deinit();
    }
};
