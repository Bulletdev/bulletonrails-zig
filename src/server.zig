// HTTP/1.1 request parser and pre-built response writer.
// Phase 2: blocking reads, keep-alive semantics, all responses pre-built at comptime.

const std = @import("std");

pub const Method = enum { get, post, unknown };

pub const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
};

const CONTENT_TYPE = "Content-Type: application/json\r\n";
const CONN_KEEP = "Connection: keep-alive\r\n\r\n";

const BODIES = [6][]const u8{
    "{\"approved\":true,\"fraud_score\":0.0}",
    "{\"approved\":true,\"fraud_score\":0.2}",
    "{\"approved\":true,\"fraud_score\":0.4}",
    "{\"approved\":false,\"fraud_score\":0.6}",
    "{\"approved\":false,\"fraud_score\":0.8}",
    "{\"approved\":false,\"fraud_score\":1.0}",
};

// Full pre-built responses: single writeAll per request, no runtime formatting.
const FRAUD_RESPONSES = blk: {
    const hdr_prefix = "HTTP/1.1 200 OK\r\n" ++ CONTENT_TYPE ++ "Content-Length: ";
    var r: [6][]const u8 = undefined;
    for (&r, BODIES) |*rsp, body| {
        const cl = std.fmt.comptimePrint("{d}", .{body.len});
        rsp.* = hdr_prefix ++ cl ++ "\r\n" ++ CONN_KEEP ++ body;
    }
    break :blk r;
};

const READY_RESPONSE =
    "HTTP/1.1 200 OK\r\n" ++ CONTENT_TYPE ++
    "Content-Length: 2\r\n" ++ CONN_KEEP ++ "OK";

const BAD_REQUEST =
    "HTTP/1.1 400 Bad Request\r\n" ++ CONTENT_TYPE ++
    "Content-Length: 0\r\n" ++ CONN_KEEP;

const NOT_FOUND =
    "HTTP/1.1 404 Not Found\r\n" ++ CONTENT_TYPE ++
    "Content-Length: 0\r\n" ++ CONN_KEEP;

pub fn setTcpNoDelay(stream: std.net.Stream) void {
    const one: c_int = 1;
    std.posix.setsockopt(
        stream.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

pub fn readRequest(stream: std.net.Stream, buf: []u8) !Request {
    var total: usize = 0;
    var header_end: usize = 0;

    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;

        if (header_end == 0) {
            header_end = findHeaderEnd(buf[0..total]) orelse 0;
            if (header_end != 0) {
                const content_length = parseContentLength(buf[0..header_end]) orelse 0;
                const body_start = header_end + 4;
                const need = body_start + content_length;
                if (total >= need) {
                    return parseRequest(buf[0..header_end], buf[body_start .. body_start + content_length]);
                }
            }
        } else {
            const content_length = parseContentLength(buf[0..header_end]) orelse 0;
            const need = header_end + 4 + content_length;
            if (total >= need) {
                const body_start = header_end + 4;
                return parseRequest(buf[0..header_end], buf[body_start .. body_start + content_length]);
            }
        }
    }
    return error.RequestTooLarge;
}

fn findHeaderEnd(data: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and
            data[i + 2] == '\r' and data[i + 3] == '\n') return i;
    }
    return null;
}

fn parseContentLength(headers: []const u8) ?usize {
    const needle = "Content-Length: ";
    var start = std.mem.indexOf(u8, headers, needle) orelse return null;
    start += needle.len;
    var end = start;
    while (end < headers.len and headers[end] != '\r' and headers[end] != '\n') end += 1;
    return std.fmt.parseInt(usize, headers[start..end], 10) catch null;
}

fn parseRequest(header_section: []const u8, body: []const u8) Request {
    const line_end = std.mem.indexOfScalar(u8, header_section, '\r') orelse header_section.len;
    const request_line = header_section[0..line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse "";
    const path = parts.next() orelse "";

    const method: Method = if (std.mem.eql(u8, method_str, "GET"))
        .get
    else if (std.mem.eql(u8, method_str, "POST"))
        .post
    else
        .unknown;

    return .{ .method = method, .path = path, .body = body };
}

pub fn sendFraudResponse(stream: std.net.Stream, fraud_count: u8) !void {
    try stream.writeAll(FRAUD_RESPONSES[@min(fraud_count, 5)]);
}

pub fn sendReady(stream: std.net.Stream) !void {
    try stream.writeAll(READY_RESPONSE);
}

pub fn sendBadRequest(stream: std.net.Stream) !void {
    try stream.writeAll(BAD_REQUEST);
}

pub fn sendNotFound(stream: std.net.Stream) !void {
    try stream.writeAll(NOT_FOUND);
}
