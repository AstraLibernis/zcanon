# zcanon

A portable **Zig-mistake guard for an LLM**. Drop it next to Claude (or any coding agent)
and it catches the errors an LLM tends to make in Zig — removed builtins, footguns, leaks —
the moment they're written, and logs them so the recurring ones can be pre-empted.

It is **not** a linter you run for its own sake, and **not** a replacement for the Zig
compiler. It is plumbing: tools that put self-checks in front of the model right after it
writes code. The model still does the writing and the reasoning; zcanon removes a class of
sabotage — the small set of traps an LLM falls into repeatedly in a fast-moving language.

> **Companion: [zephem](https://codeberg.org/AstraLibernis/zephem).** The *other* half of
> writing correct Zig — looking **up** the real std API (names, signatures, resolved types)
> so the model never writes them from memory — lives in zephem, which owns the std map and
> its query layer (`zlook`/`zmap`) plus its own LLM skill. zcanon is the *footgun + edit-check*
> half; install both. (The lookup layer used to live here; it moved to zephem so a change to
> the map's data contract can't break this pack.)

## Why it exists

An LLM writes broken Zig for two reasons: its std knowledge is stale (zephem's job), and it
falls into a handful of recurring traps — calling removed builtins, `catch unreachable`,
forgetting a `defer`. zcanon attacks the second: it runs a footgun linter and the compiler's
syntax check on every `.zig` edit, feeds the findings straight back to the model, and keeps a
log of what really goes wrong so the frequent mistakes can be surfaced proactively.

## The pieces

Everything is written **in Zig** (the project dogfoods itself) and built by Zig. Two binaries,
no runtime dependencies: no `nu`, no `sqlite3`, no database server. The log is one TSV.

| Tool | Job | Needs |
|------|-----|-------|
| `zig-out/bin/zsnag` | Flag the **13 mistakes an LLM makes** — 10 footgun/stale-knowledge rules, plus 3 checked against the real std via the companion zephem map | nothing (zephem optional) |
| `zig-out/bin/zcanon` | The PostToolUse hook (`zsnag` + `zig ast-check` on every `.zig` edit, findings fed back to the model and logged to the book), plus install/uninstall and the book reader | Claude Code |
| `skill/SKILL.md` | The instruction that makes the model actually *reach for* the check every session | Claude Code |

The **book** is single-user local state in **one TSV** (`~/.config/zcanon/book.tsv`, override
`$ZCANON_BOOK`) — auto-created on first write. It records what the model *actually* gets wrong
on real edits, judged by the compiler — no synthetic generation. Findings are deduped on
`(file, rule, message, snippet)`, deliberately excluding line/col so a finding survives edits
that shift it; each save re-scans the whole file, so anything fixed is pruned and `hits` counts
real recurrences rather than repeated saves.

## Install

```sh
git clone https://codeberg.org/AstraLibernis/zcanon.git
cd zcanon
zig build                    # builds zig-out/bin/{zsnag,zcanon}
zig build test               # optional: run the unit tests

# 1. the linter works immediately (reads the file you give it):
zig-out/bin/zsnag yourfile.zig

# 2. the auto-checker hook (reversible — see below):
zig-out/bin/zcanon install   # adds a PostToolUse hook to ~/.claude/settings.json (backs up first)
zig-out/bin/zcanon status    # installed? enabled? zsnag present? book path?

# 3. the book — read back the real mistakes the hook caught:
zig-out/bin/zcanon book              # table of contents, ranked by frequency
zig-out/bin/zcanon book recent 20    # newest findings
zig-out/bin/zcanon book files        # per-file roll-up
zig-out/bin/zcanon book R004         # detail for one rule
```

For **std lookup/discovery**, install the companion [zephem](https://codeberg.org/AstraLibernis/zephem)
and its skill — that's where the std map lives, queried with `zephem look` / `zephem map`.

The hook is fully reversible: `zcanon disable` / `zcanon enable` toggle it with no settings
change; `zcanon uninstall` removes only our entry and leaves the rest of your settings intact.
`zcanon prune` drops findings for files that no longer exist.

## What it does and does not do

- **Does:** catch known footguns, run the compiler's syntax check on every edit, feed the
  findings back to the model, and log the recurring ones.
- **Does not:** look up std APIs (that's zephem), make the model reason better, judge your
  algorithm, or guarantee correctness. The compiler and your tests remain the real safety
  net; zcanon keeps the model from repeating the traps it already knows to avoid.

## Status

Tools built and tested (`zig build test`). Validated on real third-party Zig
(zls, zig-clap, http.zig). The keystone that turns the tools into a true "install once,
fewer Zig mistakes everywhere" pack — the skill in `skill/SKILL.md` — and the longer
roadmap are in `PLAN.md`, which also carries the open **bug ledger**.

## Layout

```
build.zig       the build (targets: zsnag, zcanon, test)
src/            the Zig sources — zsnag.zig (linter), zcanon.zig (hook + CLI),
                and the modules: hook, book, tier, settings, report, vars
src/test/       tests, out-of-line, one <mod>_test.zig per module
sql/            schema_zig_log.sql — the book's column set (historical; the book is TSV now)
skill/          SKILL.md — the instruction that wires the check into how the model writes Zig
test_fixtures/  smoke + false-positive regression fixtures
docs/archive/   notes on removed components (zfact, the pgvector search)
PLAN.md         how the pieces tie together + roadmap + bug ledger
```

Verified against Zig 0.16.0, 2026-08-10. Pure Zig: no Nushell, no sqlite3, no database server —
the book is one TSV. Std discovery/lookup lives in the companion zephem.
