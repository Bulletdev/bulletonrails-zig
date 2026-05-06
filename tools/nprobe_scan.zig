// nprobe_scan: tests accuracy at different nprobe levels against all test queries.
// Usage: zig run tools/nprobe_scan.zig -- resources/index.bin /tmp/test_vectors.bin

const std = @import("std");
const bi = @import("build_index.zig");

const DIM = bi.DIM;
const KNN: usize = 5;
const K = bi.K;

const Cluster = struct {
    count: u32,
    labels: []u8,
    blocks: [][16 * DIM]i16,
};

const Index = struct {
    centroids: [][DIM]f32,
    clusters: []Cluster,

    fn deinit(self: *Index, gpa: std.mem.Allocator) void {
        for (self.clusters) |cl| {
            gpa.free(cl.labels);
            gpa.free(cl.blocks);
        }
        gpa.free(self.clusters);
        gpa.free(self.centroids);
    }
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) {
        std.debug.print("usage: nprobe_scan <index.bin> <test_vectors.bin>\n", .{});
        return error.MissingArgs;
    }

    var idx = try loadIndex(gpa, args[1]);
    defer idx.deinit(gpa);
    std.debug.print("index loaded: {d} clusters\n", .{idx.clusters.len});

    const queries = try loadTestVectors(gpa, args[2]);
    defer {
        gpa.free(queries.vecs);
        gpa.free(queries.labels);
    }
    std.debug.print("test queries: {d}\n", .{queries.vecs.len});

    const nprobe_vals = [_]u32{ 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256 };

    for (nprobe_vals) |np| {
        var correct: usize = 0;
        var correct_boundary: usize = 0;

        for (queries.vecs, queries.labels) |q, expected_fc| {
            const qi = quantize(q);
            var fc = searchNprobe(q, qi, &idx, np);
            // boundary retry with np*3
            const np_bnd = @min(np * 3, 256);
            if (fc == 2 or fc == 3) fc = searchNprobe(q, qi, &idx, np_bnd);
            if (fc == expected_fc) correct += 1;

            // also check without boundary retry
            const fc_plain = searchNprobe(q, qi, &idx, np);
            if (fc_plain == expected_fc) correct_boundary += 1;
        }

        const acc = @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(queries.vecs.len));
        const acc_plain = @as(f64, @floatFromInt(correct_boundary)) / @as(f64, @floatFromInt(queries.vecs.len));
        std.debug.print("nprobe={d:3}  acc_plain={d:.4}  acc_with_boundary={d:.4}\n", .{
            np, acc_plain, acc,
        });
    }
}

fn quantize(v: [DIM]f32) [DIM]i16 {
    const scale: f32 = @floatFromInt(bi.SCALE);
    var out: [DIM]i16 = undefined;
    for (0..DIM) |i| out[i] = @intFromFloat(@max(-32768.0, @min(32767.0, v[i] * scale)));
    return out;
}

fn searchNprobe(q: [DIM]f32, qi: [DIM]i16, idx: *const Index, nprobe: u32) u8 {
    var probe_buf: [256]u32 = undefined;
    const np = @min(nprobe, 256);
    nearestCentroids(idx.centroids, q, probe_buf[0..np]);

    var top5_d: [KNN]i64 = [_]i64{std.math.maxInt(i64)} ** KNN;
    var top5_l: [KNN]u8 = [_]u8{0} ** KNN;

    const V16i16 = @Vector(16, i16);
    const V16i32 = @Vector(16, i32);

    for (probe_buf[0..np]) |ci| {
        const cl = &idx.clusters[ci];
        for (cl.blocks, 0..) |*blk, bii| {
            const start = bii * 16;
            const n = @min(16, cl.count - @as(u32, @intCast(start)));

            var dists: V16i32 = @splat(0);
            inline for (0..DIM) |d| {
                const qv: V16i16 = @splat(qi[d]);
                const bv: V16i16 = blk[d * 16 ..][0..16].*;
                const diff: V16i16 = qv - bv;
                const diff32: V16i32 = @intCast(diff);
                dists += diff32 * diff32;
            }

            for (0..n) |j| {
                const dist: i64 = dists[j];
                if (dist < top5_d[KNN - 1]) {
                    var i: usize = KNN - 1;
                    while (i > 0 and top5_d[i - 1] > dist) : (i -= 1) {
                        top5_d[i] = top5_d[i - 1];
                        top5_l[i] = top5_l[i - 1];
                    }
                    top5_d[i] = dist;
                    top5_l[i] = cl.labels[start + j];
                }
            }
        }
    }

    var fraud: u8 = 0;
    for (top5_l) |l| fraud += l;
    return fraud;
}

fn nearestCentroids(centroids: [][DIM]f32, q: [DIM]f32, out: []u32) void {
    const np = out.len;
    var h_dist: [256]f32 = [_]f32{std.math.inf(f32)} ** 256;
    var h_idx: [256]u32 = [_]u32{0} ** 256;
    var h_size: usize = 0;

    for (centroids, 0..) |c, i| {
        var s: f32 = 0;
        for (0..DIM) |d| { const diff = q[d] - c[d]; s += diff * diff; }

        if (h_size < np) {
            h_dist[h_size] = s;
            h_idx[h_size] = @intCast(i);
            h_size += 1;
            if (h_size == np) heapify(h_dist[0..np], h_idx[0..np]);
        } else if (s < h_dist[0]) {
            h_dist[0] = s;
            h_idx[0] = @intCast(i);
            siftDown(h_dist[0..np], h_idx[0..np], 0);
        }
    }

    var size = h_size;
    while (size > 0) {
        size -= 1;
        out[size] = h_idx[0];
        h_dist[0] = h_dist[size];
        h_idx[0] = h_idx[size];
        if (size > 0) siftDown(h_dist[0..size], h_idx[0..size], 0);
    }
}

fn heapify(d: []f32, idx: []u32) void {
    var i: isize = @intCast(d.len / 2);
    while (i >= 0) : (i -= 1) siftDown(d, idx, @intCast(i));
}

fn siftDown(d: []f32, idx: []u32, root: usize) void {
    var r = root;
    while (true) {
        var largest = r;
        const l = 2 * r + 1;
        const right = l + 1;
        if (l < d.len and d[l] > d[largest]) largest = l;
        if (right < d.len and d[right] > d[largest]) largest = right;
        if (largest == r) break;
        std.mem.swap(f32, &d[r], &d[largest]);
        std.mem.swap(u32, &idx[r], &idx[largest]);
        r = largest;
    }
}

const TestData = struct {
    vecs: [][DIM]f32,
    labels: []u8,
};

fn loadTestVectors(gpa: std.mem.Allocator, path: []const u8) !TestData {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(gpa, 100_000_000);
    defer gpa.free(data);

    var pos: usize = 0;
    const n = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    const vecs = try gpa.alloc([DIM]f32, n);
    const labels = try gpa.alloc(u8, n);

    for (0..n) |i| {
        for (0..DIM) |d| {
            const bits = std.mem.readInt(u32, data[pos..][0..4], .little);
            vecs[i][d] = @bitCast(bits);
            pos += 4;
        }
        labels[i] = data[pos];
        pos += 1;
    }

    return .{ .vecs = vecs, .labels = labels };
}

fn loadIndex(gpa: std.mem.Allocator, path: []const u8) !Index {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(gpa, 100_000_000);
    defer gpa.free(data);

    var pos: usize = 0;
    const magic = std.mem.readInt(u32, data[pos..][0..4], .little); pos += 4;
    if (magic != 0x32465649) return error.BadMagic;
    _ = std.mem.readInt(u32, data[pos..][0..4], .little); pos += 4; // version
    const k = std.mem.readInt(u32, data[pos..][0..4], .little); pos += 4;
    const dim = std.mem.readInt(u32, data[pos..][0..4], .little); pos += 4;
    if (k != K or dim != DIM) return error.DimMismatch;
    pos += 12; // skip nprobe_def, nprobe_bnd, scale

    const centroids = try gpa.alloc([DIM]f32, k);
    for (centroids) |*c| {
        for (c) |*v| {
            const bits = std.mem.readInt(u32, data[pos..][0..4], .little);
            v.* = @bitCast(bits);
            pos += 4;
        }
    }

    const clusters = try gpa.alloc(Cluster, k);
    for (clusters) |*cl| {
        const count = std.mem.readInt(u32, data[pos..][0..4], .little); pos += 4;
        const block_count = std.mem.readInt(u32, data[pos..][0..4], .little); pos += 4;
        const labels = try gpa.alloc(u8, count);
        const blocks = try gpa.alloc([16 * DIM]i16, block_count);
        for (0..block_count) |bi2| {
            const lbl_start = bi2 * 16;
            const lbl_end = @min(lbl_start + 16, count);
            for (lbl_start..lbl_end) |j| labels[j] = data[pos + (j - lbl_start)];
            pos += 16;
            for (0..16 * DIM) |j| {
                blocks[bi2][j] = std.mem.readInt(i16, data[pos..][0..2], .little);
                pos += 2;
            }
        }
        cl.* = .{ .count = count, .labels = labels, .blocks = blocks };
    }

    return .{ .centroids = centroids, .clusters = clusters };
}
