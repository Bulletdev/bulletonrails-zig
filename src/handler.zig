// Route handlers: GET /ready and POST /fraud-score.

const std = @import("std");
const server = @import("server.zig");
const normalizer = @import("normalizer.zig");
const json_parser = @import("json_parser.zig");
const index = @import("index.zig");

pub const ConnContext = struct {
    stream: std.net.Stream,
    idx: *const index.IvfIndex,
};

pub fn handleConnection(ctx: ConnContext) void {
    server.setTcpNoDelay(ctx.stream);
    defer ctx.stream.close();
    var buf: [16384]u8 = undefined;
    const req = server.readRequest(ctx.stream, &buf) catch return;
    dispatch(ctx, req);
}

fn dispatch(ctx: ConnContext, req: server.Request) void {
    if (req.method == .get and std.mem.eql(u8, req.path, "/ready")) {
        server.sendReady(ctx.stream) catch {};
        return;
    }
    if (req.method == .post and std.mem.eql(u8, req.path, "/fraud-score")) {
        handleFraudScore(ctx, req.body) catch |err| {
            std.log.err("fraud-score error: {}", .{err});
            server.sendBadRequest(ctx.stream) catch {};
        };
        return;
    }
    server.sendNotFound(ctx.stream) catch {};
}

fn handleFraudScore(ctx: ConnContext, body: []const u8) !void {
    const payload = try json_parser.parse(body);
    const vec = normalizer.normalize(&payload);
    const fraud_count = ctx.idx.search(vec);
    try server.sendFraudResponse(ctx.stream, fraud_count);
}
