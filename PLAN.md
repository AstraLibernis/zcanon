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
   ──────────────        │     • zfind "<concept>"        → discover the current name │
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
- `zfind` (Nushell) — semantic search with use-case→mechanism query rephrasing
- `zindex` (Nushell) — index builder, fed by `zfact --dump`
- `zhook` (Nushell) — automatic, reversible PostToolUse checker
- `skill/SKILL.md` — the behavioral instruction

**Next (in rough order of value)**
1. **Harden the skill** — tune the wording so the model reliably uses the tools without
   over-calling them. Measure by dogfooding on real Zig tasks.
2. **Precise `zsnag` (full-AST version)** — `zsnag` already uses the real Zig tokenizer;
   upgrade the heuristic rules (R006/R008) to `std.zig.Ast` (the parse tree) to cut the
   last text-pattern false positives.
3. **Generate→test→mine loop** — generate Zig with a model, compile/test it, and let the
   compiler/tests label the failures. The most common failures become new `zsnag` rules
   or `zfact` entries. This data-drives the rule set instead of hand-curation, and it is
   LLM-specific (it learns *the model's* mistakes, not humans').
   - Seeded by `nu/zgremlin.nu`: emits plausible-but-flawed Zig in three classes (mangled
     formatting, incorrect closing, logic dead-ends) and reports which checker catches each.
     It already pinpoints the target: formatting/structure errors are caught by
     `zig fmt`/`zig ast-check`, but **logic dead-ends slip past every existing checker** —
     that is the class the mine loop must learn to detect.
4. **Bundle as one installable unit** — a single `install.sh` that wires tools + hook +
   skill + index in one step, so "copy home, settle on Claude" is literally one command.

**Stretch — give back to Zig**
The mine loop produces data on which mistakes are most common and where the compiler's
error messages are cryptic. That is a concrete, grounded contribution to the Zig project:
**propose clearer compiler diagnostics upstream**, backed by frequency data. (Not
"AI auto-fixes Zig" — that is a research problem, not a promise.)

## Honest ceiling

zforge makes the model **current and self-checking**, not a better reasoner. It removes
the dominant failure (stale API knowledge) and catches known traps. Novel logic bugs are
still caught only by the compiler, your tests, and the model's own reasoning — zforge
feeds those, it does not replace them.
