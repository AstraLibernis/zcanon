---
name: zcanon
description: >-
  Use whenever writing, editing, or reviewing Zig (.zig) code. zcanon catches the
  mistakes an LLM tends to make in Zig — removed builtins, footguns, unbalanced
  acquire/release — via the zsnag linter and a PostToolUse hook that runs zsnag +
  `zig ast-check` on every edit. For looking UP real std APIs (names, signatures,
  resolved types) so you don't write them from memory, use the companion `zephem` skill.
---

# Writing correct Zig with zcanon

zcanon keeps you from the mistakes an LLM makes in Zig. It is the **footgun + edit-check**
half of the Zig toolkit; the **std-lookup** half lives in the companion **`zephem`** skill.
Reach for both when writing Zig:

- **`zephem`** (companion skill) — *before* you write a std call, look the API up in
  zephem's complete, verified std map instead of recalling it from memory
  (`nu ~/projects/zephem/query/zlook.nu <terms>` / `zmap`). Zig's std churns fast; don't
  guess signatures.
- **`zcanon`** (this skill) — *while and after* you write, catch the known traps.

The tool lives at **`~/projects/zcanon`** (`zsnag` is prebuilt under `zig-out/bin/`; the
Nushell tools run with `nu`). Use full paths so they work from any directory.

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

## What this tool does NOT do

It catches known traps and runs the compiler's syntax check on every edit. It does **not**
look up std APIs (that's the `zephem` skill), check your logic, or guarantee correctness.
The compiler and tests are the real safety net — compile and run tests (use
`Debug`/`ReleaseSafe` for runtime checks) before claiming code works.
