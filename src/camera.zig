const std = @import("std");
const zm = @import("zmath");
const SDL = @import("sdl2");
const pow = std.math.pow;
const PI = std.math.pi;
const print = std.debug.print;
const Random = std.rand.Random;
const DefaultRandom = std.rand.DefaultPrng;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const OS = std.os;
const Mutex = Thread.Mutex;

const RayNamespace = @import("ray.zig");
const Ray = RayNamespace.Ray;

pub const CameraTransform = struct {
    origin: @Vector(4, f32),
    right: @Vector(4, f32),
    up: @Vector(4, f32),
    focusPlaneLowerLeft: @Vector(4, f32),

    unitForward: @Vector(4, f32) = @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 },
    unitRight: @Vector(4, f32) = @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 },
    unitUp: @Vector(4, f32) = @Vector(4, f32){ 0.0, 0.0, 0.0, 0.0 },

    rotation: zm.Mat,

    pub fn recalculateRotation(self: *CameraTransform, viewportSize: @Vector(2, f32), focusDist: f32) void {
        self.unitUp = @Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 };
        self.unitForward = zm.normalize3(zm.mul(self.rotation, @Vector(4, f32){ 0.0, 0.0, -1.0, 0.0 }));
        self.unitRight = zm.normalize3(zm.cross3(self.unitForward, self.unitUp));
        self.unitUp = zm.normalize3(zm.cross3(self.unitRight, self.unitForward)); // Renormalize

        self.rotation = zm.transpose(.{
            zm.f32x4(self.unitRight[0], self.unitRight[1], self.unitRight[2], 0),
            zm.f32x4(self.unitUp[0], self.unitUp[1], self.unitUp[2], 0),
            zm.f32x4(-self.unitForward[0], -self.unitForward[1], -self.unitForward[2], 0),
            zm.f32x4(0.0, 0.0, 0.0, 1.0),
        });

        self.right = @as(@Vector(4, f32), @splat(viewportSize[0] * focusDist)) * self.unitRight;
        self.up = @as(@Vector(4, f32), @splat(viewportSize[1] * focusDist)) * self.unitUp;
        self.focusPlaneLowerLeft = self.origin - self.right * zm.f32x4s(0.5) - self.up * zm.f32x4s(0.5) + @as(@Vector(4, f32), @splat(focusDist)) * self.unitForward;
    }

    pub fn generateDeterministicRay(self: *const CameraTransform, u: f32, v: f32) Ray {
        const dir = self.focusPlaneLowerLeft + @as(@Vector(4, f32), @splat(u)) * self.right + @as(@Vector(4, f32), @splat(v)) * self.up - self.origin;
        return Ray{ .origin = self.origin, .dir = dir };
    }

    pub fn uvFromRay(self: *const CameraTransform, r: Ray) @Vector(2, f32) {
        // Ray - focus plane intersection
        var op = self.focusPlaneLowerLeft;
        var on = zm.normalize3(zm.cross3(self.up, self.right));

        var t = (zm.dot3(op, on)[0] - zm.dot3(r.origin, on)[0]) / zm.dot3(r.dir, on)[0];
        var dir = r.dir * @as(@Vector(4, f32), @splat(t));

        const uvMult = -self.focusPlaneLowerLeft + r.origin + dir;

        // Simple algebra to invert generateDeterministicRay
        const u = (uvMult[0] * self.up[1] - uvMult[1] * self.up[0]) / (self.right[0] * self.up[1] - self.right[1] * self.up[0]);
        const v = (uvMult[1] - u * self.right[1]) / self.up[1];

        return @Vector(2, f32){ u, v };
    }
};

pub const Camera = struct {
    viewportSize: @Vector(2, f32),
    lensRadius: f32,
    focusDist: f32,

    transform: CameraTransform,

    prevMouseX: i32,
    prevMouseY: i32,

    pub fn init(pos: @Vector(4, f32), lookAt: @Vector(4, f32), vfov: f32, aspectRatio: f32, aperture: f32, focusDist: f32) Camera {
        const h = @sin(vfov / 2.0) / @cos(vfov / 2.0);
        const viewportHeight = 2.0 * h;
        const viewportSize = @Vector(2, f32){ viewportHeight * aspectRatio, viewportHeight };

        var cam = Camera{
            .viewportSize = viewportSize,
            .lensRadius = aperture / 2.0,
            .focusDist = focusDist,

            .transform = CameraTransform{
                .origin = pos,
                .right = undefined,
                .up = undefined,
                .focusPlaneLowerLeft = undefined,
                .rotation = zm.lookAtRh(pos, lookAt, @Vector(4, f32){ 0.0, 1.0, 0.0, 0.0 }),
            },

            .prevMouseX = 0,
            .prevMouseY = 0,
        };

        cam.transform.recalculateRotation(cam.viewportSize, cam.focusDist);

        return cam;
    }

    pub fn generateRay(self: *const Camera, u: f32, v: f32, rng: Random) Ray {
        _ = rng;
        return self.transform.generateDeterministicRay(u, v);
        //var r0 = @Vector(4, f32){ self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), 0 };
        //var r1 = @Vector(4, f32){ self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), self.lensRadius * rng.float(f32), 0 };
        //const onLenseOffset = zm.normalize3(self.up) * r0 + zm.normalize3(self.right) * r1;

        //const offsetOrigin = self.origin + onLenseOffset;
        //const dir = self.focusPlaneLowerLeft + @as(@Vector(4, f32), @splat(u)) * self.right + @as(@Vector(4, f32), @splat(v)) * self.up - offsetOrigin;
        //return Ray{ .origin = offsetOrigin, .dir = zm.normalize3(dir) };
    }

    pub fn handleInputEvent(self: *Camera, inputEvent: SDL.Event) bool {
        var moveDir: ?@Vector(4, f32) = null;
        var mouseRotation: ?zm.Mat = null;

        switch (inputEvent) {
            .key_down => |key| {
                moveDir = switch (key.keycode) {
                    .space => self.transform.unitUp,
                    .left_control => -self.transform.unitUp,
                    .w => self.transform.unitForward,
                    .s => -self.transform.unitForward,
                    .a => -self.transform.unitRight,
                    .d => self.transform.unitRight,
                    .i => return true,
                    else => null,
                };
            },
            .mouse_motion => |mouse| {
                if (mouse.button_state.getPressed(.right)) {
                    var xDiff = self.prevMouseX - mouse.x;
                    var yDiff = self.prevMouseY - mouse.y;

                    if (xDiff != 0 or yDiff != 0) {
                        mouseRotation = zm.matFromRollPitchYaw(@as(f32, @floatFromInt(-yDiff)) / 2000.0, @as(f32, @floatFromInt(-xDiff)) / 2000.0, 0.0);
                    }
                }
                self.prevMouseX = mouse.x;
                self.prevMouseY = mouse.y;
            },
            else => {},
        }

        if (moveDir) |dir| {
            self.transform.origin += dir * @Vector(4, f32){ 0.1, 0.1, 0.1, 0.1 };
        }

        if (mouseRotation) |rot| {
            self.transform.rotation = zm.mul(self.transform.rotation, rot);
        }

        if (moveDir != null or mouseRotation != null) {
            self.transform.recalculateRotation(self.viewportSize, self.focusDist);

            //print("Invalidating\n", .{});
            return true;
        }

        return false;
    }
};
