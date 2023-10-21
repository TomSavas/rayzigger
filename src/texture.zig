const stbi = @cImport({
    @cInclude("stb_image.h");
});
const std = @import("std");

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

        const size: u32 = @intCast(width * height * channel_count);
        return Texture{
            .width = @intCast(width),
            .height = @intCast(height),
            .bytesPerPixel = @intCast(channel_count),

            .bytes = imageBytes[0..size],
        };
    }

    pub fn create(compressedBytes: []const u8) !Texture {
        if (stbi.stbi_is_16_bit_from_memory(compressedBytes.ptr, @as(c_int, @intCast(compressedBytes.len))) != 0) {
            return error.InvalidFormat;
        }
        stbi.stbi_set_flip_vertically_on_load(1);

        var width: c_int = undefined;
        var height: c_int = undefined;
        var channel_count: c_int = undefined;
        const imageBytes = stbi.stbi_load_from_memory(compressedBytes.ptr, @as(c_int, @intCast(compressedBytes.len)), &width, &height, &channel_count, 0);

        if (width <= 0 or height <= 0) {
            return error.NoPixels;
        }
        if (imageBytes == null) {
            return error.NoMem;
        }

        const size: u32 = @intCast(width * height * channel_count);
        return Texture{
            .width = @intCast(width),
            .height = @intCast(height),
            .bytesPerPixel = @intCast(channel_count),

            .bytes = imageBytes[0..size],
        };
    }

    inline fn index(self: Texture, u: u32, v: u32) u32 {
        return u * self.bytesPerPixel + v * self.width * self.bytesPerPixel;
    }

    pub fn sample(self: Texture, uv: @Vector(2, f32)) @Vector(3, f32) {
        var u = @as(u32, @intFromFloat(@mod(uv[0], 1.0) * @as(f64, @floatFromInt(self.width))));
        var v = @as(u32, @intFromFloat(@mod(uv[1], 1.0) * @as(f64, @floatFromInt(self.height))));

        var idx = self.index(u, v);
        return .{
            @as(f32, @floatFromInt(self.bytes[idx + 0])) / 255.0,
            @as(f32, @floatFromInt(self.bytes[idx + 1])) / 255.0,
            @as(f32, @floatFromInt(self.bytes[idx + 2])) / 255.0,
        };
    }
};
