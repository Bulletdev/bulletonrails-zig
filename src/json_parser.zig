// Zero-alloc JSON scanner for the fraud-score payload.
// Searches for field names as literal substrings; no tokenizer, no allocations.
// Field order in the payload is not assumed.

const std = @import("std");
const normalizer = @import("normalizer.zig");

pub const Payload = normalizer.Payload;
pub const LastTx = normalizer.LastTx;

pub fn parse(buf: []const u8) !Payload {
    const tx_amount = findFloat(buf, "\"amount\":");
    const tx_installments = findFloatOrDefault(buf, "\"installments\":", 1.0);
    const tx_requested_at = findStringInContext(buf, "\"transaction\"", "\"requested_at\":") orelse
        return error.MissingRequestedAt;
    const cust_avg_amount = findFloatAfter(buf, "\"customer\"", "\"avg_amount\":");
    const cust_tx_count_24h = findFloatAfter(buf, "\"customer\"", "\"tx_count_24h\":");
    const merch_id = findStringAfter(buf, "\"merchant\"", "\"id\":") orelse "";
    const merch_mcc = findStringAfter(buf, "\"merchant\"", "\"mcc\":") orelse "";
    const merch_avg_amount = findFloatAfter(buf, "\"merchant\"", "\"avg_amount\":");
    const term_km_from_home = findFloat(buf, "\"km_from_home\":");
    const term_is_online = findBool(buf, "\"is_online\":");
    const term_card_present = findBool(buf, "\"card_present\":");

    const cust_merch_known = checkKnownMerchant(buf, merch_id);

    var last_tx: ?LastTx = null;
    const lt_key = "\"last_transaction\":";
    if (std.mem.indexOf(u8, buf, lt_key)) |p| {
        const after = skipWs(buf[p + lt_key.len ..]);
        if (after.len > 0 and after[0] != 'n') {
            const lt_ts = findStringInContext(buf, "\"last_transaction\"", "\"timestamp\":") orelse "";
            const lt_km = findFloatAfter(buf, "\"last_transaction\"", "\"km_from_current\":");
            last_tx = .{ .timestamp = lt_ts, .km_from_current = lt_km };
        }
    }

    return Payload{
        .tx_amount = tx_amount,
        .tx_installments = tx_installments,
        .tx_requested_at = tx_requested_at,
        .cust_avg_amount = cust_avg_amount,
        .cust_tx_count_24h = cust_tx_count_24h,
        .cust_merch_known = cust_merch_known,
        .merch_mcc = merch_mcc,
        .merch_avg_amount = merch_avg_amount,
        .term_km_from_home = term_km_from_home,
        .term_is_online = term_is_online,
        .term_card_present = term_card_present,
        .last_tx = last_tx,
    };
}

fn skipWs(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\r' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn findFloat(s: []const u8, key: []const u8) f64 {
    const p = std.mem.indexOf(u8, s, key) orelse return 0;
    return parseF64(skipWs(s[p + key.len ..]));
}

fn findFloatOrDefault(s: []const u8, key: []const u8, default: f64) f64 {
    const p = std.mem.indexOf(u8, s, key) orelse return default;
    return parseF64(skipWs(s[p + key.len ..]));
}

fn findFloatAfter(s: []const u8, ctx: []const u8, key: []const u8) f64 {
    const cp = std.mem.indexOf(u8, s, ctx) orelse return 0;
    const sub = s[cp..];
    const p = std.mem.indexOf(u8, sub, key) orelse return 0;
    return parseF64(skipWs(sub[p + key.len ..]));
}

fn findBool(s: []const u8, key: []const u8) bool {
    const p = std.mem.indexOf(u8, s, key) orelse return false;
    const rest = skipWs(s[p + key.len ..]);
    return rest.len >= 4 and std.mem.eql(u8, rest[0..4], "true");
}

fn findStringSlice(s: []const u8) ?[]const u8 {
    const rest = skipWs(s);
    if (rest.len == 0 or rest[0] != '"') return null;
    var end: usize = 1;
    while (end < rest.len and rest[end] != '"') end += 1;
    return rest[1..end];
}

fn findStringAfter(s: []const u8, ctx: []const u8, key: []const u8) ?[]const u8 {
    const cp = std.mem.indexOf(u8, s, ctx) orelse return null;
    const sub = s[cp..];
    const p = std.mem.indexOf(u8, sub, key) orelse return null;
    return findStringSlice(sub[p + key.len ..]);
}

fn findStringInContext(s: []const u8, ctx: []const u8, key: []const u8) ?[]const u8 {
    return findStringAfter(s, ctx, key);
}

fn parseF64(s: []const u8) f64 {
    var end: usize = 0;
    while (end < s.len) {
        const c = s[end];
        if (c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E' or (c >= '0' and c <= '9')) {
            end += 1;
        } else break;
    }
    if (end == 0) return 0;
    return std.fmt.parseFloat(f64, s[0..end]) catch 0;
}

fn checkKnownMerchant(buf: []const u8, merch_id: []const u8) bool {
    if (merch_id.len == 0) return false;
    const key = "\"known_merchants\":";
    const p = std.mem.indexOf(u8, buf, key) orelse return false;
    const after = buf[p + key.len ..];
    const bracket = std.mem.indexOfScalar(u8, after, '[') orelse return false;
    const array = after[bracket..];
    var pos: usize = 1;
    while (pos < array.len) {
        const q = std.mem.indexOfScalarPos(u8, array, pos, '"') orelse break;
        const start = q + 1;
        const end_q = std.mem.indexOfScalarPos(u8, array, start, '"') orelse break;
        if (std.mem.eql(u8, array[start..end_q], merch_id)) return true;
        pos = end_q + 1;
    }
    return false;
}
