# Performance Walkthrough: Why the Rewrite Is ~270× Faster

This walkthrough covers commit `81ad405` ("Optimize BillionRowChallenge processor"),
which rewrote `BillionRowChallenge/main.swift`. It explains what the old code
cost on every row, what the new code does differently, and how to reuse the
approach in other projects.

Related notes:
- [Optimizations.md](../Optimizations.md): benchmark numbers and implementation notes
- [ActorHops.md](../ActorHops.md): what an actor hop is at the runtime level
- [XcodeHotLoops.md](../XcodeHotLoops.md): getting Xcode to flag hot-loop problems

---

## The one idea behind everything

The challenge is a single loop that runs a billion times. At that scale, the
work done **once per row** is the only cost that matters. Anything per row gets
multiplied by 10⁹:

| Per-row cost | Total for 1B rows |
| ------------ | ----------------- |
| 1 µs         | ~17 minutes       |
| 100 ns       | ~100 seconds      |
| 10 ns        | ~10 seconds       |
| 1 ns         | ~1 second         |

Here is the math for this project, using the 10M-row figures:

- **Old:** 7,700 ms ÷ 10M rows ≈ **770 ns per row**, on one core.
- **New:** 28 ms ÷ 10M rows ≈ **2.8 ns per row** of wall-clock time. That is
  spread over 10 cores, so each row costs about **28 ns of CPU time**.

So the rewrite made each row about **27× cheaper** and then ran rows on **10
cores at once**. Together that gives about 270×. Every change below falls into
one of those two buckets.

---

## Part 1: How the old code hurt performance

Here is the old hot path, with comments marking what each row paid for:

```swift
while let line = nextLine() {                          // (1) (2) (3)
    let parts = line.components(separatedBy: ";")      // (4)
    let id = parts[0]
    if let temperature = Double(parts[1]) {            // (5)
        await add(id: id, temperature: temperature)    // (6) (7)
    }
}

func nextLine() -> String? {
    if let range = buffer.range(of: delimiter) {
        let lineData = buffer.subdata(in: 0..<range.lowerBound)   // (1)
        buffer.removeSubrange(0..<range.upperBound)               // (2)
        return String(data: lineData, encoding: .utf8)            // (3)
    }
    ...
}

func add(id: String, temperature: Double) async {
    if let tally = tallies[id] {                       // (7)
        await tally.add(temperature: temperature)      // (6)
    } ...
}
```

### (1) A new `Data` allocation for every line
`subdata(in:)` copies the line's bytes into a brand-new heap buffer. Heap
allocation is one of the most expensive things you can do in a hot loop: it
takes a lock or an atomic in the allocator, it pollutes the cache, and the
buffer has to be freed later.

### (2) Shifting the whole buffer for every line
`removeSubrange(0..<n)` deletes bytes from the **front** of the buffer. To do
that, `Data` moves every remaining byte forward (a `memmove`). With a 4 KB
buffer and ~14-byte lines, each row moves up to about 4 KB just to drop 14
bytes. The work per row grows with the buffer size rather than the line length.

### (3) Building a `String`, with UTF-8 validation
`String(data:encoding:)` allocates again, and it also checks that every byte is
valid UTF-8. That is real work per byte, and it buys nothing here.

### (4) `components(separatedBy:)` is a Foundation call
It goes through Foundation's string machinery and returns an **array** (another
allocation) holding **two new `String`s** (two more allocations). By now a
single row has made about 5 heap allocations.

### (5) `Double(String)` is a general-purpose float parser
It handles exponents, `inf`, `nan`, hex floats, locale-independent rounding,
and so on. The input is always `-?\d{1,2}\.\d`, so nearly all of that
generality is wasted.

### (6) An actor hop on every row (the largest single cost)
`Tally` was an `actor`, and every row ran `await tally.add(...)`. As
[ActorHops.md](../ActorHops.md) explains, that `await` is not a function call.
It does the following:

1. Saves the caller's state into an async frame.
2. Enqueues a job on the actor's serial executor, which takes atomic operations.
3. Possibly suspends the current task and switches to the actor's executor.
4. Runs four lines of arithmetic.
5. Hops back to the caller and resumes.

So the useful work, a `min`, a `max`, and two additions, costs a few
nanoseconds, and scheduling it costs far more. The actor protected against a
data race that **could not happen**, because there was only one thread. All of
that synchronization was pure overhead.

### (7) Hashing a Swift `String` on every row
`tallies[id]` hashes the whole `String` with SipHash, which is designed to
resist attacks and is not tuned for speed. On a match, it compares with
Unicode-correct `String` equality. Both are correct and both are slow compared
to hashing raw bytes.

### Plus: one core, and `Double` math
The loop ran on a single thread, so 9 of the 10 cores sat idle. The min, max,
and sum used `Double`, which is fine but slower than integer math and not
needed.

### What about the `ChatGPT` target?
The `ChatGPT` target is a useful counterexample. It **did** split the file
across all cores, and it was still about as slow, because every core sent every
row through **one shared `actor Results`**. The actor processes one message at
a time, so 10 cores ended up queued behind one serial executor. That is why it
showed ~178% CPU instead of ~1000%. **Running work in parallel does not help if
every item passes through one shared lock or actor.**

---

## Part 2: How the new code improved performance

### Step 1: Map the file into memory and treat it as bytes

```swift
let raw = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0)
madvise(raw, fileSize, MADV_SEQUENTIAL)
let base = raw.assumingMemoryBound(to: UInt8.self)
```

`mmap` makes the whole file look like one large array in memory. Nothing is
copied into a buffer, nothing is shifted, and nothing is allocated per line.
The kernel loads pages as you touch them, and `MADV_SEQUENTIAL` tells it to
read ahead. This one change removes costs (1), (2), and (3).

### Step 2: Split the file into one segment per core, aligned to newlines

```swift
var pos = fileSize / segments * i
while pos < fileSize && base[pos] != newline { pos += 1 }
```

Each segment boundary is pushed forward to the next `\n`, so no row is ever
split between two threads. Each thread gets a clean range of complete lines.

### Step 3: Give each thread its own table, then merge once

```swift
let tables = (0..<segments).map { _ in StatsTable(capacity: 1 << 14) }

DispatchQueue.concurrentPerform(iterations: segments) { i in
    processSegment(base, bounds[i], bounds[i + 1], into: tables[i])
}
// ...then merge `tables` into one dictionary
```

This is the change that matters most. **No thread ever touches another
thread's data**, so the loop needs no actor, lock, atomic, or `await`. Each
thread runs at full speed on its own core.

The merge happens once at the end. It touches only (unique stations × cores),
roughly 413 × 10 ≈ 4,000 entries, which is trivial next to 10⁹ rows. This
pattern is called **shard then merge** (or map/reduce). It removes cost (6) and
the `ChatGPT` bottleneck.

`concurrentPerform` is used instead of `async`/`await` because this work is
**CPU-bound**. Nothing ever waits on I/O, so there is nothing for async to gain
by suspending, and suspending would only add overhead.

### Step 4: Hash and compare station names as raw bytes

```swift
var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a
var c = base[p]
while c != semicolon {
    hash = (hash ^ UInt64(c)) &* 0x100000001b3
    p += 1
    c = base[p]
}
```

The loop finds the `;` and computes the hash **in the same pass**, so each byte
is read only once. The station name is never turned into a `String`. The table
stores a **pointer into the mapped file** plus a length, and checks for a match
with `memcmp`. That removes costs (4) and (7).

A `String` is created only during the merge, about 4,000 times in total instead
of 10⁹ times.

### Step 5: Parse the temperature as an integer number of tenths

```swift
var negative = false
if base[p] == minus { negative = true; p += 1 }
var value = Int32(base[p] - zero); p += 1
if base[p] != dot { value = value * 10 + Int32(base[p] - zero); p += 1 }
p += 1 // skip '.'
value = value * 10 + Int32(base[p] - zero); p += 1
```

The input format is fixed, so parsing it takes a handful of byte comparisons.
`-12.3` becomes the integer `-123`. Min, max, sum, and count all stay as
integers, and the code divides by 10 only when it writes the output. That
removes cost (5) and the `Double` math.

### Step 6: A purpose-built hash table

`StatsTable` is an open-addressing hash table with linear probing:

- **Power-of-two capacity**, so `hash & mask` picks the slot instead of the
  slower `%` operator.
- **Parallel arrays** (`mins[]`, `maxs[]`, `sums[]`, `counts[]`, …) stored as
  `UnsafeMutablePointer`. That skips Swift's array bounds checks and
  copy-on-write checks.
- `counts[i] == 0` marks an empty slot, so no `Optional` wrapper is needed.
- It is sized once at 16,384 slots and never resizes or allocates inside the
  loop.

### Before and after, per row

| Work per row            | Old                                  | New                     |
| ----------------------- | ------------------------------------ | ----------------------- |
| Heap allocations        | ~5 (`Data`, `String`, array, 2 × `String`) | **0**                   |
| Buffer `memmove`        | up to ~4 KB                          | **none**                |
| UTF-8 validation        | yes                                  | **no**                  |
| Temperature parse       | `Double(String)`                     | ~6 byte comparisons     |
| Key hashing             | SipHash over a `String`              | FNV-1a, same pass as the scan |
| Synchronization         | actor hop (`await`)                  | **none**                |
| Cores used              | 1                                    | all                     |

---

## Part 3: Takeaways for your own code

You won't write mmap and hash-table code every day, and you shouldn't. The
reasoning behind it applies almost everywhere, though.

### 1. Find the per-item cost, then multiply
Before optimizing, divide total time by item count, as in the
770 ns → 2.8 ns math above. It shows whether a change will matter. In a loop
over N items, a 50 ns saving is irrelevant at N = 1,000 and decisive at
N = 10⁹. Profile with Instruments (Time Profiler and Allocations) to see where
those nanoseconds go.

### 2. Do no allocations in the hot loop
In Swift, watch for hidden allocations: `String` creation, `split`,
`components`, `map`/`filter` that build arrays, `Data` slicing, closures that
capture context, and existential (`any P`) boxes. Allocate up front, reuse
buffers, and turn data into "nice" types only at the edges.

### 3. Work in the cheapest form of the data, and convert at the edges
Keep data as bytes, integers, or indices while you process it, and turn it into
`String`, `Double`, or model objects only for the final output. Here,
temperatures became integers for the whole pipeline and were divided by 10 only
at the end. Names stayed as byte ranges and became `String`s only about 4,000
times.

### 4. Use what you know about the input
General-purpose parsers pay for cases you don't have. If your format is fixed
(log lines, CSV with a known schema, binary protocols), a hand-written parser
for **that** format can be 10–100× faster. Keep a validating slow path, or
check up front, if the input might be untrusted.

### 5. Shard, don't share
This is the biggest lesson from both the old code and the `ChatGPT` target. A
shared actor, lock, or dictionary in a hot loop serializes the work, no matter
how many cores you have. Instead:

```swift
// Give each worker its own private accumulator...
var partials = [Accumulator](repeating: .init(), count: workers)
partials.withUnsafeMutableBufferPointer { buf in
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        for item in chunk(w) { buf[w].add(item) }   // no synchronization
    }
}
// ...then combine once.
let total = partials.reduce(into: Accumulator()) { $0.merge($1) }
```

This works whenever the combine step is associative: sums, counts, min/max,
histograms, set unions, or per-key aggregation.

### 6. Pick the concurrency tool for the kind of work
- **`async`/`await` and actors** fit I/O-bound work and coarse-grained
  coordination: network calls, file reads that wait, UI state. Hops are cheap
  compared to a network round trip.
- **Threads (`concurrentPerform`) or a few large tasks** fit CPU-bound loops.
  Make each unit of work large, such as one segment per core, not one row per
  task.
- Rule of thumb: **never `await` inside a loop that runs millions of times.**
  Move the `await` outside the loop and batch the work inside it.

### 7. Choose data layout for the access pattern
Parallel arrays (struct-of-arrays), power-of-two table sizes, and fixed
capacity all keep memory access predictable and cache-friendly. You rarely need
this level of detail, but when a profiler points at a dictionary lookup, a
specialized table is a legitimate fix.

### 8. Keep the unsafe code small and contained
The fast code relies on `UnsafePointer`, `mmap`, and `memcmp`, and on
assumptions that are **not checked**:

- The input must be well-formed. A missing `;` makes the name scan read past
  the end of the segment.
- The table has a fixed 16,384 slots. If there were more unique names than
  that, the probe loop would never end.
- The table holds pointers into the mapped file, so the file must stay mapped
  until the merge is done. The `defer { munmap(...) }` handles that.

These assumptions are fine for a benchmark with a defined input format. In
production code:

- Put the unsafe core behind a small, safe API.
- Validate input at the boundary.
- Assert the invariants.
- Keep a straightforward reference implementation and **diff the outputs**, as
  this project does against `ChatGPT`.

In Swift 6.2 and later, `Span` / `RawSpan` and `withUnsafeBufferPointer` give
much of the same speed with bounds safety. Try them before reaching for raw
`allocate`.

### 9. Optimize in order
1. **Algorithm and structure.** Remove shared state, remove per-item async, and
   parallelize. This is where most of the 270× came from.
2. **Allocations and conversions.** Bytes instead of strings, integers instead
   of floats.
3. **Micro-tuning.** SWAR or SIMD scanning, custom hashing. Do this only after
   1 and 2, and only with measurements.

Measure after every step. Correctness first: the rewrite was accepted only
because its output was byte-for-byte identical at every scale.
