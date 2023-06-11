const std = @import("std");

const PI = std.math.pi;
const Vector = std.meta.Vector;
const ArrayList = std.ArrayList;

const Material = @import("materials.zig").Material;
const DielectricMat = @import("materials.zig").DielectricMat;
const Camera = @import("camera.zig").Camera;
const Model = @import("model.zig").Model;

pub const Scene = struct {
    allocator: std.mem.Allocator,
    title: []const u8,

    camera: Camera,

    models: ArrayList(Model),
    //simpleShapes: ArrayList(*Hittable),
    materials: ArrayList(*Material),
    //atmosphere: Skybox,

    //bvh: BVH.BVHNode,

    fn init(allocator: std.mem.Allocator, title: [:0]const u8) Scene {
        return Scene{ .allocator = allocator, .title = title[0..std.mem.indexOfSentinel(u8, 0, title)], .camera = undefined, .models = ArrayList(Model).init(allocator), .materials = ArrayList(*Material).init(allocator) };
    }

    pub fn deinit(_: *Scene) void {}

    pub fn buildFully(_: *Scene) void {}
    pub fn buildBlas(_: *Scene) void {}
    pub fn buildTlas(_: *Scene) void {}
};

pub fn devScene(allocator: std.mem.Allocator) anyerror!Scene {
    var scene = Scene.init(allocator, "devScene");

    const cameraPos = Vector(4, f32){ -1.87689530e+00, 1.54253983e+00, -4.15354937e-01, 0.0e+00 };
    const lookTarget = Vector(4, f32){ 0.0, 2, 0.0, 0.0 };
    scene.camera = Camera.init(cameraPos, lookTarget, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 }, PI / 2.0, 16.0 / 9.0, 0.0, 10.0);

    var defaultMat = try scene.allocator.create(DielectricMat);
    defaultMat.* = DielectricMat.init(Vector(3, f32){ 0.85, 0.5, 0.1 }, 1.5);
    try scene.materials.append(&defaultMat.*.material);

    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/GearboxAssy/glTF/GearboxAssy.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/DragonAttenuation/glTF/DragonAttenuation.gltf"));
    try scene.models.append(try Model.init(scene.allocator, &defaultMat.*.material, "assets/glTF-Sample-Models-master/2.0/SciFiHelmet/glTF/SciFiHelmet.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/glTF-Sample-Models-master/2.0/Sponza/glTF/Sponza.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Atlas.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Complex.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/deccer-cubes-main/SM_Deccer_Cubes_Textured_Complex_SeparateTex.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/box/Box.gltf"));
    //try scene.models.append(try Model.init(allocator, &defaultMat.material, "assets/suzanne/Suzanne.gltf"));

    return scene;
}

pub fn sponza(allocator: std.mem.Allocator) anyerror!Scene {
    var scene = Scene.init(allocator, "Sponza");
    return scene;
}
