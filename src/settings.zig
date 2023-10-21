const std = @import("std");
const print = std.io.getStdOut().writer().print;
const Thread = std.Thread;

const Chunk = @import("render_thread.zig").Chunk;

const args = @import("args");

pub const Settings = struct {
    const CmdSettings = struct {
        width: u32 = 512,
        threads: ?u32 = null,

        benchmark: ?enum { dev, full } = null,
        targetSpp: ?u32 = null,

        sppPerPass: u32 = 4,
        maxBounces: u32 = 4,
        gamma: f32 = 2,
        chunkSize: u32 = 32,

        // For zig-args
        pub const shorthands = .{
            .w = "width",
            .t = "threads",
            .b = "benchmark",
            .s = "targetSpp",
            .p = "sppPerPass",
            .c = "chunkSize",
        };
    };
    cmdSettings: CmdSettings,

    aspectRatio: f32,
    size: @Vector(2, u32),
    pixelCount: u32,

    chunkAllocator: std.mem.Allocator,
    chunks: []Chunk,

    chunkCountAlongAxis: @Vector(2, u32),

    pub fn init(allocator: std.mem.Allocator) !Settings {
        var settings = Settings{
            .cmdSettings = undefined,
            .aspectRatio = 16.0 / 9.0,
            .size = undefined,
            .pixelCount = undefined,
            .chunkAllocator = allocator,
            .chunks = undefined,
            .chunkCountAlongAxis = undefined,
        };

        {
            const argOpts = try args.parseForCurrentProcess(CmdSettings, allocator, .print);
            settings.cmdSettings = argOpts.options;
            argOpts.deinit();
        }

        if (settings.cmdSettings.threads == null) {
            settings.cmdSettings.threads = @intCast(Thread.getCpuCount() catch 1);
        }

        const chunkSize: @Vector(2, u32) = @splat(settings.cmdSettings.chunkSize);

        settings.size = @Vector(2, u32){ settings.cmdSettings.width, @as(u32, @intFromFloat(@as(f32, @floatFromInt(settings.cmdSettings.width)) / settings.aspectRatio)) };
        settings.pixelCount = settings.size[0] * settings.size[1];

        settings.chunkCountAlongAxis = (settings.size + chunkSize - @Vector(2, u32){ 1, 1 }) / chunkSize;
        const chunkCount = settings.chunkCountAlongAxis[0] * settings.chunkCountAlongAxis[1];
        settings.chunks = try settings.chunkAllocator.alloc(Chunk, chunkCount);

        var chunkIndex: u32 = 0;
        while (chunkIndex < chunkCount) : (chunkIndex += 1) {
            const chunkCol = @mod(chunkIndex, settings.chunkCountAlongAxis[0]);
            const chunkRow = @divTrunc(chunkIndex, settings.chunkCountAlongAxis[0]);

            const chunkStartIndices = @Vector(2, u32){ chunkCol * chunkSize[0], chunkRow * chunkSize[1] };
            var clampedChunkSize = chunkSize;
            if (chunkStartIndices[0] + chunkSize[0] > settings.size[0]) {
                clampedChunkSize[0] = settings.size[0] - chunkStartIndices[0];
            }
            if (chunkStartIndices[1] + chunkSize[1] > settings.size[1]) {
                clampedChunkSize[1] = settings.size[1] - chunkStartIndices[1];
            }

            settings.chunks[chunkIndex] = Chunk.init(chunkIndex, chunkStartIndices, clampedChunkSize);
        }

        return settings;
    }

    pub fn deinit(self: *Settings) void {
        self.chunkAllocator.free(self.chunks);
    }
};
