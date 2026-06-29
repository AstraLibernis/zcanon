# zforge — how the pieces tie together

## The goal

A portable pack that, installed next to an LLM, makes it write current, correct Zig
immediately — and that can grow toward feeding real data back to the Zig project itself.
The LLM writes the code and does the reasoning; zforge controls **what the model knows at
the moment it writes**. That is the only lever (the model is stateless — its output is
decided entirely by what is in its context), so everything here is about getting the
right facts and checks in front of it at the right time.

## The flow

```
                         ┌─────────────── the model writes/edits Zig ───────────────┐
                         │                                                            │
   BEFORE writing        │   the SKILL tells the model to:                            │
   ──────────────        │     • zmap find <keywords>     → discover the current name │
                         │     • zfact <Symbol>           → exact signature + variants │
                         │                                                            │
   AFTER an edit         │   the HOOK fires automatically:                            │
   ─────────────         │     • zig ast-check  → syntax/compile errors               │
                         │     • zsnag          → known LLM footguns                   │
                         │   findings are injected back into the model's context      │
                         └────────────────────────────────────────────────────────────┘

   GROUND TRUTH:  the installed std (read live by zfact) + the compiler + your tests
```

Two tools = two moments:
- **zfact** is *foresight* — consult before/while writing so the first draft is right.
- **zhook** (running zsnag + ast-check) is the *safety net* — catches what slipped through,
  right after the edit, with no need to remember.

Ground truth is never the model's memory: `zfact` reads the std on disk, and the compiler
and tests judge correctness.

## The keystone: the skill

The tools are equipment; `skill/SKILL.md` is what makes the model *reach for them every
session, in any project, without being told*. Without it, the tools sit unused (the same
trap that kills any tool that depends on discipline). The skill is therefore the piece
that turns "a few scripts on disk" into "install once, better Zig everywhere."

Install paths for the skill (pick one):
- copy/symlink `skill/SKILL.md` into `~/.claude/skills/zforge/SKILL.md` (global), or
- reference it from a project's `CLAUDE.md`.

## Roadmap

**Done**
- `zfact` (Zig) — current-API lookup + neighborhood cluster (variants, cross-refs, efficiency)
- `zsnag` (Zig) — 10 verified LLM-mistake rules, tokenizer-based; validated on real third-party code
- `zmap` (Nushell) — deterministic reader over zephem's complete std map: keyword `find`, `show` a module, `doc` a path (replaced the removed embedding/pgvector search)
- `zhook` (Nushell) — automatic, reversible PostToolUse checker; **logs every finding to the book**
- `zbook` (Nushell) — reads the book (`zig_log`): real mistakes ranked by frequency
- `skill/SKILL.md` — the behavioral instruction

**The book (why, and why NOT synthetic).** We considered generating flawed Zig — from a
script, then from a small local model — and mining the failures. Both are dead ends for
the actual goal: a script only reproduces flaws we wrote into it, and a small model makes
*its* mistakes ("doesn't understand the language"), not the deployment model's ("this API
moved since training"). Wrong mistakes → noise. The correct generator already exists: the
hook, running on real edits by the real model. So `zhook` now records every finding to
`zig_log` with the offending source line, and `zbook` reads it back. Frequency is the
signal — no synthesis, judged by the compiler. Honest limit (unchanged): this never makes
the model reason better; it turns accumulated real findings into better *context* (which
APIs to surface in the skill, which `zsnag` rules earn their keep).

**Next (in rough order of value)**
1. **Accumulate the book on real work**, then read it: the most frequent rules/APIs become
   a short cheat-sheet baked into `skill/SKILL.md`, shifting correction from reactive
   (hook catches me) to proactive (skill warns me first).
2. **Harden the skill** — tune the wording so the model reliably uses the tools without
   over-calling them. Measure by dogfooding on real Zig tasks.
3. **Precise `zsnag` (full-AST version)** — `zsnag` already uses the real Zig tokenizer;
   upgrade the heuristic rules (R006/R008) to `std.zig.Ast` (the parse tree) to cut the
   last text-pattern false positives.
4. **Bundle as one installable unit** — a single installer that wires tools + hook + skill
   + book in one step, so "copy home, settle on Claude" is literally one command.

**Stretch — give back to Zig**
The book accumulates data on which mistakes are most common and where the compiler's error
messages are cryptic. That is a concrete, grounded contribution to the Zig project:
**propose clearer compiler diagnostics upstream**, backed by frequency data. (Not
"AI auto-fixes Zig" — that is a research problem, not a promise.)

## Honest ceiling

zforge makes the model **current and self-checking**, not a better reasoner. It removes
the dominant failure (stale API knowledge) and catches known traps. Novel logic bugs are
still caught only by the compiler, your tests, and the model's own reasoning — zforge
feeds those, it does not replace them.
