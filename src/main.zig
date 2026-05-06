const std = @import("std");
const handler = @import("handler.zig");
const index = @import("index.zig");

const PORT: u16 = 9999;
// 256 threads: blocking accept/keep-alive model, one thread per connection.
// maxVUs=250 → 125 connections per instance; 256 threads gives 131 spare → no starvation.
// 256 × 256KB = 64MB stack; well within the 160MB container limit.
const THREADS: usize = 256;

// Embed the index at compile time — zero cold-start, no disk I/O on startup.
const IDX_BYTES: []const u8 = @import("index_embed").bytes;

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    std.log.info("parsing embedded IVF index ({} bytes)...", .{IDX_BYTES.len});
    var idx = try index.loadFromBytes(gpa, IDX_BYTES);
    defer idx.deinit();
    std.log.info("index ready: {} clusters, nprobe={}", .{ idx.clusters.len, idx.nprobe_default });

    const addr = try std.net.Address.parseIp4("0.0.0.0", PORT);
    var srv = try addr.listen(.{
        .reuse_address = true,
        .kernel_backlog = 4096,
    });
    defer srv.deinit();
    std.log.info("listening on :{d} ({d} worker threads)", .{ PORT, THREADS });

    const WorkerArg = struct {
        srv: *std.net.Server,
        idx: *const index.IvfIndex,
    };

    const workerFn = struct {
        fn run(arg: WorkerArg) void {
            while (true) {
                const conn = arg.srv.accept() catch |err| {
                    std.log.err("accept: {}", .{err});
                    continue;
                };
                const ctx: handler.ConnContext = .{ .stream = conn.stream, .idx = arg.idx };
                handler.handleConnection(ctx);
            }
        }
    }.run;

    const arg = WorkerArg{ .srv = &srv, .idx = &idx };

    var threads: [THREADS - 1]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, workerFn, .{arg});
        t.detach();
    }
    workerFn(arg);
}
