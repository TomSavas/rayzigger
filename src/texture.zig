const stbi = @cImport({
    @cInclude("stb_image.h");
});
const std = @import("std");
const Vector = std.meta.Vector;

pub const Texture = struct {
    width: u32,
    height: u32,
    bytes: []u8,

    bytesPerPixel: u32,

    pub fn deinit(pi: *Texture) void {
        stbi.stbi_image_free(pi.bytes.ptr);
    }

    pub fn fromPath(path: [:0]const u8) !Texture {
        //stbi.stbi_set_flip_vertically_on_load(1);

        var width: c_int = undefined;
        var height: c_int = undefined;
        var channel_count: c_int = undefined;
        const imageBytes = stbi.stbi_load(path, &width, &height, &channel_count, 0);

        if (width <= 0 or height <= 0) {
            return error.NoPixels;
        }
        if (imageBytes == null) {
            return error.NoMem;
        }

        const size = @intCast(u32, width * height * channel_count);
        return Texture{
            .width = @intCast(u32, width),
            .height = @intCast(u32, height),
            .bytesPerPixel = @intCast(u32, channel_count),

            .bytes = imageBytes[0..size],
        };
    }

    pub fn create(compressedBytes: []const u8) !Texture {
        if (stbi.stbi_is_16_bit_from_memory(compressedBytes.ptr, @intCast(c_int, compressedBytes.len)) != 0) {
            return error.InvalidFormat;
        }
        stbi.stbi_set_flip_vertically_on_load(1);

        var width: c_int = undefined;
        var height: c_int = undefined;
        var channel_count: c_int = undefined;
        const imageBytes = stbi.stbi_load_from_memory(compressedBytes.ptr, @intCast(c_int, compressedBytes.len), &width, &height, &channel_count, 0);

        if (width <= 0 or height <= 0) {
            return error.NoPixels;
        }
        if (imageBytes == null) {
            return error.NoMem;
        }

        const size = @intCast(u32, width * height * channel_count);
        return Texture{
            .width = @intCast(u32, width),
            .height = @intCast(u32, height),
            .bytesPerPixel = @intCast(u32, channel_count),

            .bytes = imageBytes[0..size],
        };
    }

    inline fn index(self: Texture, u: u32, v: u32) u32 {
        return u * self.bytesPerPixel + v * self.width * self.bytesPerPixel;
    }

    pub fn sample(self: Texture, uv: Vector(2, f32)) Vector(3, f32) {
        // The uv wrapping should be wrapped by the caller, avoid doing here -- expensive

        var u = @floatToInt(u32, uv[0] * @intToFloat(f64, self.width));
        var v = @floatToInt(u32, uv[1] * @intToFloat(f64, self.height));

        var idx = self.index(u, v);
        return .{
            @intToFloat(f32, self.bytes[idx + 0]) / 255.0,
            @intToFloat(f32, self.bytes[idx + 1]) / 255.0,
            @intToFloat(f32, self.bytes[idx + 2]) / 255.0,
        };
    }
};
