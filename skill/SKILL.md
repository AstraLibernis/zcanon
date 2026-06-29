---
name: zforge
description: >-
  Use whenever writing, editing, or reviewing Zig (.zig) code. Your training
  knowledge of Zig's fast-moving standard library is likely stale; zforge grounds
  every std API call in the ACTUAL installed std and flags the common LLM Zig
  mistakes. Reach for it any time a task produces or changes Zig.
---

# Writing Zig with zforge

Your memory of Zig's standard library is probably out of date — Zig changes fast and
its std churns. **Do not write std signatures from memory.** Verify against the
installed std with the zforge tools first. Replace recall with ground truth.

The tools live at **`~/projects/zforge`** (the two Zig binaries are prebuilt under
`zig-out/bin/`; the Nushell tools run with `nu`). Use full paths so they work from any
directory:

## Before you write a std API call

1. **Don't know the name?** Find it by concept (semantic search over the *complete*,
   verified std index):
   ```sh
   nu ~/projects/zforge/nu/zfind.nu "read a line until a newline"
   nu ~/projects/zforge/nu/zfind.nu "grow a dynamic array" --raw   # --raw if your phrasing is already mechanical
   ```
   It returns ranked std paths with signatures + docs, and flags aliases ("→ alias of
   X — prefer the canonical name").

2. **Know the name? Confirm the exact CURRENT signature** and see the neighborhood:
   ```sh
   ~/projects/zforge/zig-out/bin/zfact Io.Reader.streamDelimiter
   ```
   The output lists the symbol's family and any "use X instead" notes — prefer the most
   efficient variant (e.g. `appendAssumeCapacity` after `ensureTotalCapacity`), not just
   the first thing that compiles.

## After you edit a .zig file

The `zhook` PostToolUse hook runs **automatically** on every `.zig` edit and feeds back:
- `zig ast-check` — real syntax/compile errors
- `zsnag` — known LLM footguns (the list below)

Read those findings and fix them before moving on. They are also recorded to a local
log ("the book", `~/.config/zforge/book.db`); review recurring patterns with
`nu ~/projects/zforge/nu/zbook.nu`. If the hook is somehow not active, run the check
yourself: `~/projects/zforge/zig-out/bin/zsnag <file>`.

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
