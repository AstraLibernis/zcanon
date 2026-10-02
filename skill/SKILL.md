---
name: zcanon
description: >-
  Use whenever writing, editing, or reviewing Zig (.zig) code. zcanon catches the
  mistakes an LLM tends to make in Zig — removed builtins, footguns, unbalanced
  acquire/release — via the zsnag linter and a PostToolUse hook that runs zsnag +
  `zig ast-check` on every edit (including edits made from the shell). Also covers looking UP
  real std APIs (names, signatures, resolved types) in the zephem map so you don't write
  them from memory.
---

# Writing correct Zig with zcanon

zcanon keeps you from the mistakes an LLM makes in Zig, in two halves:

- **Before** you write a std call, look it up in the **zephem map**, a complete, verified
  snapshot of this Zig's std, instead of recalling it from memory:
  `{{ZEPHEM}} look <terms>` for keyword search, `{{ZEPHEM}} map find <name>` to see
  whether a name exists and what replaced it, `{{ZEPHEM}} map doc <path>` for one exact decl,
  `{{ZEPHEM}} map show <path>` for a whole module or type.
  Zig's std churns fast; don't guess signatures. If `map find` has no hit for a path you were
  about to use, that API does not exist in this Zig. Don't write it.
  - Exit codes: **0** found · **1** no match (stderr may suggest the path you meant) · **2**
    usage · **3** the map is unavailable. 3 is NOT a miss: regenerate the map, never fall back
    to memory.
  - Thin names are followed: `map doc std.ArrayList.append` resolves to
    `std.array_list.Aligned().append`, and hits list their other public names on a `≡` line.
  - `[priv]` hits are private decls, real but not callable at that path from outside their file.
  - Builtins are in the map too: `{{ZEPHEM}} map doc @intCast` (signature, doc, langref example).
  - Third-party packages: if the project has dependencies, run `{{ZEPHEM}} deps <project>` once
    (after `zig build --fetch`); then `look`/`map` answer for them too (`map doc clap.parse`).
  - A multi-word `look` that no single decl matches prints the best hits per term on stderr —
    compose the answer from those (`print stdout` → `std.Io.File.stdout` + `Writer.print`).
- **While and after** you write, the hook catches the known traps (below).

This copy of the skill was installed by `zcanon setup`, which filled in the real paths above
and below. Two binaries: **`zsnag`** (the linter) and **`zcanon`** (the hook, its setup and
the book reader). No `nu`, no `sqlite3`, no environment variables to set.

## After you edit a .zig file

The PostToolUse hook feeds back, on every `.zig` edit — through Edit/Write, or through a shell
command (`sed -i`, a heredoc, a script, `zig fmt`): after each Bash call it checks every `.zig`
file modified since the previous tool call, under the working directory and any `cd` target:
- `zig ast-check` — real syntax/compile errors
- `zsnag` — known LLM footguns (the list below)

It reports in a **short view**: a tally line, one row per blocking (`▲`) or caution (`⚠`)
finding, and the advisory tiers collapsed to rule + line numbers. For every message, run
`{{ZCANON}} check --full <file.zig>`; `{{ZCANON}} view full` switches the hook itself to the full
layout (`view short` switches back).

**Semantic errors (types, calls, fields) come from a background compiler.** The hook starts a
per-project background process on the first `.zig` edit. It keeps Zig's incremental compiler
running (`zig build check --watch -fincremental`), and every hook reports the latest result as
`▲ [compile] path:line:col  message`. The hook never waits for the compiler, so an edit's own
errors usually arrive with the *next* edit, and a result that predates the edit says so. The
process exits after 30 idle minutes. `{{ZCANON}} daemon status` / `daemon stop` inspect or stop it.
- Any project with a build.zig is covered, with nothing to set up. zcanon uses the project's own
  `check` step when it has one. Otherwise it writes its own build file under
  `~/.config/zcanon/wrap/`, which loads the project as a dependency; the project's build.zig
  is only read. A project with no build.zig gets the syntax and footgun checks only.
- It checks for the host OS. Code built only for another OS (a Windows GUI checked on Linux) is
  not analysed unless that target is added: `{{ZCANON}} targets <project> x86_64-windows`.
- `zig build check` only analyses code reachable from the project's artifacts and tests; an
  unused function is not type-checked until something calls it.

It is installed and verified by one command, `{{ZCANON}} setup`, which checks zephem, checks
that it can hook into Claude Code, installs the hook, then runs it on a probe file to prove the
core rules, the zephem map rules and `zig ast-check` all fire. If findings stop appearing, run
`{{ZCANON}} doctor`: the same checks, changing nothing, each failure with its fix.
**Do not read "no findings" as "no problems"** unless `doctor` passes.

Read the findings and fix them before moving on. To check a file by hand at any time:
`{{ZCANON}} check [--full] <file.zig>` (the hook's exact checks; exit 1 = something blocking) or
`{{ZSNAG}} <file.zig>` (the linter alone).

The first time zcanon sees a file, what is already in it is its baseline: tracked, not counted
as a mistake, except lines the edit itself wrote. After that, every mistake is recorded in the book (`~/.config/zcanon/book.tsv`): one line per mistake
(rule plus message; compiler messages grouped by shape), with how many times it was made, when
first and last, and where it last happened (`path:line`). Making it again counts +1; fixing it
never removes the line. A finding still in the file on the next save is not counted again. A
mistake made 5 times goes into the bug report (`bugs.md` beside the book), which is never
pruned. Read them with `{{ZCANON}} book` (most frequent first), `book rules`, `book recent [N]`,
`book open` (findings in the code right now), `book R0NN`, and `{{ZCANON}} bugs`. `book publish` pushes a sanitized copy (no code, no paths) into a repo's `history/`.

Off switch: `{{ZCANON}} disable` / `enable` toggle at runtime without touching settings.json.
Full removal: `{{ZCANON}} uninstall`.

## Workflow

1. `map find` every std symbol you intend to use
2. Write the file
3. Read the hook's findings (or run `check`) and fix them; `zig ast-check` must be clean
4. Compile and run the tests before claiming the code works

## Your most repeated mistakes

<!-- zcanon:mistakes -->
None recorded yet. This list fills in from the book as mistakes are made.
<!-- /zcanon:mistakes -->

## Modern Zig 0.16 shapes your training data probably gets wrong

    var list: std.ArrayList(u8) = .empty;   // NOT ArrayList(u8).init(gpa)
    defer list.deinit(gpa);                  // allocator passed to deinit
    try list.append(gpa, 'x');               // allocator passed to append
    const v: u8 = @intCast(big);             // ONE argument, not @intCast(u8, big)
    std.Io.Dir.cwd()                         // NOT std.fs.cwd(); file calls take an `io`

Confirm any other shape with `map find` before writing it.

## Mistakes to avoid (zsnag checks these)

- `async` / `await` / `usingnamespace` — removed from the language. (Method calls named
  `.async()`/`.await()` are fine — those are ordinary identifiers now.)
- `std.mem.copy` / `std.mem.set` — removed; use `@memcpy` / `@memset`.
- `catch unreachable` and empty `catch {}` — these hide or crash on real errors; handle them.
- `Reader.stream()` returning `0` does **not** mean end of stream (that is
  `error.EndOfStream`) — keep looping, don't `break`.
- `@intCast` / `@ptrCast` / `@alignCast` / `@enumFromInt` / `@intFromFloat` — can panic or
  corrupt on an out-of-range value; verify it first.
- Acquire/release: an `openFile`/`createFile`/`openDir` needs `defer x.close(io)`; an
  `ArenaAllocator`/`DebugAllocator`/`Io.Threaded` needs `defer x.deinit()`; a collection
  (`= .empty`, `.init(alloc)`) needs `deinit` unless its allocator is an arena.
- `std.Io.File.stdout().writer(…)` writes at file offsets, so two runs redirected into one
  file overwrite each other. Use `.writerStreaming(…)` for stdout/stderr.
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
- **R013** — a fully-qualified `std.*` path with no map entry: it may not exist (a removed
  API like `std.fs.cwd` or `std.io.getStdOut`, or an invented one). On by default, at
  advisory severity because the resolver is deliberately conservative. Treat it as "look this
  up in the map before trusting it".

They run whenever zephem's lookup table is present. If it is missing, the hook and `check` say
so in their output (zsnag on stderr) and the other eleven rules still run — they never silently
drop them. zsnag's `--no-map` disables all three; `--no-check-existence` disables R013 alone.

Two limits worth knowing, so you read the output correctly: the resolver stops at the first
call, so `std.Io.Dir.cwd().readFileAlloc(…)` is checked as `std.Io.Dir.cwd` only (a method on
a *value* has an implicit first parameter that cannot be compared); and R013 can misfire on
enum-tag-then-method paths like `std.Io.Clock.real.now`. Both are in `PLAN.md`'s ledger.

Two suppressions, when a rule is genuinely wrong about your code: `zsnag:ok` anywhere on the
finding's own line (not the line above), or `zsnag:allow R0NN` anywhere in the file to silence
that rule file-wide. Say *why* in the same comment.

## What this tool does NOT do

It catches known traps and runs the compiler's syntax check on every edit. It does **not**
check your logic or guarantee correctness.
The compiler and tests are the real safety net — compile and run tests (use
`Debug`/`ReleaseSafe` for runtime checks) before claiming code works.

## Known blind spots

- **R008 flags a leaked collection only when its allocator is visibly a real heap**
  (`std.testing.allocator`, `smp_allocator`, `c_allocator`, `page_allocator`). An unflagged
  `= .empty` list is not proof of no leak — it only means the allocator could be an arena.
- **R008 is an AST rule: it does not fire on a file that fails to parse.** When writing
  fixtures, keep removed-keyword cases (R001/R002/R003, which make a file unparseable) in a
  separate file from R008 cases.
- `zig ast-check` is syntax-level: it accepts calls to APIs that no longer exist. For code in a
  `test` block the real bar is `zig test --test-no-exec`.
