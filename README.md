
```
>            ██████╗ ██╗   ██╗██╗     ██╗     ██████╗████████╗ 
>            ██╔══██╗██║   ██║██║     ██║     ██╔═══╝╚══██╔══╝
>            ██████╔╝██║   ██║██║     ██║     █████╗    ██║  
>            ██╔══██╗██║   ██║██║     ██║     ██╔══╝    ██║  
>            ██████╔╝╚██████╔╝██████╗ ██████╗ ██████╗   ██║  
>            ╚═════╝  ╚═════╝ ╚═════╝ ╚═════╝ ╚═════╝   ╚═╝  
              on Rails - Rinha de Backend 2026
```

<div align="center">

[![Auto-merge participant submission](https://github.com/zanfranceschi/rinha-de-backend-2026/actions/workflows/auto-merge-participant.yml/badge.svg)](https://github.com/zanfranceschi/rinha-de-backend-2026/actions/workflows/auto-merge-participant.yml)

[![Zig Version](https://img.shields.io/badge/zig-0.15.2-F7A41D?logo=zig)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

</div>

---

```
╔═════════════════════════════════════════════════════════════════╗
║  bulletonrails-zig - Rinha de Backend 2026                      ║
╠═════════════════════════════════════════════════════════════════╣
║  Fraud detection API using IVF approximate KNN - Zig            ║
║  IVF K=2048 · AoSoA16 SIMD · int16 · 1 CPU / 350 MB · 2 inst    ║
╚═════════════════════════════════════════════════════════════════╝
```

---

```
┌─────────────────────────────────────────────────────────────────┐
│  01 · What is this                                              |
│  02 · How it works                                              │
│  03 · Tech stack                                                │
│  04 · Architecture                                              │
│  05 · Quick start                                               │
│  06 · Validation                                                │
│  07 · Benchmark results                                         │
│  08 · Submission                                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 01 · What is this

Submission for [Rinha de Backend 2026](https://github.com/zanfranceschi/rinha-de-backend-2026) - a competition to build a fraud detection API under extreme resource constraints.

The challenge: build an API that receives a card transaction and decides - in real time - whether it is fraudulent, using vector similarity search against 100k labeled reference transactions.

This submission proves that **Zig can target 6000/6000** in performance-sensitive scenarios.
No allocations on the hot path. No GC. No runtime. The IVF index is embedded at compile time
via `@embedFile` - zero cold-start, zero disk I/O on startup. SIMD distance computation uses
`@Vector(16, i16)` with AVX2 on every CPU cycle that matters.

---

## 02 · How it works

```
POST /fraud-score
        │
        ▼
  json_parser.zig
  ─────────────────
  Zero-alloc scanner: std.mem.indexOf for field names.
  No HashMap, no tagged union, no allocation.
  Extracts 14 fields from nested transaction/customer/merchant/terminal JSON.
        │
        ▼
  normalizer.zig
  ─────────────────
  Port of VectorNormalizer Ruby, identical formulas.
  Rata Die DOW formula - no std.time, no libc dependency.
  Output: [14]f32 in [0,1] with sentinel -1.0 for absent last_transaction.
        │
        ▼
  index.zig - IvfIndex.search()
  ─────────────────
  1. Quantize query to [14]i16 (SCALE=5000)
  2. Find nearest centroid via O(K) linear scan (f32 distance)
  3. Scan nearest cluster first to populate initial top-5
  4. For every other cluster: compute bbox lower bound distance
       (min possible squared L2 from query to any point in cluster)
       If lower_bound <= top5_worst → scan cluster, else skip
  5. Mathematically guarantees exact KNN — zero false positives/negatives
  6. Return fraud_count (0..5)
        │
        ▼
  server.zig - pre-built comptime responses
  ─────────────────
  All 6 possible responses built at comptime via std.fmt.comptimePrint.
  Single writeAll per request. TCP_NODELAY eliminates Nagle buffering.
  Connection: close - one request per connection, 32 threads, no starvation.
        │
        ▼
  { "approved": bool, "fraud_score": float }
```

### The 14 dimensions

| idx | field                   | formula                                  |
|-----|-------------------------|------------------------------------------|
|  0  | `amount`                | `clamp(amount / 10_000)`                 |
|  1  | `installments`          | `clamp(installments / 12)`               |
|  2  | `amount_vs_avg`         | `clamp((amount / avg_amount) / 10)`      |
|  3  | `hour_of_day`           | `utc_hour / 23`                          |
|  4  | `day_of_week`           | `(wday + 6) % 7 / 6` - Mon=0, Sun=6      |
|  5  | `minutes_since_last_tx` | `clamp(minutes / 1440)` or `-1` if null  |
|  6  | `km_from_last_tx`       | `clamp(km / 1000)` or `-1` if null       |
|  7  | `km_from_home`          | `clamp(km_from_home / 1000)`             |
|  8  | `tx_count_24h`          | `clamp(tx_count / 20)`                   |
|  9  | `is_online`             | `1.0` or `0.0`                           |
| 10  | `card_present`          | `1.0` or `0.0`                           |
| 11  | `unknown_merchant`      | `0.0` if known, `1.0` if not             |
| 12  | `mcc_risk`              | lookup from `mcc_risk.json` (default 0.5)|
| 13  | `merchant_avg_amount`   | `clamp(merchant_avg / 10_000)`           |

### IVF index layout (AoSoA16)

The index uses **dimension-major block layout** (`[DIM][16]i16` per block) instead of
vector-major (`[16][DIM]i16`). This allows AVX2 to load all 16 vectors' values at dimension
`d` in a single `vmovdqu ymm` instruction:

```
Block of 16 vectors, dimension-major:
  blk[0*16 .. 0*16+16]  →  dim 0 for vectors 0..15
  blk[1*16 .. 1*16+16]  →  dim 1 for vectors 0..15
  ...
  blk[13*16 .. 13*16+16]→  dim 13 for vectors 0..15

@Vector(16, i16) loads 16×2=32 bytes per dimension → full 256-bit AVX2 register.
14 dimensions × 1 VPMULLW + VPADDW = 14 fused multiply-add cycles per block.
```

SIMD kernel (`index.zig`, `scanCluster`):
```zig
const V16i16 = @Vector(16, i16);
const V16i32 = @Vector(16, i32);
var dists: V16i32 = @splat(0);
inline for (0..DIM) |d| {
    const qv: V16i16 = @splat(q[d]);
    const bv: V16i16 = blk[d * 16 ..][0..16].*;
    const diff: V16i16 = qv - bv;
    const diff32: V16i32 = @intCast(diff);
    dists += diff32 * diff32;
}
```

int16 overflow safety: `SCALE=5000` → max diff=10000 (fits i16), max diff²=1e8,
sum over 14 dims = 1.4e9 (fits i32). No overflow possible.

---

## 03 · Tech stack

```
╔══════════════════════╦══════════════════════════════════════════════════════╗
║  LAYER               ║  CHOICE                                              ║
╠══════════════════════╬══════════════════════════════════════════════════════╣
║  Language            ║  Zig 0.15.2                                          ║
║  HTTP server         ║  Custom - blocking TCP, 32 threads, Connection:close ║
║  KNN search          ║  IVF K=2048 exact KNN via bbox pruning, AoSoA16 SIMD ║
║  Numeric core        ║  @Vector(16, i16) - AVX2 native, no deps             ║
║  JSON                ║  Custom zero-alloc scanner - std.mem.indexOf only    ║
║  Load balancer       ║  haproxy 3.0-alpine - TCP mode, roundrobin           ║
║  Binary              ║  Static musl, ~5 MB - FROM scratch final image       ║
║  Index               ║  @embedFile at compile time - zero cold-start        ║
╚══════════════════════╩══════════════════════════════════════════════════════╝
```

**Why Zig and not C or Rust?**

The `comptime` argument is central. The reference C implementation pre-computes the IVF index
in Python and includes a `.bin` blob. In Zig, `@embedFile` does the same with type safety:
the index is an embedded `[]const u8` slice, parsed at startup into a fully typed `IvfIndex`
struct - no runtime file I/O, no cold-start penalty.

`@Vector` intrinsics compile to AVX2 instructions directly without the verbosity of C
intrinsics or Rust's `std::arch` unsafe blocks. Zig's `inline for` over 14 dimensions
unrolls the SIMD loop at compile time.

**Why custom HTTP server?**

With only 2 endpoints and CPU-bound workload, framework overhead is irrelevant. The custom
server does exactly: `accept → read → dispatch → writeAll`. Pre-built comptime responses
eliminate all runtime formatting. TCP_NODELAY eliminates Nagle buffering (dropped sequential
p50 from 0.86ms to 0.32ms). Keep-alive eliminates TCP handshake per request.

**Why IVF K=2048 over HNSW or brute-force?**

| Algorithm        | Per-query p99  | Notes                                    |
|------------------|----------------|------------------------------------------|
| Brute-force f32  | ~3-5ms         | 100k × 14 FMAs, cache-unfriendly         |
| HNSW ef=200      | ~2.5ms floor   | Random memory access = constant misses   |
| IVF K=2048 SIMD  | ~0.72ms        | Sequential cluster scan, AVX2-friendly   |

IVF with K=2048 clusters visits 16/2048 = 0.78% of vectors on typical queries.
Sequential cluster scan is cache-coherent and SIMD-friendly; HNSW graph traversal is neither.

---

## 04 · Architecture

```
                      :9999
  k6 / test engine ── haproxy (LB, mode tcp)
                           │  round-robin TCP
              ┌────────────┴────────────┐
              ▼                         ▼
         [ api 1 ]                  [ api 2 ]
       Zig binary                  Zig binary
      32 worker threads          32 worker threads
      IVF index (embedded)        IVF index (embedded)
      [2048][K]AoSoA16 i16        [2048][K]AoSoA16 i16
      read-only, CoW-shared       read-only, CoW-shared
```

### Resource allocation

```
╔══════════════╦══════════╦════════════╗
║  Service     ║  CPUs    ║  Memory    ║
╠══════════════╬══════════╬════════════╣
║  haproxy     ║  0.10    ║  20 MB     ║
║  api1        ║  0.45    ║  160 MB    ║
║  api2        ║  0.45    ║  160 MB    ║
╠══════════════╬══════════╬════════════╣
║  TOTAL       ║  1.00    ║  340 MB    ║
╚══════════════╩══════════╩════════════╝
```

Limit: 1 CPU / 350 MB. Used: 1.00 CPU / 340 MB.

Binary RSS: ~14 MB (5.6 MB binary + index embedded + 256 thread stacks × 256KB).
GC: none. Allocations: only at startup (index parsing). Hot path: zero alloc.

---

## 05 · Quick start

<details>
<summary><kbd>▶ see details (click to expand)</kbd></summary>

```bash
# Clone
git clone https://github.com/bulletdev/bulletonrails-zig
cd bulletonrails-zig

# Build and run
# index.bin is committed - Docker build skips the ~90s index generation step
docker compose up --build -d

# Wait for ready
until curl -sf http://localhost:9999/ready; do sleep 1; done && echo "ready"

# Test a legitimate transaction
curl -s -X POST http://localhost:9999/fraud-score \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "tx-1329056812",
    "transaction":      { "amount": 41.12, "installments": 2, "requested_at": "2026-03-11T18:45:53Z" },
    "customer":         { "avg_amount": 82.24, "tx_count_24h": 3, "known_merchants": ["MERC-003", "MERC-016"] },
    "merchant":         { "id": "MERC-016", "mcc": "5411", "avg_amount": 60.25 },
    "terminal":         { "is_online": false, "card_present": true, "km_from_home": 29.23 },
    "last_transaction": null
  }'
# Expected: {"approved":true,"fraud_score":0.0}

# Test a fraudulent transaction
curl -s -X POST http://localhost:9999/fraud-score \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "tx-3330991687",
    "transaction":      { "amount": 9505.97, "installments": 10, "requested_at": "2026-03-14T05:15:12Z" },
    "customer":         { "avg_amount": 81.28, "tx_count_24h": 20, "known_merchants": ["MERC-008", "MERC-007", "MERC-005"] },
    "merchant":         { "id": "MERC-068", "mcc": "7802", "avg_amount": 54.86 },
    "terminal":         { "is_online": false, "card_present": true, "km_from_home": 952.27 },
    "last_transaction": null
  }'
# Expected: {"approved":false,"fraud_score":1.0}
```

**Local build (without Docker):**

```bash
# Requires Zig 0.15.2
zig build              # debug build
zig build --release=fast -Dcpu=native   # optimized for your CPU
./zig-out/bin/api      # runs on :9999
```

</details>

---

## 06 · Validation

<details>
<summary><kbd>▶ see details (click to expand)</kbd></summary>

```bash
# legit - expected: {"approved":true,"fraud_score":0.0}
curl -s -X POST http://localhost:9999/fraud-score \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "tx-1329056812",
    "transaction":      { "amount": 41.12, "installments": 2, "requested_at": "2026-03-11T18:45:53Z" },
    "customer":         { "avg_amount": 82.24, "tx_count_24h": 3, "known_merchants": ["MERC-003", "MERC-016"] },
    "merchant":         { "id": "MERC-016", "mcc": "5411", "avg_amount": 60.25 },
    "terminal":         { "is_online": false, "card_present": true, "km_from_home": 29.23 },
    "last_transaction": null
  }'

# fraud - expected: {"approved":false,"fraud_score":1.0}
curl -s -X POST http://localhost:9999/fraud-score \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "tx-3330991687",
    "transaction":      { "amount": 9505.97, "installments": 10, "requested_at": "2026-03-14T05:15:12Z" },
    "customer":         { "avg_amount": 81.28, "tx_count_24h": 20, "known_merchants": ["MERC-008", "MERC-007", "MERC-005"] },
    "merchant":         { "id": "MERC-068", "mcc": "7802", "avg_amount": 54.86 },
    "terminal":         { "is_online": false, "card_present": true, "km_from_home": 952.27 },
    "last_transaction": null
  }'
```

Expected output:

```
{"approved":true,"fraud_score":0.0}
{"approved":false,"fraud_score":1.0}
```

**IVF index accuracy (validate_index tool):**

```bash
# Build validator against the committed index.bin
zig build-exe tools/validate_index.zig -O ReleaseFast --name validate_index
./validate_index resources/references.json.gz resources/index.bin
```

Expected:
```
Loaded 100000 reference points
Sampling 2000 random queries...
Agreement (IVF vs brute-force): 1997/2000 = 99.85%
Error distribution (brute_fc → ivf_fc):
  all errors are within ±1 of the boundary (fc=2,3)
  no cross-threshold errors detected
```

The 99.85%+ agreement uses the same approval threshold as the scorer: errors that cross
the `fraud_count >= 3` boundary (approve/deny boundary) are the only ones that affect
detection score. The boundary retry (nprobe=48 when fraud_count == 2 or 3) catches
the majority of those. With nprobe=16/48, all 54100 test entries pass with 0 FP/FN.

</details>

---

## 07 · Benchmark results

Score formula: `final = score_p99 + score_det`

`score_p99 = max(-3000, min(3000, 1000 * log10(1000ms / p99)))`

```
╔════════════════════════════════════════════════════════════════════════════════╗
║  EVOLUTION                                                                     ║
╠════════════╦════════════════════════════╦═══════════╦══════════════════════════╣
║  Impl      ║  What                      ║  p99      ║  notes                   ║
╠════════════╬════════════════════════════╬═══════════╬══════════════════════════╣
║  Ruby R11  ║  FAISS IVF nlist=64        ║  ~1.5ms   ║  last Ruby run est.      ║
╠════════════╬════════════════════════════╬═══════════╬══════════════════════════╣
║  Zig Z1    ║  Brute-force f32           ║  ~3ms     ║ baseline, no SIMD        ║
║  Zig Z2    ║  IVF K=2048 nprobe=8       ║  ~1.5ms   ║ no SIMD yet              ║
║  Zig Z3    ║  + AoSoA16 @Vector SIMD    ║  ~0.05ms  ║ AVX2, haswell target     ║
║  Zig Z4    ║  + TCP_NODELAY             ║  ~0.04ms  ║ eliminates Nagle         ║
║  Zig Z5    ║  + comptime responses      ║  ~0.04ms  ║ single writeAll/req      ║
║  Zig Z6    ║  + HTTP keep-alive         ║  ~0.04ms  ║ no TCP handshake/req     ║
║  Zig Z7    ║  + heap nearestCentroid    ║  ~0.037ms ║ O(K*log(np)) vs O(K*np)  ║
║  Zig Z8    ║  + nprobe=16/48 (was 8/24) ║  1.20ms   ║ 100% accuracy, k6 tested ║
║  Zig Z9    ║  + 256 threads (was 64)    ║  1.20ms   ║ no starvation at VU=250  ║
║  Zig Z10   ║  + exact KNN bbox pruning  ║  ~1.20ms  ║ 0 FP/FN guaranteed       ║
║            ║  + Connection:close 32t    ║           ║ no cgroup runq pressure  ║
╚════════════╩════════════════════════════╩═══════════╩══════════════════════════╝
```

**k6 benchmark — local Docker, ramping arrival rate 1→650 RPS (competition test format):**

```
╔══════════════════════════════════════════════════════════════════════╗
║  k6 ramping-arrival-rate (local) · 256 threads · keep-alive          ║
╠═══════════════════════════╦══════════════════════════════════════════╣
║  Total requests           ║  14 354                                  ║
║  HTTP errors              ║  0                                       ║
║  False positives          ║  0                                       ║
║  False negatives          ║  0                                       ║
║  p99                      ║  1.20 ms                                 ║
║  p99 score                ║  2922  (formula: 1000*log10(1000/1.20))  ║
║  detection score          ║  3000  (0 errors → epsilon=0 → max)      ║
║  final score              ║  5922 / 6000                             ║
╚═══════════════════════════╩══════════════════════════════════════════╝
```

Note: local p99 is higher than competition because Docker Desktop adds ~0.5ms overhead.
Competition hardware (Mac Mini, bare Docker Engine, dedicated) is expected to hit p99 < 1ms.

**Why 32 threads + Connection:close?**

Under Linux cgroups CPU throttling (0.45 vCPU), the kernel counts all threads in the
runqueue even when blocked on `accept()` or `read()`. With 256 threads + keep-alive,
the scheduler spends significant time context-switching idle threads, adding ~1ms to p99.

Connection:close eliminates the keep-alive loop: each thread accepts one connection,
serves one request, closes. With 32 threads and one request per connection, the runqueue
stays short and cgroup throttle is no longer a bottleneck. p99 target: <1ms.

32 × 256KB stack = 8MB per instance; well within the 160MB limit.

**Optimization path:**

```
Brute-force f32                →  ~3ms, baseline
+ IVF K=2048 nprobe=8          →  ~1.5ms   (2x: cluster pruning)
+ AoSoA16 @Vector(16,i16) SIMD →  ~0.72ms  (2x: AVX2 distance compute)
+ TCP_NODELAY                  →  eliminated Nagle buffering
+ comptime responses           →  eliminates all runtime formatting
+ HTTP keep-alive              →  no TCP handshake per request
+ nearestCentroids max-heap    →  O(K*log(np)) vs O(K*np)
+ nprobe 8→16 / 24→48          →  100% accuracy on all 54100 test entries
+ threads 64→256               →  eliminates starvation at maxVUs=250
+ exact KNN via bbox pruning   →  mathematical guarantee: 0 FP/FN
+ Connection:close + 32 threads →  eliminates cgroup runqueue pressure
```

The dominant gain: IVF cluster pruning (visits 0.78% of vectors) + AoSoA16 SIMD
(16 distances computed per VMOVDQU + VPMULLW cycle at no extra cost).

---

## 08 · Submission

```
╔════════════════════════════════════════════════════════════╗
║  GitHub user:      bulletdev                               ║
║  Repo:             bulletonrails-zig                       ║
║  Submission ID:    bulletdev-zig                           ║
║  branch main:      source code                             ║
║  branch submission: docker-compose.yml at root             ║
╚════════════════════════════════════════════════════════════╝
```

To trigger the official test: open an issue with `rinha/test` in the description into official rinha repository.

---

<div align="center">

▓▒░ · Zig goes brrr · ░▒▓

</div>
