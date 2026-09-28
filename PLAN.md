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
also carries the std-lookup half: how to query the zephem map. zephem itself ships no skill,
hook or MCP server (removed 2026-09-28); it is only the map, and zcanon is its agent-facing consumer.

`zcanon setup` installs it to `~/.claude/skills/zcanon/SKILL.md` with this machine's real
paths filled in, and `zcanon doctor` reports when the installed copy has drifted from the repo's.

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
| B1 | **CLOSED** 2026-08-10 | `snag.zig` | R008 read `const NAME` forward to the next `;` — for `const T = struct { … }` the whole struct body — so any type owning an `ArrayList`/`ArenaAllocator` looked like an unreleased acquisition. **Fixed:** declarations come from `std.zig.Ast.fullVarDecl`, and an initializer that is a container declaration is skipped outright. |
| B10 | **CLOSED** 2026-08-10 | `snag.zig` | The `const` inside `[]const u8` was read as a declaration binding to `u8`, swallowing the function body. **Fixed by the same AST migration**: a parameter type is not a var-decl node, so it is never considered. Proven by DELETING the `zsnag:ok` workarounds from `src/book.zig` and `src/test/settings_test.zig` — the tree lints clean without them. |
| B11 | **DROPPED** 2026-08-10 | `snag.zig` + `tier.zig` | R008 is `warn` → `caution`, and only `advisory` demotes in scratch code, so test files showed heuristic noise at full severity. The proposed fix was a `heuristic` flag on `Rule` with a conditional demotion. **Re-measured after the AST migration: zero caution-tier findings across the whole tree.** The noise was the false positives, not the tier policy. Dropped deliberately rather than adding a knob nothing needs — reopen only if real heuristic noise reappears in test code. |
| B20 | **CLOSED** 2026-08-10 | `snag.zig` | `scanWithOpts` sorted the caller's WHOLE accumulator, so `zsnag b.zig a.zig` interleaved files by line number and output order stopped matching argument order. **Fixed:** only the range this call appended is sorted. Covered by a CLI test. |
| B2 | **CLOSED** 2026-08-10 | `snag.zig` | `--json` was hand-built with no escaping; a path containing `"` or `\` emitted invalid JSON. **Fixed:** strings go through `std.json.Stringify.value`; regression-tested with a path containing both. |
| B3 | **CLOSED** 2026-08-10 | `zsnag.zig` | All output, `--json` included, went to **stderr** via `std.debug.print`. **Fixed:** findings go to stdout, diagnostics to stderr. |
| B4 | **CLOSED** 2026-08-10 | `snag.zig` | Silent truncation at 128 R008 acquisitions / 32 `zsnag:allow` codes per file. **Fixed:** both grow dynamically; regression-tested with 60+ allow codes. |
| B5 | **CLOSED** 2026-08-10 | `snag.zig` | R006/R008 rescanned the whole token stream per candidate. **Fixed:** the release search is scoped to the declaration's own function span, so work is bounded by function size rather than file size. |
| B6 | **CLOSED** 2026-08-10 | `hook.zig` / `zcanon.zig` | **Fail-quiet**: `if ($zs | path exists)` skips zsnag silently when the binary is missing, and `zig-out/` is gitignored — a fresh clone checks nothing and says nothing. **Fixed:** the hook now emits an explicit in-band warning naming the missing path, and `zcanon status` flags it. |
| B7 | **CLOSED** 2026-08-10 | `book.zig` | SQL built by string interpolation through a hand-rolled quote-doubler; `zbook.nu`'s `R0NN` branch skips even that. **Fixed:** no SQL at all — the book is TSV with escaped delimiters, round-trip tested. |
| B8 | **CLOSED** 2026-08-10 | `hook.zig` | ast-check parse regex `^(?<file>[^:]+):` cannot match a path containing `:`, and drops `note:` lines. **Fixed:** `parseAstCheck` splits on the `: error: ` separator and takes line/col from the right of the path, so colons in paths parse; `note:` lines are kept as advisory. Both regression-tested. |
| B12 | **CLOSED** 2026-08-10 | `snag.zig` R013 | Superseded by the wider bug it was an instance of: R013 followed a dotted path through a VALUE with no guard, where R012 explicitly refuses to. 219 firings on Zig's own std, essentially all false. **Fixed:** resolve the longest prefix present in the map and report only when its kind is a container (`ns`/`struct`/`enum`/`union`/`opaque`); a value kind (`const`/`alias`/`tag`/`field`/`fn`) means member access the map cannot follow. Measured **219 → 3**, and those 3 are decls genuinely absent from the map. R013 is now also OPT-IN (`--check-existence`). |
| B21 | **CLOSED** 2026-08-10 | `snag.zig` / `zsnag.zig` / `book.zig` | **A syntax error silently erased R008's history.** Once R008 moved to the AST it is skipped on a file that does not parse — which is precisely when an LLM's stale-syntax mistakes appear. The `core` group still reported active, so `pruneFile` deleted every R008 row for that file as "resolved" while the leak was still in the source. Same class as B17, introduced by the P1-A migration and missed by it. **Fixed:** R008 moved to its own `structural` group, reported in the status record only when the parse succeeded. Regression-tested end to end. |
| B22 | **CLOSED** 2026-08-10 | `snag.zig` / `zsnag.zig` | **A documented behaviour that did not exist.** PLAN.md stated that a rule whose premise the map contradicts "disables itself instead of emitting stale advice". It did not — `stalePremises` printed a warning to stderr and the rule went on firing at error severity. **Fixed:** contradicted rules are now suppressed outright (`Opts.stale`), which is what the doc always claimed. Found by the shakedown, not by a test. |
| B23 | **CLOSED** 2026-08-10 | `settings.zig` | Dead declaration: `pub const Status` was defined and never referenced. Removed. Found by scanning every public symbol for references outside its own declaration line. |
| B24 | **CLOSED** 2026-08-10 | `src/zephem.zig` | **`arityOf` was wrong on 17 of the 68 prose-bearing std signatures** — the in-place `///` skip (which replaced B16's comma-counting) guessed the prose/parameter boundary and guessed wrong: `std.Io.Dir.readFileAlloc` (5 params) counted as 3, `AstGen.GenZir.addParam` (7) as 2, 8 more fell out as unbalanced. Found by an adversarial reviewer who built an oracle from the compiler's own source. **Fixed** by porting zephem's validated splitter (strip prose first, then count). Now gated by `src/test/oracle_arity_test.zig`: the whole 68-row population, expected values derived from std source independently of the implementation, and run against the OLD code to prove it fails. |
| B9 | LOGGED (upstream, not ours to fix) | zephem | **Superseded by a full scoped audit — see [docs/upstream-zephem-audit.md](docs/upstream-zephem-audit.md)** (6 findings across argument handling, the query commands, and the `sig` column; the map data itself was deliberately not audited, being already self-verifying). Original finding: Subcommand parsers use an `if`/`else if` chain with **no final `else`**, so an unknown argument is silently dropped and execution falls through to the action: `zephem std --help` performs a full map regeneration, `zephem depth --help` starts the multi-minute L5 sweep. Confirmed by reading `src/cmd/{std,depth}.zig`. Full writeup, with the suggested fix, in [docs/upstream-zephem-B9.md](docs/upstream-zephem-B9.md). zcanon is immune because `src/zephem.zig` reads the TSVs directly and never invokes the binary. |

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

### Measured false-positive rates on Zig's own std (550 files)

Recorded rather than asserted, before and after the P0/P1 pass. Any regression here is a failed
fix. R012's single hit is a TRUE positive and must survive.

| Rule | Before | After |
|---|---|---|
| R001 async/await | 13 (8 on `Io.zig` alone), all error-severity | **0** |
| R008 acquire/release | 41 | **10** |
| R012 arity | 1 (true positive) | **1** (same true positive) |
| R013 unknown std path | 219 | **3**, and now opt-in |

R008's remaining 10 were not individually triaged; the categories fixed were type definitions
(B1), `[]const u8` (B10), file-global name matching, and ownership transfer via `return`.

### Deferred — small, known, not urgent

Recorded so they are not rediscovered from scratch. None of these block anything.

| # | Item | Why it was left |
|---|---|---|
| D1 | **10 R008 and 7 R006 warnings on Zig's std, never individually triaged.** R008 is down from 41; the four fixed categories were type definitions, `[]const u8`, file-global name matching, and ownership transfer via `return`. R006 was never measured before this audit. | Unknown mix of real findings and remaining heuristic noise. Both are `(heuristic)`-labelled rules. Worth a look only if either starts feeling untrustworthy in daily use. |
| D2 | **No automated parity harness against the old Nushell hook.** | Its value dropped once the divergences were catalogued: three of the four are *deliberate* improvements (`note:` lines kept, colon paths parsed, missing-zsnag reported), and the accidental one (missing dedup) is now fixed and unit-tested. A harness would mostly assert the deliberate differences. |
| D3 | `R012`'s single hit on std — `lib/std/debug/cpu_context.zig:51` calls `std.mem.reverse(native.r[0..])` with one argument against a two-parameter signature — **is a real bug in Zig's standard library** and has not been reported upstream. | It sits in a comptime-dead loongarch64 branch, so it never compiles in practice. Still a genuine defect, and the first concrete instance of the "give back to Zig" goal below. |
| D5 | **zsnag has found 4 genuine dangling references in Zig's own standard library.** All are in code paths Zig's lazy analysis never reaches, so they compile fine. Unreported upstream. `http/Client.zig:1483` uses `std.posix.SocketError` and `std.posix.ConnectError` in `ConnectUnixError`; neither is declared anywhere in `posix.zig` (they live on `Io.net`, leftovers from the posix→Io migration). `debug.zig:1803` calls `std.fmt.invalidFmtError`, which is declared at `Io/Writer.zig:1802`, not in `fmt.zig`. Plus D3's `std.mem.reverse` arity bug. | Supersedes the earlier note that R013's remaining hits were gaps in the zephem map — they are not. Checked against std source directly. |
| D4 | `@intCast` advisories (R007) remain on two guarded casts in `src/`. | Both are range-checked on the line above. Suppressing them would hide the rule's only true signal; leaving them costs two lines of output. |

### Checking this tool without reading its source

The most valuable technique in the 2026-08-10 audit was **counting against a large body of
known-good code** rather than reasoning about correctness. Zig's own standard library is 550
files that are, by definition, correct.

```sh
STD=$(zig env | grep -oP '\.std_dir\s*=\s*"\K[^"]+')
cd "$STD" && find . -name '*.zig' -print0 \
  | xargs -0 -n 150 "$ZCANON_HOME/zig-out/bin/zsnag" 2>/dev/null \
  | grep -oP '\[R\d+ (error|warn|info)\]' | sort | uniq -c | sort -rn
```

**A raw total is the wrong metric** — most rules fire legitimately on std, and reading the
total as "false positives" would be exactly the kind of unsupported claim this audit existed to
catch. Split the rules by what a hit actually means:

| Rule | Baseline 2026-08-10 | A hit on std means |
|---|---|---|
| **R001** async/await | **0** | **a bug in zsnag.** Modern std cannot contain stale keyword syntax. Must stay 0. |
| **R012** arity | **1** | **a bug somewhere.** This one is real — see D3. Should stay ≈0. |
| **R013** unknown path | **3** (opt-in) | **a dangling reference.** Verified 2026-08-10: all 3 are real stale references in Zig's own std, not map gaps — see D5. |
| R008 acquire | 10 | heuristic — mixed. Watch the number; a jump means a regression. |
| R006 stream | 7 | heuristic, never triaged. Same. |
| R011 deprecated | 409 | **correct.** std has not migrated its own call sites off its own deprecated APIs. |
| R004 / R005 | 328 / 131 | **correct.** std really does use `catch unreachable` and empty `catch {}`. |
| R007 / R010 / R009 | 3542 / 44 / 12 | advisory by design; std casts, prints and uses `page_allocator` constantly. |

So: **R001, R012 and R013 are the honesty check** — they claim something is impossible or absent,
so a hit is a defect in the tool, in Zig, or in the map. The heuristics (R006, R008) are watched
for movement, not for zero. The rest are working as designed and their counts mean nothing.

Two habits from the same audit, worth keeping:

- **Measure, do not assert.** Every claim made from a small sample during the port turned out
  false in general ("byte-identical parity", "R012 fires zero times", "R013 is low-noise") —
  each was true of the handful of files actually tested. Sample size is the question to ask.
  This table itself is a case in point: the first version of it quoted "11 findings" because it
  counted only four rules, and would have read as a 400× regression the moment anyone ran the
  real command.
- **Prove a fix by deleting the workaround, not by adding a test.** B1/B10 were proven fixed by
  removing the `zsnag:ok` suppressions they had forced into `src/book.zig` and
  `src/test/settings_test.zig` and requiring the tree to lint clean without them. A test written
  to match one's own fix proves much less.

Two habits from the same audit, worth keeping:

- **Measure, do not assert.** Every claim made from a small sample during the port turned out
  false in general ("byte-identical parity", "R012 fires zero times", "R013 is low-noise") —
  each was true of the handful of files actually tested. Sample size is the question to ask.
- **Prove a fix by deleting the workaround, not by adding a test.** B1/B10 were proven fixed by
  removing the `zsnag:ok` suppressions they had forced into `src/book.zig` and
  `src/test/settings_test.zig` and requiring the tree to lint clean without them. A test written
  to match one's own fix proves much less.

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
