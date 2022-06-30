const std = @import("std");
const Vector = std.meta.Vector;
const print = std.io.getStdOut().writer().print;

const Chunk = @import("render_thread.zig").Chunk;

pub const Settings = struct {
    aspectRatio: f32,
    width: u32,
    size: Vector(2, u32),
    pixelCount: u32,
    spp: u32,
    maxBounces: u32,
    gamma: f32,

    chunkAllocator: std.mem.Allocator,
    chunks: []Chunk,

    chunkCountAlongAxis: Vector(2, u32),
    chunkSize: Vector(2, u32),

    pub fn init(allocator: std.mem.Allocator) !Settings {
        var settings = Settings{
            .aspectRatio = 16.0 / 9.0,
            .width = 512,
            //.width = 768,
            //.width = 960,
            //.width = 1920,
            //.width = 2560,
            //.width = 3840,
            .size = undefined,
            .pixelCount = undefined,
            .spp = 256,
            .maxBounces = 32,
            .gamma = 2.2,
            .chunkAllocator = allocator,
            .chunks = undefined,
            .chunkCountAlongAxis = undefined,
            .chunkSize = Vector(2, u32){ 32, 32 },
        };
        settings.size = Vector(2, u32){ settings.width, @floatToInt(u32, @intToFloat(f32, settings.width) / settings.aspectRatio) };
        settings.pixelCount = settings.size[0] * settings.size[1];

        settings.chunkCountAlongAxis = (settings.size + settings.chunkSize - Vector(2, u32){ 1, 1 }) / settings.chunkSize;
        const chunkCount = settings.chunkCountAlongAxis[0] * settings.chunkCountAlongAxis[1];
        settings.chunks = try settings.chunkAllocator.alloc(Chunk, chunkCount);

        var chunkIndex: u32 = 0;
        while (chunkIndex < chunkCount) : (chunkIndex += 1) {
            const chunkCol = @mod(chunkIndex, settings.chunkCountAlongAxis[0]);
            const chunkRow = @divTrunc(chunkIndex, settings.chunkCountAlongAxis[0]);

            const chunkStartIndices = Vector(2, u32){ chunkCol * settings.chunkSize[0], chunkRow * settings.chunkSize[1] };
            var clampedChunkSize = settings.chunkSize;
            if (chunkStartIndices[0] + settings.chunkSize[0] > settings.size[0]) {
                clampedChunkSize[0] = settings.size[0] - chunkStartIndices[0];
            }
            if (chunkStartIndices[1] + settings.chunkSize[1] > settings.size[1]) {
                clampedChunkSize[1] = settings.size[1] - chunkStartIndices[1];
            }

            settings.chunks[chunkIndex] = Chunk.init(chunkStartIndices, clampedChunkSize);
        }

        return settings;
    }

    pub fn deinit(self: *Settings) void {
        self.chunkAllocator.free(self.chunks);
    }
};
