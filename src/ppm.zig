const std = @import("std");
const pow = std.math.pow;
const print = std.debug.print;
const Vector = std.meta.Vector;

pub fn outputImage(size: Vector(2, u32), fpPixels: []Vector(3, f32), gamma: f32) anyerror!void {
    print("Writing to file...\n", .{});

    const file = try std.fs.cwd().createFile(
        "output.ppm",
        .{ .read = true },
    );
    var writer = file.writer();
    defer file.close();

    try writer.print("P3\n", .{});
    try writer.print("{} {}\n", .{ size[0], size[1] });
    try writer.print("{}\n", .{255});

    var x: usize = 0;
    var y: usize = size[1];
    while (y > 0) {
        y -= 1;
        x = 0;
        while (x < size[0]) : (x += 1) {
            var color = fpPixels[y * size[0] + x];
            var r = @truncate(u8, @floatToInt(u32, pow(f32, color[0], 1.0 / gamma) * 255));
            var g = @truncate(u8, @floatToInt(u32, pow(f32, color[1], 1.0 / gamma) * 255));
            var b = @truncate(u8, @floatToInt(u32, pow(f32, color[2], 1.0 / gamma) * 255));

            try writer.print("{} {} {}\n", .{ r, g, b });
        }
    }

    print("Done writing...\n", .{});
}
