const std = @import("std");

const PI = std.math.pi;
const Vector = std.meta.Vector;
const ArrayList = std.ArrayList;

const Material = @import("materials.zig").Material;
const DielectricMat = @import("materials.zig").DielectricMat;
const LambertianMat = @import("materials.zig").LambertianMat;
const EmissiveMat = @import("materials.zig").EmissiveMat;
const Camera = @import("camera.zig").Camera;
const Model = @import("model.zig").Model;
const Hittable = @import("hittables.zig").Hittable;
const Sphere = @import("hittables.zig").Sphere;
const BVH = @import("bvh.zig");

pub const Scene = struct {
    allocator: std.mem.Allocator,
    title: []const u8,

    camera: Camera,

    models: ArrayList(Model),
    primitives: ArrayList(*Hittable),
    materials: ArrayList(*Material),
    //atmosphere: Skybox,

    blases: []*BVH.BVHNode,
    tlas: BVH.BVHNode,

    fn init(allocator: std.mem.Allocator, title: [:0]const u8) Scene {
        return Scene{
            .allocator = allocator,
            .title = title[0..std.mem.indexOfSentinel(u8, 0, title)],
            .camera = undefined,
            .models = ArrayList(Model).init(allocator),
            .primitives = ArrayList(*Hittable).init(allocator),
            .materials = ArrayList(*Material).init(allocator),
            .blases = undefined,
            .tlas = undefined,
        };
    }

    pub fn deinit(_: *Scene) void {}

    pub fn buildFully(self: *Scene) !void {
        try self.buildBlases();
        try self.buildTlas();
    }

    pub fn buildBlases(self: *Scene) !void {
        const blasCount = self.models.items.len + (@boolToInt(self.primitives.items.len > 0) * 1);
        self.blases = try self.allocator.alloc(*BVH.BVHNode, blasCount);
        var i: usize = 0;
        for (self.models.items) |*model| {
            self.blases[i] = &model.bvh;
            i += 1;
        }

        // NOTE: I don't think this will work well...
        if (self.primitives.items.len > 0) {
            var rng = std.rand.DefaultPrng.init(0);
            var b = try self.allocator.alloc(BVH.BVHNode, 1);
            b[0] = try BVH.buildSimpleBVH(rng.random(), self.allocator, self.primitives.items, 64);
            self.blases[i] = &b[0];
        }
    }

    pub fn buildTlas(self: *Scene) !void {
        self.tlas = try BVH.buildTLAS(self.allocator, self.blases);
    }
};

pub fn devScene(allocator: std.mem.Allocator) anyerror!Scene {
    var scene = Scene.init(allocator, "devScene");

    const cameraPos = Vector(4, f32){ -1.87689530e+00, 0.54253983e+00, -4.15354937e-01, 0.0e+00 };
    const lookTarget = Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 };
    scene.camera = Camera.init(cameraPos, lookTarget, PI / 2.0, 16.0 / 9.0, 0.0, 10.0);

    var defaultMat = try scene.allocator.create(DielectricMat);
    defaultMat.* = DielectricMat.init(Vector(3, f32){ 0.85, 0.5, 0.1 }, 1.5);
    try scene.materials.append(&defaultMat.*.material);

    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/GearboxAssy/glTF/GearboxAssy.gltf"));
    try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/DragonAttenuation/glTF/DragonAttenuation.gltf"));
    //try scene.models.append(try Model.init(scene.allocator, &defaultMat.*.material, "assets/glTF-Sample-Models-master/2.0/SciFiHelmet/glTF/SciFiHelmet.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/Sponza/glTF/Sponza.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Atlas.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Complex.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Complex_SeparateTex.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/box/Box.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/suzanne/Suzanne.gltf"));

    var spheres = try allocator.alloc(Sphere, 4);

    const aMat = try allocator.create(EmissiveMat);
    const bMat = try allocator.create(EmissiveMat);
    const cMat = try allocator.create(EmissiveMat);
    const dMat = try allocator.create(LambertianMat);
    aMat.* = EmissiveMat.init(Vector(3, f32){ 1.0, 1.0, 1.0 });
    spheres[0] = Sphere.init(&aMat.material, Vector(4, f32){ 0.0, 5.0, 0.0, 0.0 }, 1.0);
    bMat.* = EmissiveMat.init(Vector(3, f32){ 0.7 * 2.0, 0.5 * 2.0, 0.1 * 2.0 });
    spheres[2] = Sphere.init(&bMat.material, Vector(4, f32){ 4.0, 1.0, 0.0, 0.0 }, 1.0);
    cMat.* = EmissiveMat.init(Vector(3, f32){ 5.0, 0.0, 0.0 });
    spheres[1] = Sphere.init(&cMat.material, Vector(4, f32){ -4.0, 1.0, 0.0, 0.0 }, 1.0);
    dMat.* = LambertianMat.init(Vector(3, f32){ 0.35, 0.6, 0.2 });
    spheres[3] = Sphere.init(&dMat.material, Vector(4, f32){ 0.0, -2005.0, 0.0, 0.0 }, 2000);

    try scene.primitives.append(&spheres[0].hittable);
    try scene.primitives.append(&spheres[1].hittable);
    try scene.primitives.append(&spheres[2].hittable);
    try scene.primitives.append(&spheres[3].hittable);

    return scene;
}

pub fn sponza(allocator: std.mem.Allocator) anyerror!Scene {
    var scene = Scene.init(allocator, "Sponza");
    return scene;
}
