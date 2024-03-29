const std = @import("std");
const pow = std.math.pow;
const Random = std.rand.Random;

const print = std.debug.print;

const zm = @import("zmath");

const Ray = @import("ray.zig").Ray;
const Hit = @import("ray.zig").Hit;
const ScatteredRay = @import("ray.zig").ScatteredRay;

fn randomInUnitSphere(rng: Random) @Vector(4, f32) {
    while (true) {
        var vec = @Vector(4, f32){ (rng.float(f32) - 0.5) * 2.0, (rng.float(f32) - 0.5) * 2.0, (rng.float(f32) - 0.5) * 2.0, 0 };
        if (zm.lengthSq3(vec)[0] >= 1.0) continue;
        return zm.normalize3(vec);
    }
}

fn randomInUnitHemisphere(rng: Random, normal: @Vector(4, f32)) @Vector(4, f32) {
    var inUnitSphere = randomInUnitSphere(rng);

    if (zm.dot3(inUnitSphere, normal)[0] <= 0.0) {
        return -inUnitSphere;
    }

    return inUnitSphere;
}

pub const Material = struct {
    scatterFn: *const fn (*const Material, *const Hit, *const Ray, Random) ScatteredRay,

    pub fn scatter(self: *const Material, hit: *const Hit, r: *const Ray, rng: Random) ScatteredRay {
        return self.scatterFn(self, hit, r, rng);
    }
};

pub const LambertianMat = struct {
    color: @Vector(3, f32),
    material: Material,

    pub fn init(color: @Vector(3, f32)) LambertianMat {
        return LambertianMat{ .color = color, .material = Material{ .scatterFn = scatter } };
    }

    pub fn scatter(material: *const Material, hit: *const Hit, _: *const Ray, rng: Random) ScatteredRay {
        const self = @fieldParentPtr(LambertianMat, "material", material);

        var newDir = randomInUnitHemisphere(rng, hit.normal);
        var scatteredRay = Ray{ .origin = hit.location, .dir = zm.normalize3(newDir) };
        return ScatteredRay{ .ray = scatteredRay, .attenuation = self.color };
    }
};

const Texture = @import("texture.zig").Texture;
pub const LambertianTexMat = struct {
    color: @Vector(3, f32),
    texture: Texture,
    material: Material,

    pub fn init(path: [:0]const u8) !LambertianTexMat {
        return LambertianTexMat{ .color = @Vector(3, f32){ 1.0, 0.0, 1.0 }, .texture = try Texture.fromPath(path), .material = Material{ .scatterFn = scatter } };
    }
    pub fn deinit(self: Texture) void {
        self.texture.deinit();
    }

    pub fn scatter(material: *const Material, hit: *const Hit, _: *const Ray, rng: Random) ScatteredRay {
        const self = @fieldParentPtr(LambertianTexMat, "material", material);
        const color = self.texture.sample(hit.uv);

        var newDir = randomInUnitHemisphere(rng, hit.normal);
        var scatteredRay = Ray{ .origin = hit.location, .dir = zm.normalize3(newDir) };
        return ScatteredRay{ .ray = scatteredRay, .attenuation = color };
    }
};

fn reflect(vec: @Vector(4, f32), normal: @Vector(4, f32)) @Vector(4, f32) {
    var a = 2.0 * zm.dot3(vec, normal)[0];
    return vec - normal * @as(@Vector(4, f32), @splat(a));
}

pub const MetalMat = struct {
    color: @Vector(3, f32),
    roughness: f32,
    material: Material,

    pub fn init(color: @Vector(3, f32), roughness: f32) MetalMat {
        return MetalMat{ .color = color, .roughness = roughness, .material = Material{ .scatterFn = scatter } };
    }

    pub fn scatter(material: *const Material, hit: *const Hit, r: *const Ray, rng: Random) ScatteredRay {
        const self = @fieldParentPtr(MetalMat, "material", material);

        var newDir = reflect(r.dir, hit.normal) + @as(@Vector(4, f32), @splat(self.roughness)) * randomInUnitSphere(rng);
        var scatteredRay = Ray{ .origin = hit.location, .dir = zm.normalize3(newDir) };
        return ScatteredRay{ .ray = scatteredRay, .attenuation = self.color };
    }
};

fn refract(vec: @Vector(4, f32), normal: @Vector(4, f32), refractionRatio: f32) @Vector(4, f32) {
    var cosTheta = zm.dot3(-vec, normal)[0];
    if (cosTheta > 1.0) {
        cosTheta = 1.0;
    }
    var a = @as(@Vector(4, f32), @splat(refractionRatio)) * (vec + (@as(@Vector(4, f32), @splat(cosTheta)) * normal));
    var b = normal * -@as(@Vector(4, f32), @splat(@sqrt(@fabs(1.0 - zm.lengthSq3(a)[0]))));

    return a + b;
}

pub const DielectricMat = struct {
    color: @Vector(3, f32),
    refractionIndex: f32,
    material: Material,

    pub fn init(color: @Vector(3, f32), refractionIndex: f32) DielectricMat {
        return DielectricMat{ .color = color, .refractionIndex = refractionIndex, .material = Material{ .scatterFn = scatter } };
    }

    fn reflectance(cos: f32, refractionIndex: f32) f32 {
        // Shlick's approximation
        var r0 = (1.0 - refractionIndex) / (1.0 + refractionIndex);
        r0 = r0 * r0;
        return r0 + (1.0 - r0) * pow(f32, 1.0 - cos, 5.0);
    }

    pub fn scatter(material: *const Material, hit: *const Hit, r: *const Ray, rng: Random) ScatteredRay {
        const self = @fieldParentPtr(DielectricMat, "material", material);

        var refractionIndex = self.refractionIndex;
        if (hit.hitFrontFace) {
            refractionIndex = 1.0 / self.refractionIndex;
        }

        var cosTheta = zm.dot3(-r.dir, hit.normal)[0];
        if (cosTheta > 1.0) {
            cosTheta = 1.0;
        }
        var sinTheta = @sqrt(1.0 - cosTheta * cosTheta);

        var newDir: @Vector(4, f32) = undefined;
        var cannotRefract = (refractionIndex * sinTheta) > 1.0;
        if (cannotRefract or reflectance(cosTheta, refractionIndex) > rng.float(f32)) {
            newDir = reflect(r.dir, hit.normal);
        } else {
            newDir = refract(r.dir, hit.normal, refractionIndex);
        }

        var scatteredRay = Ray{ .origin = hit.location, .dir = zm.normalize3(newDir) };
        return ScatteredRay{ .ray = scatteredRay, .attenuation = self.color };
    }
};

pub const EmissiveMat = struct {
    color: @Vector(3, f32),
    material: Material,

    pub fn init(color: @Vector(3, f32)) EmissiveMat {
        return EmissiveMat{ .color = color, .material = Material{ .scatterFn = scatter } };
    }

    pub fn scatter(material: *const Material, hit: *const Hit, _: *const Ray, rng: Random) ScatteredRay {
        const self = @fieldParentPtr(LambertianMat, "material", material);

        var newDir = randomInUnitHemisphere(rng, hit.normal);
        var scatteredRay = Ray{ .origin = hit.location, .dir = zm.normalize3(newDir) };
        return ScatteredRay{ .ray = scatteredRay, .emissiveness = self.color };
    }
};
