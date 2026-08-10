# zcanon — how the pieces tie together

## The goal

A portable pack that, installed next to an LLM, makes it write current, correct Zig
immediately — and that can grow toward feeding real data back to the Zig project itself.
The LLM writes the code and does the reasoning; zcanon controls **what the model knows at
the moment it writes**. That is the only lever (the model is stateless — its output is
decided entirely by what is in its context), so everything here is about getting the
right facts and checks in front of it at the right time.

## The flow

```
                         ┌─────────────── the model writes/edits Zig ───────────────┐
                         │                                                            │
   BEFORE writing        │   the ZEPHEM skill tells the model to search the MAP:     │
   ──────────────        │     • zephem look <terms>  → discover the current name     │
   (companion: zephem)   │     • zephem map doc <p>   → signature + resolved type +   │
                         │                            fields + factory members        │
                         │                                                            │
   AFTER an edit         │   zcanon's HOOK fires (once installed):                   │
   ─────────────         │     • zig ast-check  → syntax/compile errors               │
   (this pack)           │     • zsnag          → known LLM footguns                   │
                         │   findings are injected back into the model's context      │
                         └────────────────────────────────────────────────────────────┘

   GROUND TRUTH:  zephem's regenerable std map + the compiler + your tests
```

Two moments, now split across two packs:
- **the map** (via `zephem look` / `zephem map`) is *foresight* — consult before/while writing so
  the first draft is right. It's the single source of std truth; there is no live-lookup
  fallback (a shallow one would be less accurate). To refresh it, *regenerate zephem*. This
  half moved to **zephem**, which owns the data and the query layer over it, so a change to
  the map's contract can no longer break this pack.
- **the hook** (running zsnag + ast-check) is zcanon's *safety net* — catches what slipped
  through, right after the edit, with no need to remember.

Ground truth is never the model's memory: the map is compiled+self-verified from the std on
disk (regenerate when your Zig moves), and the compiler and tests judge correctness.

## The keystone: the skill

The tools are equipment; `skill/SKILL.md` is what makes the model *reach for the check every
session, in any project, without being told*. Without it, the tools sit unused (the same
trap that kills any tool that depends on discipline). The skill is therefore the piece
that turns "a few scripts on disk" into "install once, fewer Zig mistakes everywhere." It
cross-references the companion **zephem** skill, which owns the std-lookup half.

Install paths for the skill (pick one):
- copy/symlink `skill/SKILL.md` into `~/.claude/skills/zcanon/SKILL.md` (global), or
- reference it from a project's `CLAUDE.md`.

## Roadmap

**Done**
- `zsnag` (Zig) — 13 LLM-mistake rules in a registry (`--list-rules`), tokenizer-based; validated
  on real third-party code. 10 are self-contained; **R011/R012/R013 read the zephem map**, so
  their advice (the replacement name, the real signature) is data rather than a literal and
  cannot go stale. R003's premise is self-checked against the map at startup: if std ever
  brings `mem.copy` back, the rule disables itself instead of emitting stale advice.
- `zcanon hook` (Zig) — automatic, reversible PostToolUse checker; **logs every finding to the book**
- `zcanon book` (Zig) — reads the book: real mistakes ranked by frequency
- `skill/SKILL.md` — the behavioral instruction (footgun + hook half; cross-refs the zephem skill)
- **The std-lookup half moved to zephem** — `zephem look` (SIMD keyword search over the map) and
  `zephem map` (deterministic reader) are subcommands of zephem's single binary, with their own
  skill, since zephem owns the map's data. This kept a data-contract change from breaking zcanon again.
  (They earlier replaced `zfact`, a half-accurate live-std scanner, and the removed
  embedding/pgvector search; the map is complete and regenerable, so it stands alone.)

**The book (why, and why NOT synthetic).** We considered generating flawed Zig — from a
script, then from a small local model — and mining the failures. Both are dead ends for
the actual goal: a script only reproduces flaws we wrote into it, and a small model makes
*its* mistakes ("doesn't understand the language"), not the deployment model's ("this API
moved since training"). Wrong mistakes → noise. The correct generator already exists: the
hook, running on real edits by the real model. So the hook records every finding to
the book with the offending source line, and `zcanon book` reads it back. Frequency is the
signal — no synthesis, judged by the compiler. Honest limit (unchanged): this never makes
the model reason better; it turns accumulated real findings into better *context* (which
APIs to surface in the skill, which `zsnag` rules earn their keep).

**What happened on 2026-08-10.** Two silent failures were found and fixed on the same day.

*The hook had never fired.* Written 2026-07-14, but `--install` was never run — `settings.json`
carried no `hooks` key at all, while `skill/SKILL.md` claimed the hook ran "automatically". Four
weeks of unchecked Zig edits, with the skill asserting a safety net that did not exist.

*The book had never recorded anything, and could not.* `lib.nu` shelled out to `^sqlite3`; there
is no `sqlite3` binary on this machine. The failure was silent — findings were reported normally
while nothing persisted. So the book starts from zero as of today.

Both are closed: the hook is installed and verified firing, the Nushell layer is gone, and the
book is a TSV (B6/B7/B8 in the ledger). The book still has no accumulated history — item 1 below
is now about *gathering* data, not about making storage work.

**Next (in rough order of value)**
1. **Accumulate the book on real work**, then read it: the most frequent rules/APIs become a
   short cheat-sheet baked into `skill/SKILL.md`, shifting correction from reactive (hook
   catches me) to proactive (skill warns me first). Blocked on nothing but time and edits.
2. **Harden the skill** — tune the wording so the model reliably uses the tools without
   over-calling them. Measure by dogfooding on real Zig tasks.
3. **Precise `zsnag` (full-AST version)** — `zsnag` already uses the real Zig tokenizer;
   upgrade the heuristic rules (R006/R008) to `std.zig.Ast` (the parse tree) to cut the
   text-pattern false positives. This is now the highest-value fix, not a nicety: B1 and B10
   are both this bug, and between them they fire on most real Zig files.
4. **Bundle as one installable unit** — a single installer that wires tools + hook + skill
   + book in one step, so "copy home, settle on Claude" is literally one command.

## Bug ledger

Defects, closed explicitly rather than quietly. Opened 2026-08-10.

| # | Status | Where | Defect |
|---|---|---|---|
| B1 | OPEN | `zsnag.zig` R008 | **Systematic false positive.** The acquire scan takes `const NAME` and reads forward to the next `;` — for `const T = struct { … }` that span is the *entire struct body*, so it captures any `ArenaAllocator`/`ArrayList` field plus any `.init(` inside, binds the acquisition to the type name, then hunts for a `T.deinit` that will never exist. Fires on most files declaring a type that owns an allocator. Fixed by the R006/R008 AST upgrade (item 3 above). Live example: `src/book.zig`'s `Book`, suppressed with `zsnag:ok`. |
| B10 | OPEN | `zsnag.zig` R008 | **Second false-positive mode, worse than B1.** The scan treats the `const` keyword *inside a type expression* as a declaration: in `fn init(text: []const u8) !Fixture {` it binds to the following identifier (`u8`), reads forward to the next `;` — swallowing the whole function body — and then hunts for a `u8.deinit`. `[]const u8` appears in nearly every Zig file, so this fires broadly. Same fix as B1 (parse declarations from the AST, not from a keyword scan). Live examples suppressed in `src/test/settings_test.zig`. |
| B11 | OPEN | `zsnag.zig` + `tier.zig` | R008 is `warn`, so it lands in `caution`, and only `advisory` demotes to `expected`. Test files therefore never get the scratch demotion, and B1/B10 noise shows at full severity in `src/test/*`. Revisit once B1/B10 are fixed — the demotion rule may be fine and the FPs the whole problem. |
| B2 | **CLOSED** 2026-08-10 | `snag.zig` | `--json` was hand-built with no escaping; a path containing `"` or `\` emitted invalid JSON. **Fixed:** strings go through `std.json.Stringify.value`; regression-tested with a path containing both. |
| B3 | **CLOSED** 2026-08-10 | `zsnag.zig` | All output, `--json` included, went to **stderr** via `std.debug.print`. **Fixed:** findings go to stdout, diagnostics to stderr. |
| B4 | **CLOSED** 2026-08-10 | `snag.zig` | Silent truncation at 128 R008 acquisitions / 32 `zsnag:allow` codes per file. **Fixed:** both grow dynamically; regression-tested with 60+ allow codes. |
| B5 | OPEN | `zsnag.zig` | R006 and R008 each rescan the whole token stream per candidate — O(n²). |
| B6 | **CLOSED** 2026-08-10 | `hook.zig` / `zcanon.zig` | **Fail-quiet**: `if ($zs | path exists)` skips zsnag silently when the binary is missing, and `zig-out/` is gitignored — a fresh clone checks nothing and says nothing. **Fixed:** the hook now emits an explicit in-band warning naming the missing path, and `zcanon status` flags it. |
| B7 | **CLOSED** 2026-08-10 | `book.zig` | SQL built by string interpolation through a hand-rolled quote-doubler; `zbook.nu`'s `R0NN` branch skips even that. **Fixed:** no SQL at all — the book is TSV with escaped delimiters, round-trip tested. |
| B8 | **CLOSED** 2026-08-10 | `hook.zig` | ast-check parse regex `^(?<file>[^:]+):` cannot match a path containing `:`, and drops `note:` lines. **Fixed:** `parseAstCheck` splits on the `: error: ` separator and takes line/col from the right of the path, so colons in paths parse; `note:` lines are kept as advisory. Both regression-tested. |
| B12 | OPEN | `snag.zig` R013 | **False positive on enum-tag-then-method.** `std.Io.Clock.real.now(io)` resolves as the dotted path `std.Io.Clock.real.now`, which is not a map entry — `real` is an enum *tag* and `now` is a method on the enum. The chain-stops-at-a-call rule does not help because there is no intervening call. Needs the resolver to notice that a prefix (`std.Io.Clock.real`) resolves with kind `tag` and fall back to the parent type's member. Live example suppressed in `src/book.zig`. |
| B9 | OPEN (upstream) | zephem | Subcommand parsers ignore unknown flags, so `zephem std --help` performs a **full map regeneration** and `zephem depth --help` starts the multi-minute L5 sweep. Never forward flags to a zephem subcommand. |

**Adversarial audit, 2026-08-10.** After R012's first implementation shipped 16 false positives
found by accident, the work was handed to two independent reviewers — one blind, one refuting
specific claims. Both found real defects; the confirmed ones are B13–B19 above. Two claims of
mine were refuted and are corrected in the record: "byte-identical parity with the Nushell hook"
held for one fixture only (three divergences are deliberate ledger fixes, one — missing dedup —
was not), and "R013 is low-noise" was measured on 15 files and is wrong (219 firings on std).

Also worth recording: **zsnag found a real bug in Zig's standard library.**
`lib/std/debug/cpu_context.zig:51` calls `std.mem.reverse(native.r[0..])` with one argument
against a two-parameter signature. R012 working as designed.

**Found by dogfooding, already closed.** R012's first implementation counted commas rather
than parameters, so every wrapped std signature with a trailing comma (`fn sort( a, b, c, d, )`)
read as one parameter too many — 16 false positives on zcanon's own source in its first run.
Both the signature parser and the call-site counter now count non-empty segments. R012 fires
zero times on correct code.

**Found by the same run, real:** 36 genuine deprecations in zcanon's own new Zig —
`std.mem.indexOf` → `find`, `lastIndexOfScalar` → `findScalarLast`, `indexOfScalarPos` →
`findScalarPos`, `indexOfScalar` → `findScalar`. All written from stale memory, all caught by
R011 reading the map, all fixed. This is the integration paying for itself on day one.

| B13 | **CLOSED** 2026-08-10 | `zcanon.zig` | The "zsnag was NOT run" notice was emitted twice: with no findings, `ctx` was assigned `notice` and then concatenated with `notice` again. **Fixed:** `hook.compose` assembles body + notices + hint exactly once. |
| B14 | **CLOSED** 2026-08-10 | `hook.zig` | **Phantom BLOCKING findings.** `zig ast-check` echoes the offending source line under each diagnostic; `parseAstCheck` trimmed each line and accepted anything containing `": error: "`, so an echoed line holding that string parsed as a second, invented diagnostic at error severity. **Fixed:** a diagnostic must start at column 0 and name the file under check. Regression-tested with verbatim ast-check output. |
| B15 | **CLOSED** 2026-08-10 | `hook.zig` / `zcanon.zig` | `MAX_CONTEXT` was a raw byte slice over text containing `▲ ⚠ ℹ ·` (could split a UTF-8 sequence), it silently dropped `HINT`, and the notice was concatenated *after* truncating so output could exceed the cap. **Fixed:** `truncateUtf8` cuts on a codepoint boundary; notices and hint are reserved from the budget, not truncated away. |
| B16 | **CLOSED** 2026-08-10 | `snag.zig` R001 | **8 error-severity false positives on `lib/std/Io.zig` alone**, 13 across std. `async`/`await` are ordinary identifiers now, so std declares them (`async,` as an enum member, `await(ev, …)` as a call, `.async = async` reading a field) — and R001 matched the bare name. **Fixed:** flag only the stale syntax `async <expr>` / `await <expr>`, i.e. followed by an identifier. Measured 13 → 0 on std, with the real pattern still caught. |
| B17 | **CLOSED** 2026-08-10 | `zsnag.zig` / `zcanon.zig` / `book.zig` | **Three "the checker ran" lies silently erased the book.** zsnag exits 0 even when the zephem map fails to load, so the hook believed R011–R013 had run and found nothing → `pruneFile` deleted their entire history for the file (a moved `$ZEPHEM_HOME` wiped a third of the book). Likewise `ran_ast` was set without checking `term`, and exit 1 conflated "error findings" with "file unreadable". **Fixed:** zsnag *reports* which rule groups ran in a machine-readable status record; pruning is scoped per group; exit codes are distinct (0 clean, 1 error findings, 2 usage, 3 unreadable). |
| B18 | **CLOSED** 2026-08-10 | `settings.zig` | Three ways the user's own settings file was damaged: the empty-scaffolding cleanup ran even when nothing was removed (deleting a pre-existing empty `"PostToolUse": []`); `addOurs` deleted and recreated `PostToolUse`, silently moving it to the END of `hooks`; and `load` aborted outright on a duplicate key (`error.DuplicateField`) or a UTF-8 BOM. **Fixed:** clean up only after an actual removal, filter in place, strip the BOM, `duplicate_field_behavior = .use_last`. |
| B19 | **CLOSED** 2026-08-10 | `zcanon.zig` | `try recordToBook(...)` was the only unswallowed error in `runHook`, so a book-write failure (or `error.NegativeTimestamp`) exited non-zero with zero findings — the opposite of the documented always-report invariant. **Fixed:** book failures degrade to an in-band notice. |

**Stretch — give back to Zig**
The book accumulates data on which mistakes are most common and where the compiler's error
messages are cryptic. That is a concrete, grounded contribution to the Zig project:
**propose clearer compiler diagnostics upstream**, backed by frequency data. (Not
"AI auto-fixes Zig" — that is a research problem, not a promise.)

## Honest ceiling

zcanon makes the model **current and self-checking**, not a better reasoner. It removes
the dominant failure (stale API knowledge) and catches known traps. Novel logic bugs are
still caught only by the compiler, your tests, and the model's own reasoning — zcanon
feeds those, it does not replace them.
