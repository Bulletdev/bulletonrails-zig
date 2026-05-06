// Loads index.bin into memory and provides IVF search.
// Phase 2: int16 vectors, float32 centroid distances, nprobe clusters visited.

const std = @import("std");

pub const K_CLUSTERS: usize = 2048;
pub const DIM: usize = 14;
pub const SCALE: i16 = 5000;

const MAGIC: u32 = 0x32465649;
const KNN: usize = 5;

const Cluster = struct {
    count: u32,
    // labels: one per vector (0=legit, 1=fraud), interleaved in blocks of 16
    labels: []u8,
    // vectors: count vectors of DIM i16, stored in blocks of 16
    // block layout: [vec_in_block][dim] i16, 16 vecs per block
    blocks: [][16 * DIM]i16,

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

    pub fn search(self: *const IvfIndex, query_f32: [DIM]f32) u8 {
        const query = quantizeVec(query_f32);
        const query_f = query_f32; // for centroid distance
        const np = self.nprobe_default;

        const fraud = self.searchWithNprobe(query, query_f, np);
        if (fraud == 2 or fraud == 3) {
            return self.searchWithNprobe(query, query_f, self.nprobe_boundary);
        }
        return fraud;
    }

    fn searchWithNprobe(self: *const IvfIndex, query_i16: [DIM]i16, query_f32: [DIM]f32, nprobe: u32) u8 {
        var probe_buf: [64]u32 = undefined; // nprobe_boundary = 24 max
        const np = @min(nprobe, 64);
        const probes = probe_buf[0..np];
        nearestCentroids(self.centroids, query_f32, probes);

        // Top-5 heap: dists[0] is the farthest (worst best so far)
        var top5_dist: [KNN]i64 = [_]i64{std.math.maxInt(i64)} ** KNN;
        var top5_lbl: [KNN]u8 = [_]u8{0} ** KNN;

        for (probes) |ci| {
            const cl = &self.clusters[ci];
            scanCluster(cl, query_i16, &top5_dist, &top5_lbl);
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

// O(K*log(nprobe)) via max-heap instead of O(K*nprobe) repeated selection.
fn nearestCentroids(centroids: [][DIM]f32, q: [DIM]f32, out: []u32) void {
    const np = out.len;
    var h_dist: [64]f32 = [_]f32{std.math.inf(f32)} ** 64;
    var h_idx: [64]u32 = [_]u32{0} ** 64;
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

    // Extract smallest-first by repeatedly removing the max (heap sort).
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
    if (version != 1) return error.UnsupportedVersion;
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

        clusters[loaded] = .{ .count = count, .labels = labels, .blocks = blocks };
    }

    return .{
        .nprobe_default = nprobe_def,
        .nprobe_boundary = nprobe_bnd,
        .centroids = centroids,
        .clusters = clusters,
        .allocator = gpa,
    };
}
