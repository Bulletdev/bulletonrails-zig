const std = @import("std");

const MAX_AMOUNT: f32 = 10_000.0;
const MAX_INSTALLMENTS: f32 = 12.0;
const AMOUNT_VS_AVG_RATIO: f32 = 10.0;
const MAX_MINUTES: f32 = 1440.0;
const MAX_KM: f32 = 1000.0;
const MAX_TX_COUNT_24H: f32 = 20.0;
const MAX_MERCHANT_AVG_AMOUNT: f32 = 10_000.0;

const DOW_TABLE = [12]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };

pub const LastTx = struct {
    timestamp: []const u8,
    km_from_current: f64,
};

pub const Payload = struct {
    tx_amount: f64,
    tx_installments: f64,
    tx_requested_at: []const u8,
    cust_avg_amount: f64,
    cust_tx_count_24h: f64,
    cust_merch_known: bool,
    merch_mcc: []const u8,
    merch_avg_amount: f64,
    term_km_from_home: f64,
    term_is_online: bool,
    term_card_present: bool,
    last_tx: ?LastTx,
};

pub fn normalize(p: *const Payload) [14]f32 {
    var v: [14]f32 = undefined;

    const hour, const dow = parseDatetime(p.tx_requested_at);

    v[0] = clamp(@as(f32, @floatCast(p.tx_amount)) / MAX_AMOUNT);
    v[1] = clamp(@as(f32, @floatCast(p.tx_installments)) / MAX_INSTALLMENTS);
    v[2] = amountRatio(p.tx_amount, p.cust_avg_amount);
    v[3] = @as(f32, @floatFromInt(hour)) / 23.0;
    v[4] = @as(f32, @floatFromInt(dow)) / 6.0;

    if (p.last_tx) |lt| {
        const mins = minutesDiff(p.tx_requested_at, lt.timestamp);
        v[5] = clamp(mins / MAX_MINUTES);
        v[6] = clamp(@as(f32, @floatCast(lt.km_from_current)) / MAX_KM);
    } else {
        v[5] = -1.0;
        v[6] = -1.0;
    }

    v[7] = clamp(@as(f32, @floatCast(p.term_km_from_home)) / MAX_KM);
    v[8] = clamp(@as(f32, @floatCast(p.cust_tx_count_24h)) / MAX_TX_COUNT_24H);
    v[9] = if (p.term_is_online) 1.0 else 0.0;
    v[10] = if (p.term_card_present) 1.0 else 0.0;
    v[11] = if (p.cust_merch_known) 0.0 else 1.0;
    v[12] = mccRisk(p.merch_mcc);
    v[13] = clamp(@as(f32, @floatCast(p.merch_avg_amount)) / MAX_MERCHANT_AVG_AMOUNT);

    return v;
}

fn clamp(val: f32) f32 {
    if (val < 0.0) return 0.0;
    if (val > 1.0) return 1.0;
    return val;
}

fn amountRatio(amount: f64, avg: f64) f32 {
    if (avg == 0.0) return 0.0;
    return clamp(@as(f32, @floatCast((amount / avg) / AMOUNT_VS_AVG_RATIO)));
}

fn mccRisk(mcc: []const u8) f32 {
    if (mcc.len < 4) return 0.5;
    const n = std.fmt.parseInt(u16, mcc, 10) catch return 0.5;
    return switch (n) {
        4511 => 0.35,
        5311 => 0.25,
        5411 => 0.15,
        5812 => 0.30,
        5912 => 0.20,
        5944 => 0.45,
        5999 => 0.50,
        7801 => 0.80,
        7802 => 0.75,
        7995 => 0.85,
        else => 0.5,
    };
}

// Returns {hour, day_of_week} from "YYYY-MM-DDTHH:MM:SSZ"
// day_of_week: Monday=0, Sunday=6 (Rata Die formula, matches Ruby)
fn parseDatetime(ts: []const u8) struct { u8, u8 } {
    if (ts.len < 19) return .{ 0, 0 };
    const year = parseInt4(ts[0..4]);
    const mon = parseInt2(ts[5..7]);
    const dom = parseInt2(ts[8..10]);
    const hour: u8 = @intCast(parseInt2(ts[11..13]));

    const adj_y: i32 = if (mon < 3) @as(i32, year) - 1 else @as(i32, year);
    const sum = adj_y +
        @divFloor(adj_y, 4) -
        @divFloor(adj_y, 100) +
        @divFloor(adj_y, 400) +
        DOW_TABLE[@intCast(mon - 1)] +
        @as(i32, dom);
    const wday: u8 = @intCast(@mod(sum, 7));
    const dow: u8 = (wday + 6) % 7;

    return .{ hour, dow };
}

// Returns minutes between requested_at and last timestamp.
// Both are "YYYY-MM-DDTHH:MM:SSZ". Result may be negative (clamped to 0 by caller).
fn minutesDiff(requested_at: []const u8, last_ts: []const u8) f32 {
    const t1 = toUnixSeconds(requested_at);
    const t2 = toUnixSeconds(last_ts);
    return @as(f32, @floatFromInt(t1 - t2)) / 60.0;
}

fn toUnixSeconds(ts: []const u8) i64 {
    if (ts.len < 19) return 0;
    const y = parseInt4(ts[0..4]);
    const mo = parseInt2(ts[5..7]);
    const d = parseInt2(ts[8..10]);
    const h = parseInt2(ts[11..13]);
    const mi = parseInt2(ts[14..16]);
    const s = parseInt2(ts[17..19]);

    // JDN formula (proleptic Gregorian)
    const a: i64 = @intCast(@divFloor(14 - @as(i32, mo), 12));
    const y2: i64 = @as(i64, y) + 4800 - a;
    const m2: i64 = @as(i64, mo) + 12 * a - 3;
    const jdn: i64 = @as(i64, d) +
        @divFloor(153 * m2 + 2, 5) +
        365 * y2 +
        @divFloor(y2, 4) -
        @divFloor(y2, 100) +
        @divFloor(y2, 400) -
        32045;
    // Unix epoch 1970-01-01 = JDN 2440588
    const days_since_epoch: i64 = jdn - 2440588;
    return days_since_epoch * 86400 + @as(i64, h) * 3600 + @as(i64, mi) * 60 + @as(i64, s);
}

fn parseInt4(s: []const u8) i32 {
    return @as(i32, s[0] - '0') * 1000 +
        @as(i32, s[1] - '0') * 100 +
        @as(i32, s[2] - '0') * 10 +
        @as(i32, s[3] - '0');
}

fn parseInt2(s: []const u8) i32 {
    return @as(i32, s[0] - '0') * 10 + @as(i32, s[1] - '0');
}
