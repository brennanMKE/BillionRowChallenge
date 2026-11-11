# Surfacing Hot-Loop Optimizations in Xcode

How to make Xcode highlight potential performance problems — especially the
per-row actor hops described in [ActorHops.md](ActorHops.md) — as inline warnings
and errors. This is the tooling companion to [Optimizations.md](Optimizations.md).

## The baseline: a Build Phase Run Script

Anything a build step prints in this format shows up inline in Xcode:

```
/path/to/File.swift:LINE:COL: warning: message
/path/to/File.swift:LINE:COL: error: message
/path/to/File.swift:LINE:COL: note: message
```

So a *Build Phase → Run Script* that greps the source and emits those lines is the
simplest way to flag patterns. Every better tool below uses this same hook.

**Why it is the weak version:** it is plain text matching with no understanding of
structure. It cannot distinguish `await` in a hot loop from `await` in setup code,
it cannot see types, it produces no fix-its, it reruns every build (slowing
compiles unless you wire up input/output file lists), and it is brittle to
formatting. Use it only as a last-resort shim.

The options below are ordered worst-to-best for this goal.

## A. SwiftLint custom rules (as a build tool plugin)

The pragmatic upgrade. Add SwiftLint as an **SPM Build Tool Plugin** (Xcode 14+
supports this on `.xcodeproj` targets via *Build Phases → Run Build Tool
Plug-ins*). Rules live in `.swiftlint.yml`:

```yaml
custom_rules:
  await_in_loop:
    name: "await in loop"
    regex: '(for|while)[^{]*\{[^}]*await'
    message: "await inside a loop — possible per-iteration actor hop"
    severity: warning
```

- **Pros:** zero infrastructure, hundreds of built-in rules, real inline
  diagnostics, autocorrect for many rules.
- **Cons:** custom rules are still **regex**, so they false-positive/negative on
  anything structural (nested braces, multiline). Good for cheap house-style
  checks, not for "is this `await` actually in a tight loop over a billion rows."

## B. A SwiftSyntax build tool plugin (the better way)

For real anti-pattern detection, write a small linter on top of
**SwiftSyntax / SwiftParser** and ship it as an SPM Build Tool Plugin. You walk the
actual AST, so you can detect what grep fundamentally cannot:

- an `AwaitExpr` whose syntactic ancestor is a `ForStmt` / `WhileStmt`
- a call to a member of a declared `actor` inside a loop body
- `String(...)` / `.split` / `Double(_:)` allocations inside a hot loop
- a `func` that is `async` but contains no real suspension (candidate to desugar)

Emit the same `path:line:col: warning:` format — SwiftSyntax gives exact source
locations and lets you attach **fix-its**. Because it is a build tool plugin it
runs on every build and joins the dependency graph. Strictly better than the run
script: structural accuracy, precise locations, suggested fixes, and it is testable
in isolation. The cost is maintaining a small Swift tool.

**Plugin flavors:** a **Build Tool Plugin** runs automatically during the build; a
**Command Plugin** runs on demand (right-click in Xcode) — useful for an opt-in
"audit optimizations" action too expensive to run every compile.

## C. Let the compiler tell you — most authoritative, least effort

Rather than guessing at anti-patterns from shape, turn on the signals the toolchain
already produces. These are facts, not heuristics.

| Signal | How | Catches |
| ------ | --- | ------- |
| **Strict concurrency** | `SWIFT_STRICT_CONCURRENCY = complete` | actor-isolation crossings, data races, needless `await`s — the real source of hops |
| **Slow type-checking** | `OTHER_SWIFT_FLAGS = -warn-long-expression-type-checking=100 -warn-long-function-bodies=100` | compile-time hotspots, surfaced inline as warnings |
| **Optimization remarks** | `-save-optimization-record=yaml` (+ `-save-optimization-record-path`) | what the optimizer *couldn't* do: failed inlining, leftover retain/release, failed generic specialization |

The optimization record is the gem for performance work: the `.opt.yaml` tells you
whether `@inline(__always)` actually inlined, whether value types avoided ARC
traffic, and where retain/release survived in the hot loop. Parse it (or view with
a tool like `optview2`) and you can emit those findings as warnings in the same
format, so "this hot function wasn't inlined" appears right in Xcode.

**Strict concurrency** is the most direct tool for the actor-hop question: it flags
the isolation crossings at the source instead of inferring them from shape. It
would have flagged the original per-row actor isolation immediately.

## Recommendation

- **Now:** enable `SWIFT_STRICT_CONCURRENCY = complete` and the `-warn-long-*`
  flags. Free, authoritative, no new dependencies; flags the per-row actor
  isolation directly.
- **For project-specific optimization hints:** a small **SwiftSyntax build tool
  plugin** with a few rules (await-in-loop, actor-call-in-loop,
  allocation-in-hot-loop). The only approach that understands structure well enough
  to be trustworthy, with proper inline warnings and fix-its.
- Keep **SwiftLint** alongside it for cheap, regex-able house rules.
- Skip the raw run script except as a last-resort shim.
