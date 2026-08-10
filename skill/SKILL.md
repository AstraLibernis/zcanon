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
  (`$ZEPHEM_HOME/zig-out/bin/zephem look <terms>` for keyword search, `… map doc <path>`
  for one exact decl). Zig's std churns fast; don't guess signatures.
- **`zcanon`** (this skill) — *while and after* you write, catch the known traps.

Two binaries, both under `zig-out/bin/` and both self-locating, so they work wherever zcanon
is cloned: **`zsnag`** (the linter) and **`zcanon`** (the hook, its installer, and the book
reader). No `nu`, no `sqlite3`. The commands below refer to the repo as **`$ZCANON_HOME`** —
set it once to your clone (e.g. `export ZCANON_HOME=/path/to/zcanon`) so they run verbatim
from any directory.

## After you edit a .zig file

The PostToolUse hook feeds back, on every `.zig` edit:
- `zig ast-check` — real syntax/compile errors
- `zsnag` — known LLM footguns (the list below)

**It only runs once installed** — `$ZCANON_HOME/zig-out/bin/zcanon install` writes the hook
into `~/.claude/settings.json` (backing it up first, and touching nothing but its own entry).

Verify with `zcanon status`, which prints four things — the hook is only working if all four
are right:

```
installed in settings: true
runtime state: enabled
zsnag binary: …/zig-out/bin/zsnag          ← flagged MISSING if absent
book: ~/.config/zcanon/book.tsv
```

A fresh clone has neither the hook installed nor the binaries built (`zig-out/` is gitignored) —
run `zig build` first. If zsnag is missing the hook now says so in-band rather than checking
nothing silently, but **do not read "no findings" as "no problems"** until `status` is clean.

Read the findings and fix them before moving on. To check a file by hand at any time:
`$ZCANON_HOME/zig-out/bin/zsnag <file>`.

Findings that survive are recorded to the book (`~/.config/zcanon/book.tsv`), so `hits` counts
real recurrences — each save re-scans the whole file and anything no longer present is pruned.
Read it with `zcanon book` (by rule), `zcanon book files`, `zcanon book recent [N]`, or
`zcanon book R0NN` for one rule's detail.

Off switch: `zcanon disable` / `zcanon enable` toggle at runtime without touching settings.json.
Full removal: `zcanon uninstall`.

## Mistakes to avoid (zsnag checks these)

- `async` / `await` / `usingnamespace` — removed from the language. (Method calls named
  `.async()`/`.await()` are fine — those are ordinary identifiers now.)
- `std.mem.copy` / `std.mem.set` — removed; use `@memcpy` / `@memset`.
- `catch unreachable` and empty `catch {}` — these hide or crash on real errors; handle them.
- `stream()` returning `0` does **not** mean end-of-stream — use `continue`, not `break`.
- `@intCast` / `@ptrCast` / `@alignCast` — can panic or corrupt; verify the value first.
- Acquire/release: every `init()` / `openFile()` of a resource needs a matching
  `defer x.deinit()` / `defer x.close()`.
- `page_allocator` as a general allocator is slow — pass an allocator in. (Backing an arena
  with it is fine.)
- `std.debug.print` left in shipped code — remove it or use `std.log`.

## Checked against the real std (R011–R013)

These three do not carry advice written by hand — they read the **zephem map**, so they cannot
go stale the way a hardcoded "use X instead" does:

- **R011** — the API is deprecated. The replacement is quoted *from the map*, e.g.
  ``std.mem.indexOf` is deprecated — the map says: use `find`.``
- **R012** — the argument count disagrees with the map's signature, which is printed with the
  finding so you can see the real parameter list.
- **R013** — a fully-qualified `std.*` path with no map entry: it may not exist. Advisory,
  because the resolver is deliberately conservative.

They run whenever zephem's lookup table is present. If it is missing, zsnag says so on stderr
and the other ten rules still run — it never silently drops them. Disable with `--no-map`.

Two limits worth knowing, so you read the output correctly: the resolver stops at the first
call, so `std.Io.Dir.cwd().readFileAlloc(…)` is checked as `std.Io.Dir.cwd` only (a method on
a *value* has an implicit first parameter that cannot be compared); and R013 can misfire on
enum-tag-then-method paths like `std.Io.Clock.real.now`. Both are in `PLAN.md`'s ledger.

Two suppressions, when a rule is genuinely wrong about your code: `zsnag:ok` anywhere on the
finding's own line (not the line above), or `zsnag:allow R0NN` anywhere in the file to silence
that rule file-wide. Say *why* in the same comment.

## What this tool does NOT do

It catches known traps and runs the compiler's syntax check on every edit. It does **not**
look up std APIs (that's the `zephem` skill), check your logic, or guarantee correctness.
The compiler and tests are the real safety net — compile and run tests (use
`Debug`/`ReleaseSafe` for runtime checks) before claiming code works.
