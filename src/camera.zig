const std = @import("std");
const zm = @import("zmath");
const SDL = @import("sdl2");
const pow = std.math.pow;
const PI = std.math.pi;
const print = std.io.getStdOut().writer().print;
const printErr = std.io.getStdErr().writer().print;
const Vector = std.meta.Vector;
const Random = std.rand.Random;
const DefaultRandom = std.rand.DefaultPrng;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const OS = std.os;
const Mutex = Thread.Mutex;

const RayNamespace = @import("ray.zig");
const Ray = RayNamespace.Ray;

pub const Camera = struct {
    viewportSize: Vector(2, f32),
    origin: Vector(4, f32),
    right: Vector(4, f32),
    up: Vector(4, f32),
    focusPlaneLowerLeft: Vector(4, f32),
    lensRadius: f32,
    focusDist: f32,

    unitForward: Vector(4, f32) = Vector(4, f32){},
    unitRight: Vector(4, f32) = Vector(4, f32){},
    unitUp: Vector(4, f32) = Vector(4, f32){},

    rotation: zm.Quat,

    prevMouseX: i32,
    prevMouseY: i32,

    pub fn init(pos: Vector(4, f32), lookAt: Vector(4, f32), requestedUp: Vector(4, f32), vfov: f32, aspectRatio: f32, aperture: f32, focusDist: f32) Camera {
        const h = @sin(vfov / 2.0) / @cos(vfov / 2.0);
        const viewportHeight = 2.0 * h;
        const viewportSize = Vector(2, f32){ viewportHeight * aspectRatio, viewportHeight };

        _ = requestedUp;
        var rotationMat = zm.lookAtRh(pos, lookAt, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 });
        var rotation = zm.matToQuat(rotationMat);

        var forward = zm.qmul(rotation, Vector(4, f32){ 0.0, 0.0, -1.0, 0.0 });
        var right = zm.qmul(rotation, Vector(4, f32){ 1.0, 0.0, 0.0, 0.0 });
        var up = zm.qmul(rotation, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 });

        right = @splat(4, viewportSize[0] * focusDist) * right;
        up = @splat(4, viewportHeight * focusDist) * up;
        const focusPlaneLowerLeft = pos - right * zm.f32x4s(0.5) - up * zm.f32x4s(0.5) + @splat(4, focusDist) * forward;

        var cam = Camera{ .viewportSize = viewportSize, .origin = pos, .right = right, .up = up, .focusPlaneLowerLeft = focusPlaneLowerLeft, .lensRadius = aperture / 2.0, .focusDist = focusDist, .rotation = rotation, .prevMouseX = 0, .prevMouseY = 0 };

        return cam;
    }

    fn recalculateRotation(self: *Camera) void {
        var rotationMat = zm.quatToMat(self.rotation);
        self.unitForward = zm.mul(rotationMat, Vector(4, f32){ 0.0, 0.0, -1.0, 0.0 });
        self.unitRight = zm.mul(rotationMat, Vector(4, f32){ 1.0, 0.0, 0.0, 0.0 });
        self.unitUp = zm.mul(rotationMat, Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 });

        self.right = @splat(4, self.viewportSize[0] * self.focusDist) * self.unitRight;
        self.up = @splat(4, self.viewportSize[1] * self.focusDist) * self.unitUp;
        self.focusPlaneLowerLeft = self.origin - self.right * zm.f32x4s(0.5) - self.up * zm.f32x4s(0.5) + @splat(4, self.focusDist) * self.unitForward;
    }

    pub fn generateRay(self: Camera, u: f32, v: f32, rng: Random) Ray {
        var r0 = Vector(4, f32){ self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), 0 };
        var r1 = Vector(4, f32){ self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), 0 };
        const onLenseOffset = zm.normalize3(self.up) * r0 + zm.normalize3(self.right) * r1;

        const offsetOrigin = self.origin + onLenseOffset;
        const dir = self.focusPlaneLowerLeft + @splat(4, u) * self.right + @splat(4, v) * self.up - offsetOrigin;
        return Ray{ .origin = offsetOrigin, .dir = zm.normalize3(dir) };
    }

    pub fn handleInputEvent(self: *Camera, inputEvent: SDL.Event) bool {
        var moveDir: ?Vector(4, f32) = null;
        var mouseRotation: ?Vector(4, f32) = null;

        switch (inputEvent) {
            .key_down => |key| {
                moveDir = switch (key.keycode) {
                    .space => self.unitUp,
                    .left_control => -self.unitUp,
                    .w => self.unitForward,
                    .s => -self.unitForward,
                    .a => -self.unitRight,
                    .d => self.unitRight,
                    else => null,
                };
            },
            .mouse_motion => |mouse| {
                if (mouse.button_state.getPressed(.right)) {
                    var xDiff = self.prevMouseX - mouse.x;
                    var yDiff = self.prevMouseY - mouse.y;

                    if (xDiff != 0 or yDiff != 0) {
                        mouseRotation = zm.quatFromRollPitchYaw(@intToFloat(f32, -yDiff) / 1000.0, @intToFloat(f32, -xDiff) / 1000.0, 0.0);
                    }
                }
                self.prevMouseX = mouse.x;
                self.prevMouseY = mouse.y;
            },
            else => {},
        }

        if (moveDir) |dir| {
            self.origin += dir * Vector(4, f32){ 0.1, 0.1, 0.1, 0.1 };
        }

        if (mouseRotation) |rot| {
            self.rotation = zm.qmul(self.rotation, rot);
        }

        if (moveDir != null or mouseRotation != null) {
            self.recalculateRotation();
            return true;
        }

        return false;
    }
};
