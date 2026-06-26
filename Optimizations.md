# Optimizations

This documents the rewrite of the `BillionRowChallenge` target from a port of the
naive structure into a fast Swift implementation. The original version is preserved
on the `main` branch, and the `ChatGPT` target is kept as a slow baseline for
comparison.

## Results

Measured on an Apple-silicon machine, 10 cores.

| Dataset           | Original    | Optimized                  | Speedup |
| ----------------- | ----------- | -------------------------- | ------- |
| 10M rows          | 7,700 ms    | ~28 ms warm (120 ms cold)  | ~270×   |
| 100M rows (cached)| —           | ~256 ms (~370M rows/sec)   | —       |
| 1B rows           | ~13 min*    | ~13 s                      | ~60×    |

\* Extrapolated from the original's per-row cost.

Output is **byte-for-byte identical** to the original at every scale (verified at
3 lines, 10M, 100M, and 1B rows against the known-good baseline output).

### Caveat on the 1B number

The 1B file is ~13 GB. On a 32 GB machine with only ~6 GB free, it does not fit in
the page cache, so every run re-reads it from disk. `time` confirms this: high `sys`
time (~8.5 s) and only ~2× core utilization mean the 1B run is **I/O / page-fault
bound, not compute bound**. The CPU-only throughput is the cached 100M figure
(~370M rows/sec), which extrapolates to ~2.5–3 s of compute for 1B when the file is
resident in the page cache (as the official challenge assumes).

## Baseline: why the original was slow

Two prior versions, both ~8 s for 10M rows:

- **`BillionRowChallenge` (original)** — single-threaded read; one `actor Tally`
  per city, so every row paid an actor hop.
- **`ChatGPT`** — mmap + one segment per core, but all segments funneled every row
  through a single shared `actor Results`. It used all 10 cores yet ran *slower*
  than the single-threaded version (178% CPU) because the shared actor serialized
  the hot loop and added an `await` suspension per row.

The mmap + segment-per-core skeleton was sound; the per-row work was the problem.

## Changes

### 1. No shared mutable state (removed the actor bottleneck)

Each segment accumulates into its **own** open-addressing hash table with no locks,
no actors, and no `await` in the loop. The per-segment tables are merged exactly
once at the end. The merge runs only ~(unique stations × segments) times, so its
cost is negligible. This restores near-linear scaling across cores.

### 2. No allocations in the hot loop

The original allocated a Swift `String` per row (the `LineProcessor` variant even
did `.map { UInt8(...) }`, allocating an intermediate array per line), then `split`
on `;`, then `Double(_:)`.

The optimized hot loop allocates nothing:

- Station names are hashed (FNV-1a) and compared as raw `UInt8` bytes via pointers
  into the mmap'd file.
- The hash table is keyed on those bytes (`memcmp` on collision).
- A `String` is materialized only for the ~413 final results, at output time.

### 3. Integer temperature parsing

The temperature format is fixed: `-?\d{1,2}\.\d`. It is parsed into a scaled `Int`
(tenths of a degree) with a handful of byte comparisons — no `Double`, no `String`,
no `split`. Min / max / sum / count are kept as integers and only converted to
decimal at output. `mean` is computed as `round(sum / count) / 10` to match the
original's rounding exactly.

### 4. Synchronous byte scan + threads

- `DispatchQueue.concurrentPerform(iterations: cores)` — one task per core. The
  `AsyncSequence` / `async` line iterator is removed entirely; nothing here is
  actually asynchronous, it is a CPU-bound scan over memory.
- Tight synchronous `while` loops over an `UnsafePointer<UInt8>`.
- Segment boundaries are aligned to the next newline so no row is split across two
  segments.
- `madvise(MADV_SEQUENTIAL)` hints the kernel to prefetch the mapping.

## Implementation notes

- **Hash table** — open addressing with linear probing, power-of-two capacity
  (`1 << 14`), `count == 0` marks an empty slot. Parallel `UnsafeMutablePointer`
  arrays (hashes, name pointers, name lengths, min, max, sum, count) avoid Swift
  `Array` bounds-check overhead in the hot path.
- **Hashing** — FNV-1a (64-bit) computed incrementally while scanning the name up
  to `;`. Note: index into the table must be `Int(hash & UInt64(mask))`, **not**
  `Int(hash) & mask` — the latter traps ("Not enough bits to represent the passed
  value") whenever the 64-bit hash has its high bit set.
- **Correctness of names with commas** — names are everything up to `;`, so entries
  that contain commas (e.g. `Flores,  Petén`) are handled correctly; output is
  sorted by station name.

## Further work (to chase the Java leaders)

1. Custom hash table tuned further (sizing, probe strategy).
2. SWAR / `memchr` for newline and `;` scanning instead of per-byte loops.
3. SIMD temperature parsing.
4. On memory-constrained machines, the 1B case is I/O bound — overlapping reads and
   ensuring the file is page-cache resident matter more than further compute tuning.

## How to build, run, and verify

```bash
# Build (Release)
xcodebuild -scheme CreateMeasurements -configuration Release -derivedDataPath ./build/dd build
xcodebuild -scheme BillionRowChallenge -configuration Release -derivedDataPath ./build/dd build
BIN=./build/dd/Build/Products/Release

# Generate a dataset (writes ./measurements.txt; processors default to ./10_000_000.txt)
$BIN/CreateMeasurements 10000000
cp measurements.txt 10_000_000.txt

# Run (takes an optional path argument; writes ./brc-output.txt)
$BIN/BillionRowChallenge ./10_000_000.txt

# Larger scales by concatenation (valid format is preserved)
for i in $(seq 1 10);  do cat 10_000_000.txt; done > 100M.txt   # 100M rows
for i in $(seq 1 100); do cat 10_000_000.txt; done > 1B.txt     # 1B rows (~13 GB)

# Verify correctness against the ChatGPT baseline target
( cd <dir-with-10_000_000.txt> && $BIN/ChatGPT )                # writes ./chatgpt-output.txt
diff <(sort brc-output.txt) <(sort chatgpt-output.txt) && echo "MATCH"
```

For quick iteration during development, compile the single file directly:

```bash
swiftc -O -whole-module-optimization BillionRowChallenge/main.swift -o /tmp/fast
/tmp/fast ./10_000_000.txt
```
