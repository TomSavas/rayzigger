const std = @import("std");
const print = std.io.getStdOut().writer().print;

const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn main() anyerror!void {
    try print("P3\n255\n", .{});
    try print("{} {}\n", .{255, 255});

    var img: [256][256]Pixel = undefined;
    var x: usize = 0;
    var y: usize = 0;
    while (x < 256) : (x += 1) {
        y = 0;
        while (y < 256) : (y += 1) {
            var p: Pixel = Pixel{.r = @truncate(u8, x), .g = @truncate(u8, y), .b = 0};
            img[x][y] = p;

            try print("{} {} {}\n", p);
        }
    }
}
