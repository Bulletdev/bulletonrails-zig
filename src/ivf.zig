// Phase 1: brute-force L2 KNN in float32.
// Phase 2 replaces this with IVF + int16 + AoSoA16 SIMD.

const dataset = @import("dataset.zig");
const DataPoint = dataset.DataPoint;

const K: usize = 5;

pub fn search(query: [14]f32, points: []const DataPoint) u8 {
    var top5: [K]f32 = [_]f32{std.math.inf(f32)} ** K;
    var top5_labels: [K]u8 = [_]u8{0} ** K;

    for (points) |p| {
        const dist = l2sq(query, p.vector);
        if (dist < top5[K - 1]) {
            insertSorted(&top5, &top5_labels, dist, p.label);
        }
    }

    var fraud_count: u8 = 0;
    for (top5_labels) |lbl| fraud_count += lbl;
    return fraud_count;
}

fn l2sq(a: [14]f32, b: [14]f32) f32 {
    var sum: f32 = 0.0;
    inline for (0..14) |i| {
        const d = a[i] - b[i];
        sum += d * d;
    }
    return sum;
}

// Insertion sort into a sorted ascending array (smallest first).
fn insertSorted(dists: *[K]f32, labels: *[K]u8, dist: f32, label: u8) void {
    var i: usize = K - 1;
    while (i > 0 and dists[i - 1] > dist) : (i -= 1) {
        dists[i] = dists[i - 1];
        labels[i] = labels[i - 1];
    }
    dists[i] = dist;
    labels[i] = label;
}

const std = @import("std");
