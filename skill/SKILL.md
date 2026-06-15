---
name: zforge
description: >-
  Use whenever writing or refining Zig code. Grounds Zig work in the current,
  installed standard library instead of stale training knowledge, and avoids the
  common LLM Zig mistakes. Invoke for any task that produces or edits .zig code.
---

# Writing Zig with zforge

Your memory of Zig's standard library is probably out of date — Zig changes fast.
Do not trust it. Verify against the installed std using the zforge tools. The tools
live in the zforge checkout's `bin/` (put it on PATH, or use the full path).

## Before you write a std API call

1. If you are unsure of the **name**, find it by concept:
   `zfact find "read a line until newline"`
2. Confirm the **exact current signature** and see the alternatives:
   `zfact Io.Reader.streamDelimiter`
   The output also lists the symbol's family and any "use X instead" notes — prefer the
   most efficient variant (e.g. `appendAssumeCapacity` after `ensureTotalCapacity`),
   not just the first one that compiles.

Never write a std signature from memory without confirming it. The whole point is to
replace recall with ground truth.

## After you edit a .zig file

The `zhook` PostToolUse hook (if installed) runs automatically and reports:
- `zig ast-check` — real syntax/compile errors
- `zsnag` — known LLM footguns

Read its findings and fix them before moving on. If the hook is not installed, run
`zsnag <file>` yourself.

## Mistakes to avoid (zsnag checks these)

- `async` / `await` / `usingnamespace` — removed from the language. (Method calls named
  `.async()`/`.await()` are fine — those are ordinary identifiers now.)
- `std.mem.copy` / `std.mem.set` — removed; use `@memcpy` / `@memset`.
- `catch unreachable` and empty `catch {}` — these hide or crash on real errors; handle them.
- `stream()` returning `0` does **not** mean end-of-stream — use `continue`, not `break`.
- `@intCast` / `@ptrCast` / `@alignCast` — can panic or corrupt; verify the value first.
- Acquire/release: every `init()`/`openFile()` of a resource needs a matching
  `defer x.deinit()` / `defer x.close()`.

## What these tools do NOT do

They keep your API usage current and catch known traps. They do not check your logic or
guarantee correctness. The compiler and tests are the real safety net — compile and run
tests (use `ReleaseSafe`/`Debug` for runtime checks) before claiming code works.
