const std = @import("std");
const json_parser = @import("json_parser.zig");
const normalizer = @import("normalizer.zig");

const PAYLOAD =
    \\{"id":"tx-123","transaction":{"amount":150.0,"installments":2,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":82.24,"tx_count_24h":3,"known_merchants":["MERC-003","MERC-016"]},"merchant":{"id":"MERC-016","mcc":"5411","avg_amount":60.25},"terminal":{"is_online":false,"card_present":true,"km_from_home":29.23},"last_transaction":null}
;

const PAYLOAD_WITH_LT =
    \\{"id":"tx-456","transaction":{"amount":500.0,"installments":1,"requested_at":"2026-03-14T05:15:12Z"},"customer":{"avg_amount":81.28,"tx_count_24h":20,"known_merchants":["MERC-008","MERC-007"]},"merchant":{"id":"MERC-068","mcc":"7802","avg_amount":54.86},"terminal":{"is_online":false,"card_present":true,"km_from_home":952.27},"last_transaction":{"timestamp":"2026-03-14T04:00:00Z","km_from_current":25.5}}
;

pub fn main() !void {
    const N = 50_000;
    var sink: u64 = 0;

    // Warmup
    for (0..500) |_| {
        const p = try json_parser.parse(PAYLOAD);
        const v = normalizer.normalize(&p);
        sink += @as(u64, @intFromFloat(v[0] * 1000));
    }

    // Bench JSON parse only
    var timer = try std.time.Timer.start();
    for (0..N) |_| {
        const p = try json_parser.parse(PAYLOAD);
        sink += @intFromBool(p.cust_merch_known);
    }
    const t_parse = timer.read();

    // Bench normalize only (pre-parse payload)
    const pre_parsed = try json_parser.parse(PAYLOAD);
    timer.reset();
    for (0..N) |_| {
        const v = normalizer.normalize(&pre_parsed);
        sink += @as(u64, @intFromFloat(v[0] * 1000));
    }
    const t_norm = timer.read();

    // Bench parse+normalize together
    timer.reset();
    for (0..N) |_| {
        const p = try json_parser.parse(PAYLOAD_WITH_LT);
        const v = normalizer.normalize(&p);
        sink += @as(u64, @intFromFloat(v[0] * 1000));
    }
    const t_both = timer.read();

    std.debug.print("sink={d}\n", .{sink});
    std.debug.print("JSON parse only:     {d}ns = {d:.3}ms/call\n", .{ t_parse / N, @as(f64, @floatFromInt(t_parse / N)) / 1e6 });
    std.debug.print("Normalize only:      {d}ns = {d:.3}ms/call\n", .{ t_norm / N, @as(f64, @floatFromInt(t_norm / N)) / 1e6 });
    std.debug.print("Parse+Norm (w/ LT):  {d}ns = {d:.3}ms/call\n", .{ t_both / N, @as(f64, @floatFromInt(t_both / N)) / 1e6 });
}
