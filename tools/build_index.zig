// Build step: reads references.json.gz, runs k-means++ (K=2048, 60 iterations),
// quantizes vectors to int16 (scale 5000), organizes in AoSoA16, writes index.bin.
//
// Run: zig run tools/build_index.zig -- resources/references.json.gz resources/index.bin

const std = @import("std");

pub const K: usize = 2048;
pub const DIM: usize = 14;
const ITERATIONS: usize = 60;
pub const SCALE: i16 = 5000; // max diff=10000, max diff^2=1e8, max sum(14)=1.4e9 < i32 max

// Magic "IVF2" as little-endian u32
const MAGIC: u32 = 0x32465649;
const VERSION: u32 = 1;
const NPROBE_DEFAULT: u32 = 8;
const NPROBE_BOUNDARY: u32 = 24;

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
        std.debug.print("usage: build_index <refs.json.gz> <out.bin>\n", .{});
        return error.MissingArgs;
    }

    std.debug.print("[1/5] loading {s}...\n", .{args[1]});
    const points = try loadDataset(gpa, args[1]);
    defer gpa.free(points);
    std.debug.print("      {} points\n", .{points.len});

    std.debug.print("[2/5] k-means++ K={d} iters={d}...\n", .{ K, ITERATIONS });
    const centroids = try kmeanspp(gpa, points);
    defer gpa.free(centroids);

    std.debug.print("[3/5] assigning clusters...\n", .{});
    const asgn = try assign(gpa, points, centroids);
    defer gpa.free(asgn);

    std.debug.print("[4/5] building & writing index to {s}...\n", .{args[2]});
    try writeIndex(gpa, args[2], centroids, points, asgn);
    std.debug.print("[5/5] done.\n", .{});
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
    const entries = try std.json.parseFromSliceLeaky([]JsonEntry, temp, aw.written(), .{
        .ignore_unknown_fields = false,
    });

    const pts = try gpa.alloc(DataPoint, entries.len);
    for (entries, 0..) |e, i| {
        pts[i] = .{ .vector = e.vector, .label = if (e.label[0] == 'l') 0 else 1 };
    }
    return pts;
}

fn kmeanspp(gpa: std.mem.Allocator, points: []const DataPoint) ![][DIM]f32 {
    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();

    const centroids = try gpa.alloc([DIM]f32, K);
    // min_dists[i] = squared distance from point i to its nearest centroid so far.
    // This is the standard D^2 weighting optimization: O(K*N) instead of O(K^2*N).
    const min_dists = try gpa.alloc(f64, points.len);
    defer gpa.free(min_dists);
    @memset(min_dists, std.math.inf(f64));

    const first = rand.intRangeLessThan(usize, 0, points.len);
    centroids[0] = points[first].vector;

    // Update min_dists after adding first centroid
    for (points, 0..) |p, i| {
        min_dists[i] = @floatCast(l2sq(p.vector, centroids[0]));
    }

    var k: usize = 1;
    while (k < K) : (k += 1) {
        if (k % 256 == 0) std.debug.print("  kmeans++ {d}/{d}\r", .{ k, K });
        var total: f64 = 0;
        for (min_dists) |d| total += d;

        var target = rand.float(f64) * total;
        var chosen: usize = points.len - 1;
        for (min_dists, 0..) |d, i| {
            target -= d;
            if (target <= 0) { chosen = i; break; }
        }
        centroids[k] = points[chosen].vector;

        // Update min_dists with the new centroid
        for (points, 0..) |p, i| {
            const d: f64 = @floatCast(l2sq(p.vector, centroids[k]));
            if (d < min_dists[i]) min_dists[i] = d;
        }
    }
    std.debug.print("\n", .{});

    // Lloyd iterations
    const asgn = try gpa.alloc(u32, points.len);
    defer gpa.free(asgn);
    const sums = try gpa.alloc([DIM]f64, K);
    defer gpa.free(sums);
    const counts = try gpa.alloc(u32, K);
    defer gpa.free(counts);

    var it: usize = 0;
    while (it < ITERATIONS) : (it += 1) {
        std.debug.print("  lloyd {d}/{d}\r", .{ it + 1, ITERATIONS });
        for (points, 0..) |p, i| asgn[i] = nearestCentroid(p.vector, centroids);
        @memset(sums, [_]f64{0} ** DIM);
        @memset(counts, 0);
        for (points, 0..) |p, i| {
            const c = asgn[i];
            counts[c] += 1;
            for (0..DIM) |d| sums[c][d] += p.vector[d];
        }
        for (0..K) |c| {
            if (counts[c] == 0) continue;
            const n: f64 = @floatFromInt(counts[c]);
            for (0..DIM) |d| centroids[c][d] = @floatCast(sums[c][d] / n);
        }
    }
    std.debug.print("\n", .{});
    return centroids;
}

fn nearestCentroid(v: [DIM]f32, ctrs: [][DIM]f32) u32 {
    var best_d: f32 = std.math.inf(f32);
    var best_i: u32 = 0;
    for (ctrs, 0..) |c, i| {
        const d = l2sq(v, c);
        if (d < best_d) { best_d = d; best_i = @intCast(i); }
    }
    return best_i;
}

fn l2sq(a: [DIM]f32, b: [DIM]f32) f32 {
    var s: f32 = 0;
    inline for (0..DIM) |i| { const d = a[i] - b[i]; s += d * d; }
    return s;
}

fn assign(gpa: std.mem.Allocator, pts: []const DataPoint, ctrs: [][DIM]f32) ![]u32 {
    const a = try gpa.alloc(u32, pts.len);
    for (pts, 0..) |p, i| a[i] = nearestCentroid(p.vector, ctrs);
    return a;
}

fn quantize(v: f32) i16 {
    const s: f32 = @floatFromInt(SCALE);
    return @intFromFloat(@max(-32768.0, @min(32767.0, v * s)));
}

// Index binary format (all little-endian):
//   u32 magic, u32 version, u32 K, u32 DIM, u32 nprobe_default, u32 nprobe_boundary, i32 scale
//   K * DIM * f32   (centroids)
//   for each cluster k in 0..K:
//     u32 count, u32 block_count
//     for each block b in 0..block_count:
//       16 bytes labels (1 per vector in block, padded with 0)
//       16 * DIM * i16 data  (AoSoA16: 16 vectors interleaved by dimension)
fn writeIndex(gpa: std.mem.Allocator, path: []const u8, centroids: [][DIM]f32, points: []const DataPoint, asgn: []const u32) !void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(gpa);
    const w = buf.writer(gpa);

    // Header
    try writeU32(w, MAGIC);
    try writeU32(w, VERSION);
    try writeU32(w, K);
    try writeU32(w, DIM);
    try writeU32(w, NPROBE_DEFAULT);
    try writeU32(w, NPROBE_BOUNDARY);
    try writeI32(w, SCALE);

    // Centroids
    for (centroids) |c| {
        for (c) |v| try writeF32(w, v);
    }

    // Cluster data
    const ClusterVec = struct { qi: [DIM]i16, label: u8 };
    const clusters = try gpa.alloc(std.ArrayList(ClusterVec), K);
    defer {
        for (clusters) |*cl| cl.deinit(gpa);
        gpa.free(clusters);
    }
    for (clusters) |*cl| cl.* = .{};

    for (points, 0..) |p, i| {
        var qi: [DIM]i16 = undefined;
        for (0..DIM) |d| qi[d] = quantize(p.vector[d]);
        try clusters[asgn[i]].append(gpa, .{ .qi = qi, .label = p.label });
    }

    for (clusters) |cl| {
        const cnt: u32 = @intCast(cl.items.len);
        const blk_cnt: u32 = (cnt + 15) / 16;
        try writeU32(w, cnt);
        try writeU32(w, blk_cnt);

        for (0..blk_cnt) |bi| {
            const start = bi * 16;
            const end = @min(start + 16, cl.items.len);
            const n = end - start;

            // Labels (16 bytes, padded with 0)
            for (start..end) |j| try w.writeByte(cl.items[j].label);
            for (n..16) |_| try w.writeByte(0);

            // AoSoA16 dimension-major layout: block[dim][vec] = [DIM][16]i16
            // Enables AVX2: load block[d][0..16] as @Vector(16,i16) per dim iteration
            for (0..DIM) |d| {
                for (0..16) |j| {
                    const v: i16 = if (j < n) cl.items[start + j].qi[d] else 0;
                    try writeI16(w, v);
                }
            }
        }
    }

    // Flush to file
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
    std.debug.print("  index: {} bytes, {} clusters\n", .{ buf.items.len, K });
}

fn writeU32(w: anytype, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try w.writeAll(&b);
}

fn writeI32(w: anytype, v: i32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, v, .little);
    try w.writeAll(&b);
}

fn writeF32(w: anytype, v: f32) !void {
    try writeU32(w, @bitCast(v));
}

fn writeI16(w: anytype, v: i16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(i16, &b, v, .little);
    try w.writeAll(&b);
}
