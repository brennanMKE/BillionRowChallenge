# Actor Hops

Notes on what a Swift `actor` "hop" actually is, why it was the dominant cost in
the original Billion Row Challenge processors, and the techniques that eliminate
it. This is the conceptual companion to [Optimizations.md](Optimizations.md),
which covers the concrete rewrite.

## What a hop actually is

An `actor` is a reference type with a **serial executor**. The executor enforces
that only one task touches the actor's mutable state at a time. The enforcement
mechanism is: to run actor-isolated code you must be running *on that actor's
executor*. If you aren't, you must switch to it. That switch is the **hop**.

When you write `await someActor.method()` from outside the actor, the compiler
does not emit a plain function call. It emits roughly:

1. **Package the continuation** — the rest of the calling function, plus its
   locals, is saved into a heap-allocated async frame.
2. **Enqueue** — an atomic enqueue of that job onto the actor's executor queue.
3. **Suspend** — the current task suspends and returns its thread to the
   cooperative thread pool.
4. **Resume** — the pool later picks the job up (possibly on a *different*
   physical thread), runs the isolated code, then hops back to resume the caller.

So a one-line `min = Swift.min(min, t)` becomes: an allocation, an atomic enqueue,
a suspend, a schedule, and a resume. Even on the uncontended fast path (where the
runtime can sometimes elide the thread switch) you still pay the suspension-point
machinery and async-frame bookkeeping.

## The two distinct costs

Hopping imposes two independent taxes. The original code paid both.

### 1. Hop overhead (per call, even with zero contention)

The enqueue / suspend / resume cycle costs on the order of tens of nanoseconds at
minimum. The actual protected work — updating four numbers — is a few nanoseconds.
So the concurrency mechanism costs **10–100× more than the thing it protects**.
At a billion rows that is a billion of these cycles, all pure overhead.

### 2. Serialization / contention (shared-actor case)

If many tasks share one actor, the actor's whole purpose — mutual exclusion —
forces their calls through a single serial queue. Anything parallel upstream
collapses to serial at the actor. This is Amdahl's law at its worst: the part you
parallelized is exactly the part that is now serial. On top of that you add
cache-coherence traffic as the actor's state and queue bounce between cores.

### 3. Cache locality (a hidden third cost)

Because a hop can resume your continuation on a *different* thread, the data you
just touched is now cold in the wrong core's cache. Per-row hopping means you
never build up locality; the hash table, row bytes, and stats slot keep migrating
cores.

## How this showed up in this project

Two baseline processors, both ~8 s for 10M rows:

- **`BillionRowChallenge` (original)** — single-threaded read, but one
  `actor Tally` per city, so every row did an `await` hop into an actor and back.
  Pure hop overhead with **zero** parallelism upside.
- **`ChatGPT`** — one segment per core, but every row from every core funnelled
  through a single shared `actor Results`. Measured at **178% CPU and slower than
  the single-threaded version**: ten cores mostly idle, waiting on one actor, the
  work buried under hop overhead. This is the textbook symptom of cost #1 + #2.

## The core reframe

The original design synchronized **once per row** — a billion times. The fix
synchronizes **once total**, at the end.

| Design                                   | Synchronization points |
| ---------------------------------------- | ---------------------- |
| Shared / per-city actor (original)       | O(rows)                |
| Per-thread tables, merge once (rewrite)  | O(threads × stations)  |

Same correctness guarantee — no two threads ever write the same memory at the same
time — but the coordination cost drops from O(rows) to a one-time merge.

## Recommended optimizations to eliminate hop cost

In priority order. The first one is the whole game; the rest reduce the per-row
work that hops were hiding.

### 1. Partition the input; give each thread private state (map-reduce)

Eliminate sharing instead of synchronizing it. Each thread owns a private
accumulator and writes only to memory it alone touches, so there is nothing to
guard — no actor, no lock, no `await`, no suspension point.

```swift
// MAP: one private table per segment, no shared state, no await in the loop.
let tables = (0..<segments).map { _ in StatsTable(capacity: 1 << 14) }
DispatchQueue.concurrentPerform(iterations: segments) { i in
    processSegment(base, bounds[i], bounds[i + 1], into: tables[i])
}

// REDUCE: synchronize exactly once, merging ~(stations × segments) entries.
var merged: [String: Stat] = [:]
for table in tables { /* fold each table's slots into `merged` */ }
```

### 2. Make the hot path synchronous and inlinable

Drop `async` / `AsyncSequence` from the inner loop — nothing here is actually
asynchronous, it is a CPU-bound scan over memory. A plain synchronous,
`@inline(__always)` update lets the compiler inline the accumulation directly into
the scan loop, with no async frame and no continuation.

```swift
@inline(__always)
func add(hash: UInt64, name: UnsafePointer<UInt8>, len: Int32, value: Int32) { ... }
```

### 3. Use a coarse fan-out, not per-element tasks

Spawn work at the granularity of *segments* (one unit per core), not per row.
`DispatchQueue.concurrentPerform` (or a `TaskGroup` with one child per segment)
amortizes all scheduling cost across millions of rows instead of paying it each
row.

### 4. Keep the per-thread working set hot

Because each segment is processed start-to-finish on one core with private arrays,
its hash table and the bytes it scans stay resident in that core's L1/L2 for the
whole pass. This is a direct consequence of #1 — no hops means no continuation
migrating to another thread mid-scan.

## If you genuinely must share state

Sometimes the work cannot be cleanly partitioned. The options, fastest to slowest
for a hot path, and where each lands:

| Approach                                   | Per-row cost | Notes                                             |
| ------------------------------------------ | ------------ | ------------------------------------------------- |
| Per-thread state, merge once               | ~0 sync      | Right tool for parallel reduction (what we used)  |
| Striped/sharded state (N shards by hash)   | low          | Use when you can't partition the *input* cleanly  |
| `os_unfair_lock` / `NSLock` around state   | medium       | Cheaper than a hop, but still contended per row   |
| Atomics on min/max/sum                     | medium       | No lock, but cache-line ping-pong; CAS for min/max|
| Shared `actor`                             | high         | Hop + serialization — the original, worst here    |

Key point: locks and atomics are *cheaper than hops*, but they still coordinate
**per row**, so they do not fix the fundamental problem. The win was not "replace
the actor with a lock" — it was "stop coordinating per row at all."

## When an actor is the right tool

Actors are not slow in the abstract. They fit when the protected work is
**coarse-grained** (each call does enough work to amortize the hop) and
**genuinely shared** (it cannot be partitioned away) — e.g. a request handler
mutating shared session state. They are the wrong tool for a billion fine-grained
updates to a structure you could have partitioned.

Rule of thumb: **the cost of a concurrency primitive should be small relative to
the work it guards.** A hop guarding a four-integer update violates that by ~100×.
Either make the guarded unit bigger (batch), or — better — make the state private
so there is nothing to guard.
