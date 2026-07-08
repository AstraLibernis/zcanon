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

The tool that judges Zig source is written **in Zig** (the project dogfoods itself); the glue
— running it on each edit and keeping the log — is written **in Nushell**. No database
server: the log is one sqlite file.

| Tool | Lang | Job | Needs |
|------|------|-----|-------|
| `zig-out/bin/zsnag` | Zig | Flag the **10 mistakes an LLM makes** (removed APIs, footguns, leaks) | nothing |
| `nu/zhook.nu` | Nushell | Run `zsnag` + `zig ast-check` on every `.zig` edit, feed findings back to the model, **and log them to the book** | Claude Code (+ sqlite for the book) |
| `nu/zbook.nu` | Nushell | Read **the book** — the corpus of real mistakes the hook captured live, ranked by frequency | sqlite (one local file) |
| `skill/SKILL.md` | — | The instruction that makes the model actually *reach for* the check every session | Claude Code |

The **book** (`zig_log`, written by `zhook`, read by `zbook`) is single-user local state in
**one sqlite file** (`~/.config/zcanon/book.db`, override `$ZCANON_BOOK`) — no server,
auto-created on first write. It records what the model *actually* gets wrong on real edits,
judged by the compiler — no synthetic generation.

## Install

```sh
git clone https://codeberg.org/AstraLibernis/zcanon.git
cd zcanon
zig build                              # builds zig-out/bin/zsnag

# 1. the linter works immediately (reads the file you give it):
zig-out/bin/zsnag yourfile.zig

# 2. the auto-checker hook (reversible — see below):
nu nu/zhook.nu --install   # adds a PostToolUse hook to ~/.claude/settings.json (backs up first)

# 3. the book — log real mistakes the hook catches, then read them back:
#    (no setup: the hook auto-creates ~/.config/zcanon/book.db on first .zig edit)
nu nu/zbook.nu                         # table of contents, ranked by frequency
```

For **std lookup/discovery**, install the companion [zephem](https://codeberg.org/AstraLibernis/zephem)
and its skill — that's where `zlook`/`zmap` now live.

The hook is fully reversible: `nu nu/zhook.nu --disable` / `--enable` toggle it with no
settings change; `--uninstall` removes only our entry and leaves the rest of your settings
intact.

## What it does and does not do

- **Does:** catch known footguns, run the compiler's syntax check on every edit, feed the
  findings back to the model, and log the recurring ones.
- **Does not:** look up std APIs (that's zephem), make the model reason better, judge your
  algorithm, or guarantee correctness. The compiler and your tests remain the real safety
  net; zcanon keeps the model from repeating the traps it already knows to avoid.

## Status

Tools built and tested (`nu nu/test.nu`). Validated on real third-party Zig
(zls, zig-clap, http.zig). The keystone that turns the tools into a true "install once,
fewer Zig mistakes everywhere" pack — the skill in `skill/SKILL.md` — and the longer
roadmap are in `PLAN.md`.

## Layout

```
src/      the Zig tool (zsnag.zig) + build.zig
nu/       the Nushell glue (zhook, zbook, test, lib)
sql/      schema_zig_log.sql — the sqlite book
skill/    SKILL.md — the instruction that wires the check into how the model writes Zig
test_fixtures/  smoke + false-positive regression fixtures
docs/     component notes
PLAN.md   how the pieces tie together + roadmap
```

Verified against Zig 0.16.0 / Nushell 0.113.1, 2026-07-08. No database server; the book is
one sqlite file. Std discovery/lookup lives in the companion zephem.
