const std = @import("std");
const Vector = std.meta.Vector;

const Material = @import("materials.zig").Material;

pub const Ray = struct {
    origin: Vector(4, f32),
    dir: Vector(4, f32),

    pub fn at(self: Ray, t: f32) Vector(4, f32) {
        return self.origin + @splat(4, t) * self.dir;
    }
};

pub const ScatteredRay = struct {
    ray: Ray,

    attenuation: Vector(3, f32) = Vector(3, f32){ 0.0, 0.0, 0.0 },
    emissiveness: Vector(3, f32) = Vector(3, f32){ 0.0, 0.0, 0.0 },
};

pub const Hit = struct {
    location: Vector(4, f32),
    normal: Vector(4, f32),
    rayFactor: f32,
    hitFrontFace: bool,
    uv: Vector(2, f32),

    material: ?*const Material = null,
};
