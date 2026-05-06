const std = @import("std");
const json_parser = @import("json_parser.zig");
const normalizer = @import("normalizer.zig");

pub fn main() !void {
    const cases = [_]struct {
        buf: []const u8,
        expected: [14]f32,
        id: []const u8,
    }{
        .{
            .id = "tx-2870794086",
            .buf =
                \\{"id":"tx-2870794086","transaction":{"amount":4178.7,"installments":7,"requested_at":"2026-03-10T04:08:50Z"},"customer":{"avg_amount":197.67,"tx_count_24h":13,"known_merchants":["MERC-005","MERC-007","MERC-012","MERC-009","MERC-008"]},"merchant":{"id":"MERC-076","mcc":"7995","avg_amount":85.01},"terminal":{"is_online":true,"card_present":false,"km_from_home":898.0523206056},"last_transaction":{"timestamp":"2026-03-10T03:59:50Z","km_from_current":427.888266609}}
            ,
            .expected = .{0.4179, 0.5833, 1, 0.1739, 0.1667, 0.0063, 0.4279, 0.8981, 0.65, 1, 0, 1, 0.85, 0.0085},
        },
        .{
            .id = "tx-1329056812",
            .buf =
                \\{"id":"tx-1329056812","transaction":{"amount":41.12,"installments":2,"requested_at":"2026-03-11T18:45:53Z"},"customer":{"avg_amount":82.24,"tx_count_24h":3,"known_merchants":["MERC-003","MERC-016"]},"merchant":{"id":"MERC-016","mcc":"5411","avg_amount":60.25},"terminal":{"is_online":false,"card_present":true,"km_from_home":29.2331036248},"last_transaction":null}
            ,
            .expected = .{0.0041, 0.1667, 0.05, 0.7826, 0.3333, -1, -1, 0.0292, 0.15, 0, 1, 0, 0.15, 0.006},
        },
        .{
            .id = "tx-3330991687",
            .buf =
                \\{"id":"tx-3330991687","transaction":{"amount":9505.97,"installments":10,"requested_at":"2026-03-14T05:15:12Z"},"customer":{"avg_amount":81.28,"tx_count_24h":20,"known_merchants":["MERC-008","MERC-007","MERC-005"]},"merchant":{"id":"MERC-068","mcc":"7802","avg_amount":54.86},"terminal":{"is_online":false,"card_present":true,"km_from_home":952.2745933273},"last_transaction":null}
            ,
            .expected = .{0.9506, 0.8333, 1.0, 0.2174, 0.8333, -1, -1, 0.9523, 1.0, 0, 1, 1, 0.75, 0.0055},
        },
    };

    for (cases) |tc| {
        const payload = json_parser.parse(tc.buf) catch |err| {
            std.debug.print("PARSE ERROR for {s}: {}\n", .{tc.id, err});
            continue;
        };
        const v = normalizer.normalize(&payload);

        var ok = true;
        for (v, tc.expected, 0..) |got, exp, i| {
            if (@abs(got - exp) > 0.001) {
                if (ok) std.debug.print("MISMATCH {s}:\n", .{tc.id});
                std.debug.print("  dim[{d}]: got={d:.4} exp={d:.4}\n", .{i, got, exp});
                ok = false;
            }
        }
        if (ok) {
            std.debug.print("OK {s}\n", .{tc.id});
        } else {
            std.debug.print("  Parsed: tx_amount={d} installments={d} requested_at='{s}'\n",
                .{payload.tx_amount, payload.tx_installments, payload.tx_requested_at});
            std.debug.print("  cust_avg={d} tx_count={d} merch_known={}\n",
                .{payload.cust_avg_amount, payload.cust_tx_count_24h, payload.cust_merch_known});
            std.debug.print("  merch_mcc='{s}' merch_avg={d} km_home={d}\n",
                .{payload.merch_mcc, payload.merch_avg_amount, payload.term_km_from_home});
            std.debug.print("  is_online={} card_present={}\n",
                .{payload.term_is_online, payload.term_card_present});
            if (payload.last_tx) |lt| {
                std.debug.print("  last_tx_ts='{s}' km_curr={d}\n",
                    .{lt.timestamp, lt.km_from_current});
            } else {
                std.debug.print("  last_tx=null\n", .{});
            }
        }
    }
}
