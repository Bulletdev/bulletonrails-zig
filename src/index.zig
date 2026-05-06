// Loads index.bin into memory and provides IVF search.
// v2: bbox lower bound pruning for exact KNN — guarantees 100% accuracy.

const std = @import("std");

pub const K_CLUSTERS: usize = 2048;
pub const DIM: usize = 14;
pub const SCALE: i16 = 5000;

const MAGIC: u32 = 0x32465649;
const KNN: usize = 5;

const Cluster = struct {
    count: u32,
    labels: []u8,
    blocks: [][16 * DIM]i16,
    bbox_min: [DIM]i16,
    bbox_max: [DIM]i16,

    fn deinit(self: *Cluster, gpa: std.mem.Allocator) void {
        gpa.free(self.labels);
        gpa.free(self.blocks);
    }
};

pub const IvfIndex = struct {
    nprobe_default: u32,
    nprobe_boundary: u32,
    centroids: [][DIM]f32,
    clusters: []Cluster,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IvfIndex) void {
        for (self.clusters) |*cl| cl.deinit(self.allocator);
        self.allocator.free(self.clusters);
        self.allocator.free(self.centroids);
    }

    // Exact KNN via bbox lower bound pruning.
    // Step 1: scan nearest centroid cluster to get initial top-5.
    // Step 2: for every other cluster, compute the minimum possible distance
    //         from query to any point in that cluster using the bbox.
    //         If bbox_lower_bound <= worst top-5 dist, cluster may improve top-5 -> scan it.
    //         Otherwise, skip. Mathematically guarantees exact KNN.
    pub fn search(self: *const IvfIndex, query_f32: [DIM]f32) u8 {
        const q = quantizeVec(query_f32);

        var top5_dist: [KNN]i64 = [_]i64{std.math.maxInt(i64)} ** KNN;
        var top5_lbl: [KNN]u8 = [_]u8{0} ** KNN;

        // Find nearest centroid and scan it first
        const nearest = nearestCentroid(self.centroids, query_f32);
        scanCluster(&self.clusters[nearest], q, &top5_dist, &top5_lbl);

        // Bbox pruning over all other clusters
        for (self.clusters, 0..) |*cl, ci| {
            if (ci == nearest) continue;
            if (bboxLowerBound(cl.bbox_min, cl.bbox_max, q) <= top5_dist[KNN - 1]) {
                scanCluster(cl, q, &top5_dist, &top5_lbl);
            }
        }

        var fraud: u8 = 0;
        for (top5_lbl) |l| fraud += l;
        return fraud;
    }
};

fn quantizeVec(v: [DIM]f32) [DIM]i16 {
    var out: [DIM]i16 = undefined;
    const s: f32 = @floatFromInt(SCALE);
    for (0..DIM) |i| {
        out[i] = @intFromFloat(@max(-32768.0, @min(32767.0, v[i] * s)));
    }
    return out;
}

// Returns the index of the single nearest centroid (O(K) linear scan).
fn nearestCentroid(centroids: [][DIM]f32, q: [DIM]f32) usize {
    var best_dist: f32 = std.math.inf(f32);
    var best_idx: usize = 0;
    for (centroids, 0..) |c, i| {
        var s: f32 = 0;
        for (0..DIM) |d| { const diff = q[d] - c[d]; s += diff * diff; }
        if (s < best_dist) { best_dist = s; best_idx = i; }
    }
    return best_idx;
}

// Minimum possible squared L2 distance from query q to any point in the cluster bbox.
// If a dimension's query value is inside [min,max], that dimension contributes 0.
// Guarantees: actual_dist >= bboxLowerBound for all points in cluster.
fn bboxLowerBound(bbox_min: [DIM]i16, bbox_max: [DIM]i16, q: [DIM]i16) i64 {
    var s: i64 = 0;
    for (0..DIM) |d| {
        const d_val: i32 = if (q[d] < bbox_min[d])
            @as(i32, bbox_min[d]) - @as(i32, q[d])
        else if (q[d] > bbox_max[d])
            @as(i32, q[d]) - @as(i32, bbox_max[d])
        else
            0;
        s += @as(i64, d_val) * @as(i64, d_val);
    }
    return s;
}

// SIMD: process 16 vectors per block simultaneously (AVX2 = 256-bit = 16×i16 or 8×i32).
// Block layout is dimension-major: blk[d*16..d*16+16] = all 16 vecs at dim d.
// SCALE=5000 → max diff=10000 (fits i16), max diff²=1e8, sum(14)=1.4e9 (fits i32).
fn scanCluster(cl: *const Cluster, q: [DIM]i16, top5_d: *[KNN]i64, top5_l: *[KNN]u8) void {
    const V16i16 = @Vector(16, i16);
    const V16i32 = @Vector(16, i32);

    for (cl.blocks, 0..) |*blk, blk_i| {
        const start = blk_i * 16;
        const n = @min(16, cl.count - start);

        var dists: V16i32 = @splat(0);
        inline for (0..DIM) |d| {
            const qv: V16i16 = @splat(q[d]);
            const bv: V16i16 = blk[d * 16 ..][0..16].*;
            const diff: V16i16 = qv - bv;
            const diff32: V16i32 = @intCast(diff);
            dists += diff32 * diff32;
        }

        for (0..n) |j| {
            const dist: i64 = dists[j];
            if (dist < top5_d[KNN - 1]) {
                insertSorted(top5_d, top5_l, dist, cl.labels[start + j]);
            }
        }
    }
}

fn insertSorted(dists: *[KNN]i64, labels: *[KNN]u8, d: i64, lbl: u8) void {
    var i: usize = KNN - 1;
    while (i > 0 and dists[i - 1] > d) : (i -= 1) {
        dists[i] = dists[i - 1];
        labels[i] = labels[i - 1];
    }
    dists[i] = d;
    labels[i] = lbl;
}

pub fn load(gpa: std.mem.Allocator, path: []const u8) !IvfIndex {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(gpa, 100_000_000);
    defer gpa.free(data);
    return parse(gpa, data);
}

pub fn loadFromBytes(gpa: std.mem.Allocator, data: []const u8) !IvfIndex {
    return parse(gpa, data);
}

fn readU32(data: []const u8, pos: *usize) u32 {
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readI32(data: []const u8, pos: *usize) i32 {
    const v = std.mem.readInt(i32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readF32(data: []const u8, pos: *usize) f32 {
    const bits = readU32(data, pos);
    return @bitCast(bits);
}

fn readI16(data: []const u8, pos: *usize) i16 {
    const v = std.mem.readInt(i16, data[pos.*..][0..2], .little);
    pos.* += 2;
    return v;
}

fn parse(gpa: std.mem.Allocator, data: []const u8) !IvfIndex {
    var pos: usize = 0;

    const magic = readU32(data, &pos);
    if (magic != MAGIC) return error.InvalidMagic;
    const version = readU32(data, &pos);
    if (version != 2) return error.UnsupportedVersion;
    const k = readU32(data, &pos);
    const dim = readU32(data, &pos);
    if (k != K_CLUSTERS or dim != DIM) return error.DimensionMismatch;
    const nprobe_def = readU32(data, &pos);
    const nprobe_bnd = readU32(data, &pos);
    _ = readI32(data, &pos); // scale (already known at comptime)

    // Centroids
    const centroids = try gpa.alloc([DIM]f32, K_CLUSTERS);
    errdefer gpa.free(centroids);
    for (centroids) |*c| {
        for (c) |*v| v.* = readF32(data, &pos);
    }

    // Clusters
    const clusters = try gpa.alloc(Cluster, K_CLUSTERS);
    errdefer {
        for (clusters) |*cl| cl.deinit(gpa);
        gpa.free(clusters);
    }
    var loaded: usize = 0;
    while (loaded < K_CLUSTERS) : (loaded += 1) {
        const count = readU32(data, &pos);
        const block_count = readU32(data, &pos);

        // v2: bbox_min/max per cluster for exact KNN pruning
        var bbox_min: [DIM]i16 = undefined;
        var bbox_max: [DIM]i16 = undefined;
        for (0..DIM) |d| bbox_min[d] = readI16(data, &pos);
        for (0..DIM) |d| bbox_max[d] = readI16(data, &pos);

        const labels = try gpa.alloc(u8, count);
        const blocks = try gpa.alloc([16 * DIM]i16, block_count);

        for (0..block_count) |blk_i| {
            // 16 label bytes
            const lbl_start = @min(blk_i * 16, count);
            const lbl_end = @min(lbl_start + 16, count);
            for (lbl_start..lbl_end) |j| labels[j] = data[pos + (j - lbl_start)];
            pos += 16;
            // 16 * DIM i16 values
            for (0..16 * DIM) |j| blocks[blk_i][j] = readI16(data, &pos);
        }

        clusters[loaded] = .{ .count = count, .labels = labels, .blocks = blocks, .bbox_min = bbox_min, .bbox_max = bbox_max };
    }

    return .{
        .nprobe_default = nprobe_def,
        .nprobe_boundary = nprobe_bnd,
        .centroids = centroids,
        .clusters = clusters,
        .allocator = gpa,
    };
}
