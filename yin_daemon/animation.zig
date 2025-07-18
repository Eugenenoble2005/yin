const std = @import("std");
const wl = @import("wayland").client.wl;
const lz4 = @import("shared").lz4;
const posix = std.posix;
const pixman = @import("pixman");
const Output = @import("output.zig").Output;
const allocator = @import("util.zig").allocator;
const Buffer = @import("Buffer.zig");
const Image = @import("image.zig").Image;
//use global allocator
pub const AnimatedImage = @This();
pub const ImageResponse = @import("image.zig").ImageResponse;
framecount: usize,
durations: []f32,
delta_mmaps: [][]align(4096) u8,
current_frame: u32 = 0,
base_frame: []align(4096) u8,
timer_fd: posix.fd_t,
event_index: usize = 1,
output_name: u32 = 0,
poolBuffer: *Buffer.PoolBuffer, //todo, should not be a pool buffer on animation

pub fn deinit(self: *AnimatedImage) void {
    allocator.free(self.durations);
    for (self.delta_mmaps, 0..) |dm, i| {
        //first item in this array is invald
        if (i == 0) continue;
        std.posix.munmap(dm);
    }
    allocator.free(self.delta_mmaps);
    std.posix.munmap(self.base_frame);
    self.poolBuffer.deinit();
}
pub fn load(file: *std.fs.File, output: *Output) !?ImageResponse {
    const output_scale: u32 = @intCast(output.scale);
    const output_height = output.height * output_scale;
    const output_width = output.width * output_scale;
    const output_stride = output_width * 4;
    var fbs = file;
    defer {
        file.close();
        allocator.destroy(file);
    }
    const number_of_frames = try fbs.reader().readInt(u32, .little);
    _ = try fbs.reader().readInt(u32, .little);
    _ = try fbs.reader().readInt(u32, .little);
    _ = try fbs.reader().readInt(u8, .little);

    //Go through frames
    var durations: []f32 = try allocator.alloc(f32, number_of_frames);
    const delta_mmaps = try allocator.alloc([]align(4096) u8, number_of_frames);
    var base_frame: []align(4096) u8 = undefined;
    const poolBuffer = try Buffer.new_buffer(output);
    for (0..number_of_frames) |i| {
        const full_or_composite = try fbs.reader().readByte();
        if (full_or_composite == 0) {
            composite_from_delta(
                fbs,
                durations,
                delta_mmaps,
                i,
            ) catch {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
            };
            continue;
        }

        const duration_length = try fbs.reader().readInt(u32, .little);
        const duration_buffer = try allocator.alloc(u8, duration_length);
        defer allocator.free(duration_buffer);
        _ = try fbs.reader().readAll(duration_buffer);
        const duration: f32 = std.mem.bytesToValue(f32, duration_buffer);
        durations[i] = duration;
        const original_pixel_len = try fbs.reader().readInt(u32, .little);
        const compressed_pixel_len = try fbs.reader().readInt(u32, .little);
        const compressed_buffer = try allocator.alloc(u8, compressed_pixel_len);
        defer allocator.free(compressed_buffer);
        _ = try fbs.reader().readAll(compressed_buffer);
        const decompressed_buffer = try allocator.alloc(u8, original_pixel_len * @sizeOf(u32));
        defer allocator.free(decompressed_buffer);
        const decompressed_size = lz4.LZ4_decompress_safe(
            @ptrCast(@alignCast(compressed_buffer.ptr)),
            @ptrCast(@alignCast(decompressed_buffer.ptr)),
            @intCast(compressed_buffer.len),
            @intCast(decompressed_buffer.len),
        );
        const decompressed_data_slice = decompressed_buffer[0..@intCast(decompressed_size)];
        const fd = try std.posix.memfd_create("yin-frame-buffer", 0);
        const size = output_height * output_stride;
        try std.posix.ftruncate(fd, @intCast(size));
        const data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        base_frame = data;
        //must be the same resolution, todo: this is really stupid
        if (data.len != decompressed_data_slice.len) {
            std.log.debug("dimensions were not correct", .{});
            return error.IncorrectDimension;
        }
        @memcpy(data, decompressed_data_slice);
    }
    const timer_fd = try std.posix.timerfd_create(.MONOTONIC, .{});
    return ImageResponse{ .Animated = .{ .image = .{
        .durations = durations,
        .framecount = number_of_frames,
        .delta_mmaps = delta_mmaps,
        .timer_fd = timer_fd,
        .base_frame = base_frame,
        .poolBuffer = poolBuffer.?,
    } } };
}

fn composite_from_delta(
    fbs: *std.fs.File,
    durations: []f32,
    mmaps: [][]align(4096) u8,
    i: usize,
) !void {
    const duration_length = try fbs.reader().readInt(u32, .little);
    const duration_buffer = try allocator.alloc(u8, duration_length);
    defer allocator.free(duration_buffer);
    _ = try fbs.reader().readAll(duration_buffer);
    const duration: f32 = std.mem.bytesToValue(f32, duration_buffer);
    durations[i] = duration;

    //read compressed length
    const original_len = try fbs.reader().readInt(u32, .little);
    const compressed_len = try fbs.reader().readInt(u32, .little);
    const compressed_buffer = try allocator.alloc(u8, compressed_len);
    defer allocator.free(compressed_buffer);
    _ = try fbs.reader().readAll(compressed_buffer);
    const decompressed_buffer = try allocator.alloc(u8, original_len);
    defer allocator.free(decompressed_buffer);
    const decompressed_size = lz4.LZ4_decompress_safe(
        @ptrCast(@alignCast(compressed_buffer.ptr)),
        @ptrCast(@alignCast(decompressed_buffer.ptr)),
        @intCast(compressed_buffer.len),
        @intCast(decompressed_buffer.len),
    );

    const encoded: []u8 = decompressed_buffer[0..@intCast(decompressed_size)];
    const fd = try std.posix.memfd_create("yin-frame-buffer", 0);
    defer std.posix.close(fd);
    try std.posix.ftruncate(fd, @intCast(encoded.len));
    const data = try std.posix.mmap(
        null,
        encoded.len,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    @memcpy(data, encoded);
    mmaps[i] = data;
}

pub fn set_timer_milliseconds(_: AnimatedImage, timer_fd: posix.fd_t, duration: f32) !void {
    const delay_microseconds = @as(u64, @intFromFloat(duration * 1000.0));
    const delay_ms = delay_microseconds;
    const spec: posix.system.itimerspec = .{
        .it_value = .{ .sec = @intCast(delay_ms / 1000), .nsec = @intCast((delay_ms % 1000) * 1000000) },
        .it_interval = .{ .sec = 0, .nsec = 0 },
    };
    try posix.timerfd_settime(timer_fd, .{}, &spec, null);
}
pub const AnimationFrame = struct {
    image: ?*Image = null, //this will get released after a render, so we cannot release it here to prevent double free
    duration: f32,
    pub fn deinit(self: *AnimationFrame) void {
        allocator.destroy(self);
    }
};

pub fn play_frame(self: *AnimatedImage, output: *Output) !void {
    const surface = output.wlSurface orelse return;
    const current_frame = self.current_frame;
    //display base frame
    switch (current_frame) {
        0 => {
            @memcpy(self.poolBuffer.memory_map, self.base_frame);
        },
        else => {
            const delta_data = self.delta_mmaps[current_frame];
            const data = self.poolBuffer.memory_map;
            var output_pos: usize = 0;
            const pixel_size = @sizeOf(u32);
            var index: usize = 0;
            // warning: no bounds checking
            while (index < delta_data.len) {
                const tag = delta_data[index];
                index += 1;
                if (tag != 0xE0 and tag != 0xD0) return error.InvalidTag;
                if (tag == 0xE0) {
                    const unchanged_count = std.mem.readInt(u32, @ptrCast(delta_data[index .. index + 4]), .little);
                    index += 4;
                    output_pos += unchanged_count;
                } else {
                    const changed_len = std.mem.readInt(u32, @ptrCast(delta_data[index .. index + 4]), .little);
                    index += 4;
                    const bytes_to_read = changed_len * pixel_size;
                    const pixel_data = delta_data[index .. index + bytes_to_read];
                    index += bytes_to_read;
                    const start_at = output_pos * pixel_size;
                    var i: usize = 0;
                    const chunk_size: u8 = 128;
                    while (i + chunk_size < bytes_to_read) {
                        @memcpy(data[start_at + i .. start_at + i + chunk_size], pixel_data[i .. i + chunk_size]);
                        i += chunk_size;
                    }
                    if (i < bytes_to_read) {
                        @memcpy(data[start_at + i .. bytes_to_read + start_at], pixel_data[i..]);
                    }
                    output_pos += changed_len;
                }
            }
        },
    }
    surface.attach(self.poolBuffer.wlBuffer, 0, 0);
    surface.damage(0, 0, @intCast(output.width), @intCast(output.width));
    surface.setBufferScale(output.scale);
    surface.commit();
    //schedule next frame
    if (self.current_frame + 1 >= self.framecount) {
        self.current_frame = 1;
    } else {
        self.current_frame += 1;
    }
    //schedule next frame
    if (output.paused == true) return;
    try self.set_timer_milliseconds(self.timer_fd, self.durations[self.current_frame]);
}
