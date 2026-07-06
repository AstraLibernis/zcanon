---
name: zcanon
description: >-
  Use whenever writing, editing, or reviewing Zig (.zig) code. Your training
  knowledge of Zig's fast-moving standard library is likely stale; zcanon grounds
  every std API call in zephem's map of the ACTUAL std — a complete, self-verified,
  regenerable snapshot — and flags the common LLM Zig mistakes. Reach for it any
  time a task produces or changes Zig.
---

# Writing Zig with zcanon

Your memory of Zig's standard library is probably out of date — Zig changes fast and
its std churns. **Do not write std signatures from memory.** Verify against the **zephem
map** — a complete, self-verified, *regenerable* snapshot of the actual std — first.
Replace recall with ground truth.

The tools live at **`~/projects/zcanon`** (the two Zig binaries — `zlook`, `zsnag` — are
prebuilt under `zig-out/bin/`; the Nushell tools run with `nu`). Use full paths so they
work from any directory:

## Before you write a std API call

1. **Don't know the name?** Search the **complete, verified std map** by keyword. This
   is deterministic — every literal match across all names/signatures/docs is returned,
   ranked name-first (no fuzzy model, no missed answers). Prefer `zlook` (SIMD-fast, one
   shot, also searches the **resolved type/error-set** — e.g. find every fn that returns
   `OutOfMemory`); it needs a one-time `nu ~/projects/zcanon/nu/build_lookup.nu`. `zmap`
   is the Nushell equivalent that reads zephem's TSVs directly (no lookup table):
   ```sh
   ~/projects/zcanon/zig-out/bin/zlook parse int         # AND of all terms, structured hits
   ~/projects/zcanon/zig-out/bin/zlook OutOfMemory       # find fns by resolved error set
   nu ~/projects/zcanon/nu/zmap.nu find "constant time"  # zmap: quote a multi-word term
   nu ~/projects/zcanon/nu/zmap.nu show std.fmt          # browse a whole module/subtree
   ```
   **YOU are the semantic layer.** Pick the mechanism words you'd expect to see in std's
   own names/docs ("delimiter", "alloc", "parse", "hash"), search, and if nothing lands,
   rethink the wording and search again. Use `show <module>` when you know the
   neighborhood but not the exact name.

2. **Know the name? Look it up in the map** for its exact signature, resolved type, doc,
   fields/tags, and factory members:
   ```sh
   ~/projects/zcanon/zig-out/bin/zlook Io.Reader.streamDelimiter
   ~/projects/zcanon/zig-out/bin/zlook HashMap get         # a factory member: Type().method
   ```
   The map carries everything you need to write the call — the as-written signature, the
   compiler-resolved type/error-set, a struct's field types, an enum's tags, and the
   members a `fn(…) type` factory produces (pathed `Type().method`). Prefer the most
   efficient variant it surfaces (`appendAssumeCapacity` after `ensureTotalCapacity`), not
   just the first thing that compiles.

**The map is the single source of std truth** — no live-lookup fallback, by design (a
shallow fallback would be *less* accurate, defeating the point). It is a **regenerable**
snapshot pinned to a Zig version, so it's authoritative, not a guess. If it's stale — its
`PINNED` zig differs from your installed zig, and the tools warn you — **regenerate it**,
never fall back to memory:
```sh
cd ~/projects/zephem && nu scripts/build_std.nu    # rebuild the map (self-verifies)
nu ~/projects/zcanon/nu/build_lookup.nu            # refresh zlook's index from it
```

## After you edit a .zig file

The `zhook` PostToolUse hook runs **automatically** on every `.zig` edit and feeds back:
- `zig ast-check` — real syntax/compile errors
- `zsnag` — known LLM footguns (the list below)

Read those findings and fix them before moving on. They are also recorded to a local
log ("the book", `~/.config/zcanon/book.db`); review recurring patterns with
`nu ~/projects/zcanon/nu/zbook.nu`. If the hook is somehow not active, run the check
yourself: `~/projects/zcanon/zig-out/bin/zsnag <file>`.

## Mistakes to avoid (zsnag checks these)

- `async` / `await` / `usingnamespace` — removed from the language. (Method calls named
  `.async()`/`.await()` are fine — those are ordinary identifiers now.)
- `std.mem.copy` / `std.mem.set` — removed; use `@memcpy` / `@memset`.
- `catch unreachable` and empty `catch {}` — these hide or crash on real errors; handle them.
- `stream()` returning `0` does **not** mean end-of-stream — use `continue`, not `break`.
- `@intCast` / `@ptrCast` / `@alignCast` — can panic or corrupt; verify the value first.
- Acquire/release: every `init()` / `openFile()` of a resource needs a matching
  `defer x.deinit()` / `defer x.close()`.

## What these tools do NOT do

They keep your API usage current and catch known traps. They do **not** check your logic
or guarantee correctness. The compiler and tests are the real safety net — compile and
run tests (use `Debug`/`ReleaseSafe` for runtime checks) before claiming code works.
