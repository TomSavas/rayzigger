const std = @import("std");
const Vector = std.meta.Vector;

pub const Ray = struct {
    origin: Vector(4, f32),
    dir: Vector(4, f32),

    pub fn at(self: Ray, t: f32) Vector(4, f32) {
        return self.origin + @splat(4, t) * self.dir;
    }
};
