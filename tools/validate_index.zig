// Validates IVF fraud_count agreement vs brute-force L2 ground truth.
// A "hit" = fraud_count from IVF matches brute-force exactly.
// Run: zig run tools/validate_index.zig -- resources/references.json.gz resources/index.bin

const std = @import("std");
const bi = @import("build_index.zig");

const DIM = bi.DIM;
const KNN: usize = 5;
const SAMPLES: usize = 2000;
const MIN_AGREEMENT: f64 = 0.99;

const DataPoint = struct {
    vector: [DIM]f32,
    label: u8,
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) {
        std.debug.print("usage: validate_index <refs.json.gz> <index.bin>\n", .{});
        return error.MissingArgs;
    }

    std.debug.print("loading dataset...\n", .{});
    const points = try loadDataset(gpa, args[1]);
    defer gpa.free(points);

    std.debug.print("loading index...\n", .{});
    var idx = try loadIndex(gpa, args[2]);
    defer idx.deinit(gpa);
    std.debug.print("  {d} clusters, nprobe_default={d}\n", .{ idx.clusters.len, idx.nprobe_default });

    var rng = std.Random.DefaultPrng.init(99999);
    const rand = rng.random();

    var exact_hits: usize = 0;
    var near_hits: usize = 0; // within ±1 fraud_count
    // error_dist[bf][ivf] counts mismatches
    var err_dist: [6][6]usize = [_][6]usize{[_]usize{0} ** 6} ** 6;

    std.debug.print("checking {d} samples (nprobe={d})...\n", .{ SAMPLES, idx.nprobe_default });
    for (0..SAMPLES) |s| {
        const qi = rand.intRangeLessThan(usize, 0, points.len);
        const q = points[qi].vector;

        const fc_bf = bruteForce(q, points);
        const fc_ivf = ivfSearch(q, &idx);

        if (fc_ivf == fc_bf) exact_hits += 1;
        if (fc_ivf <= fc_bf + 1 and fc_bf <= fc_ivf + 1) near_hits += 1;
        if (fc_ivf != fc_bf) err_dist[fc_bf][fc_ivf] += 1;

        if (s % 200 == 199) {
            const done = s + 1;
            std.debug.print("  {d}/{d} exact={d:.3} near={d:.3}\r", .{
                done, SAMPLES,
                @as(f64, @floatFromInt(exact_hits)) / @as(f64, @floatFromInt(done)),
                @as(f64, @floatFromInt(near_hits)) / @as(f64, @floatFromInt(done)),
            });
        }
    }
    std.debug.print("\n", .{});

    std.debug.print("error distribution (bf→ivf): ", .{});
    for (0..6) |bf| {
        for (0..6) |ivf| {
            if (bf != ivf and err_dist[bf][ivf] > 0)
                std.debug.print("bf={d}→ivf={d}:{d} ", .{ bf, ivf, err_dist[bf][ivf] });
        }
    }
    std.debug.print("\n", .{});

    const exact = @as(f64, @floatFromInt(exact_hits)) / SAMPLES;
    const near  = @as(f64, @floatFromInt(near_hits)) / SAMPLES;
    std.debug.print("exact agreement: {d:.4}  near(±1): {d:.4}\n", .{ exact, near });

    if (exact < MIN_AGREEMENT) {
        std.debug.print("FAIL: {d:.4} < {d:.2}\n", .{ exact, MIN_AGREEMENT });
        std.process.exit(1);
    }
    std.debug.print("PASS\n", .{});
}

fn bruteForce(q: [DIM]f32, points: []const DataPoint) u8 {
    var top5_d: [KNN]f32 = [_]f32{std.math.inf(f32)} ** KNN;
    var top5_l: [KNN]u8 = [_]u8{0} ** KNN;

    for (points) |p| {
        var s: f32 = 0;
        for (0..DIM) |d| { const diff = q[d] - p.vector[d]; s += diff * diff; }
        if (s < top5_d[KNN - 1]) {
            var j: usize = KNN - 1;
            while (j > 0 and top5_d[j - 1] > s) : (j -= 1) {
                top5_d[j] = top5_d[j - 1];
                top5_l[j] = top5_l[j - 1];
            }
            top5_d[j] = s;
            top5_l[j] = p.label;
        }
    }
    var fraud: u8 = 0;
    for (top5_l) |l| fraud += l;
    return fraud;
}

// ---- Minimal IVF index structures ----

const Cluster = struct {
    count: u32,
    labels: []u8,
    blocks: [][16 * DIM]i16,
};

const Index = struct {
    nprobe_default: u32,
    nprobe_boundary: u32,
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

fn loadIndex(gpa: std.mem.Allocator, path: []const u8) !Index {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(gpa, 100_000_000);
    defer gpa.free(data);

    var pos: usize = 0;
    const magic = r32(data, &pos);
    if (magic != 0x32465649) return error.BadMagic;
    _ = r32(data, &pos); // version
    const k = r32(data, &pos);
    const dim = r32(data, &pos);
    if (k != bi.K or dim != DIM) return error.DimMismatch;
    const np_def = r32(data, &pos);
    const np_bnd = r32(data, &pos);
    _ = ri32(data, &pos); // scale

    const centroids = try gpa.alloc([DIM]f32, k);
    errdefer gpa.free(centroids);
    for (centroids) |*c| for (c) |*v| { v.* = @bitCast(r32(data, &pos)); };

    const clusters = try gpa.alloc(Cluster, k);
    errdefer gpa.free(clusters);
    for (clusters, 0..) |*cl, ci| {
        _ = ci;
        const count = r32(data, &pos);
        const block_count = r32(data, &pos);
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
    return .{ .nprobe_default = np_def, .nprobe_boundary = np_bnd, .centroids = centroids, .clusters = clusters };
}

fn ivfSearch(q: [DIM]f32, idx: *const Index) u8 {
    const scale: f32 = @floatFromInt(bi.SCALE);
    var qi: [DIM]i16 = undefined;
    for (0..DIM) |i| qi[i] = @intFromFloat(@max(-32768.0, @min(32767.0, q[i] * scale)));

    const fc = searchNprobe(q, qi, idx, idx.nprobe_default);
    if (fc == 2 or fc == 3) return searchNprobe(q, qi, idx, idx.nprobe_boundary);
    return fc;
}

fn searchNprobe(q: [DIM]f32, qi: [DIM]i16, idx: *const Index, nprobe: u32) u8 {
    var probe_buf: [64]u32 = undefined;
    const np = @min(nprobe, 64);
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
            inline for (0..DIM) |dim| {
                const qv: V16i16 = @splat(qi[dim]);
                const bv: V16i16 = blk[dim * 16 ..][0..16].*;
                const diff: V16i16 = qv - bv;
                const diff32: V16i32 = @intCast(diff);
                dists += diff32 * diff32;
            }

            for (0..n) |j| {
                const d: i64 = dists[j];
                if (d < top5_d[KNN - 1]) {
                    var k2: usize = KNN - 1;
                    while (k2 > 0 and top5_d[k2 - 1] > d) : (k2 -= 1) {
                        top5_d[k2] = top5_d[k2 - 1];
                        top5_l[k2] = top5_l[k2 - 1];
                    }
                    top5_d[k2] = d;
                    top5_l[k2] = cl.labels[start + j];
                }
            }
        }
    }

    var fraud: u8 = 0;
    for (top5_l) |l| fraud += l;
    return fraud;
}

fn nearestCentroids(centroids: [][DIM]f32, q: [DIM]f32, out: []u32) void {
    var dists: [bi.K]f32 = undefined;
    for (centroids, 0..) |c, i| {
        var s: f32 = 0;
        for (0..DIM) |d| { const diff = q[d] - c[d]; s += diff * diff; }
        dists[i] = s;
    }
    for (out, 0..) |*slot, rank| {
        var best: f32 = std.math.inf(f32);
        var best_i: u32 = 0;
        for (dists, 0..) |d, i| {
            if (d < best) {
                var already = false;
                for (out[0..rank]) |prev| if (prev == i) { already = true; break; };
                if (!already) { best = d; best_i = @intCast(i); }
            }
        }
        slot.* = best_i;
    }
}

fn loadDataset(gpa: std.mem.Allocator, gz_path: []const u8) ![]DataPoint {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const temp = arena.allocator();
    const file = try std.fs.cwd().openFile(gz_path, .{});
    defer file.close();
    const gz = try file.readToEndAlloc(temp, 10_000_000);
    var aw: std.Io.Writer.Allocating = .init(temp);
    var in_reader: std.Io.Reader = .fixed(gz);
    var decomp: std.compress.flate.Decompress = .init(&in_reader, .gzip, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    const JsonEntry = struct { vector: [DIM]f32, label: []const u8 };
    const entries = try std.json.parseFromSliceLeaky([]JsonEntry, temp, aw.written(), .{ .ignore_unknown_fields = false });
    const pts = try gpa.alloc(DataPoint, entries.len);
    for (entries, 0..) |e, i| pts[i] = .{ .vector = e.vector, .label = if (e.label[0] == 'l') 0 else 1 };
    return pts;
}

fn r32(data: []const u8, pos: *usize) u32 {
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn ri32(data: []const u8, pos: *usize) i32 {
    const v = std.mem.readInt(i32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}
