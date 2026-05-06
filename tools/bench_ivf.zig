const std = @import("std");
const index = @import("../src/index.zig");

const IDX_BYTES: []const u8 = @embedFile("../resources/index.bin");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var idx = try index.loadFromBytes(gpa, IDX_BYTES);
    defer idx.deinit();

    const queries = [_][14]f32{
        .{ 0.004, 0.167, 0.05, 0.783, 0.333, -1, -1, 0.029, 0.15, 0, 1, 0, 0.15, 0.006 },
        .{ 0.951, 0.833, 1.0, 0.217, 0.833, -1, -1, 0.952, 1.0, 0, 1, 1, 0.75, 0.005 },
        .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1, 0, 1, 0.5, 0.5 },
        .{ 0.1, 0.08, 0.1, 0.6, 0.5, -1, -1, 0.05, 0.2, 0, 1, 0, 0.3, 0.01 },
        .{ 0.8, 0.9, 0.8, 0.1, 0.6, -1, -1, 0.9, 0.9, 1, 0, 1, 0.8, 0.01 },
    };

    const N = 20_000;

    // Warmup
    var sink: u64 = 0;
    for (0..200) |i| sink += idx.search(queries[i % queries.len]);

    var timer = try std.time.Timer.start();
    for (0..N) |i| sink += idx.search(queries[i % queries.len]);
    const elapsed_ns = timer.read();

    const ns_per = elapsed_ns / N;
    const stdout = std.io.getStdOut().writer();
    try stdout.print("sink={d}\n", .{sink}); // prevent elision
    try stdout.print("IVF search ({d} calls): total={d}ms avg={d}ns = {d:.3}ms thru={d}/s\n", .{
        N,
        elapsed_ns / 1_000_000,
        ns_per,
        @as(f64, @floatFromInt(ns_per)) / 1_000_000.0,
        1_000_000_000 / ns_per,
    });
}
