const std = @import("std");

pub const DataPoint = struct {
    vector: [14]f32,
    label: u8, // 0 = legit, 1 = fraud
};

const JsonEntry = struct {
    vector: [14]f32,
    label: []const u8,
};

pub fn load(gpa: std.mem.Allocator, gz_path: []const u8) ![]DataPoint {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const temp = arena.allocator();

    const json_bytes = try decompressFile(temp, gz_path);
    const entries = try std.json.parseFromSliceLeaky([]JsonEntry, temp, json_bytes, .{
        .ignore_unknown_fields = false,
    });

    const points = try gpa.alloc(DataPoint, entries.len);
    for (entries, 0..) |e, i| {
        points[i] = .{
            .vector = e.vector,
            .label = if (e.label[0] == 'l') 0 else 1,
        };
    }
    return points;
}

fn decompressFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const gz = try file.readToEndAlloc(allocator, 10_000_000);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    var in_reader: std.Io.Reader = .fixed(gz);
    var decomp: std.compress.flate.Decompress = .init(&in_reader, .gzip, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    return aw.written();
}
