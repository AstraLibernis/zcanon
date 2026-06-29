# zforge

A portable **Zig-competence pack for an LLM**. Drop it next to Claude (or any coding
agent) and it writes *current, correct* Zig immediately — by keeping the model grounded
in the real installed standard library and catching the mistakes an LLM tends to make.

It is **not** a linter you run for its own sake, and **not** a replacement for the Zig
compiler. It is plumbing: tools that put ground truth and self-checks in front of the
model at the moment it writes code. The model still does the writing and the reasoning;
zforge removes the thing that usually sabotages it — stale knowledge of a fast-moving
language.

## Why it exists

An LLM writes broken Zig mostly for one reason: its training is out of date, and Zig's
standard library changes fast. The model confidently calls APIs that moved or were
removed. zforge attacks that directly — it reads *this machine's* std as the source of
truth, never the model's memory.

## The pieces

The tools that read and judge Zig source are written **in Zig** (the project dogfoods
itself); the glue — reading the map and keeping the log — is written **in Nushell**.
No database server, no embedding models: the two Zig binaries read live std, and the
Nushell tools read plain files (zephem's std map + one sqlite log).

| Tool | Lang | Job | Needs |
|------|------|-----|-------|
| `zig-out/bin/zfact` | Zig | Look up the **current** signature of a std symbol + its neighborhood (variants, cross-refs, efficiency notes) | nothing (reads local std) |
| `zig-out/bin/zsnag` | Zig | Flag the **10 mistakes an LLM makes** (removed APIs, footguns, leaks) | nothing |
| `nu/zmap.nu` | Nushell | **Read the complete std map** — keyword `find`, `show` a module, `doc` a path. Deterministic discovery over the 100%-mapped truth | zephem's std map (TSVs) |
| `nu/zhook.nu` | Nushell | Run `zsnag` + `zig ast-check` on every `.zig` edit, feed findings back to the model, **and log them to the book** | Claude Code (+ sqlite for the book) |
| `nu/zbook.nu` | Nushell | Read **the book** — the corpus of real mistakes the hook captured live, ranked by frequency | sqlite (one local file) |
| `skill/SKILL.md` | — | The instruction that makes the model actually *reach for* these every session | Claude Code |

Discovery ("what's it called?") is **deterministic keyword search over the complete,
verified std map** that [zephem](https://codeberg.org/AstraLibernis/zephem) extracts —
not a fuzzy semantic search. The map has every name, signature, and doc, so a keyword
hit is never missed and never mis-ranked; the LLM supplies the meaning by choosing the
mechanism words. (The old embedding/vector search — postgres+pgvector+ollama — was
removed: a weak embedding model is worse than letting a capable LLM search the full
map.) The **book** (`zig_log`, written by `zhook`, read by `zbook`) is single-user
local state in **one sqlite file** (`~/.config/zforge/book.db`, override
`$ZFORGE_BOOK`) — no server, auto-created on first write. It records what the model
*actually* gets wrong on real edits, judged by the compiler — no synthetic generation.

## Install

```sh
git clone https://codeberg.org/AstraLibernis/zforge.git
cd zforge
zig build                              # builds zig-out/bin/{zfact,zsnag}

# 1. always-on tools work immediately:
zig-out/bin/zfact Io.Reader.stream
zig-out/bin/zsnag yourfile.zig

# 2. the auto-checker hook (reversible — see below):
nu nu/zhook.nu --install   # adds a PostToolUse hook to ~/.claude/settings.json (backs up first)

# 3. read the complete std map (needs zephem's TSVs; set $ZEPHEM_DATA if not default):
nu nu/zmap.nu find hash password       # keyword search the whole map
nu nu/zmap.nu show std.crypto.pwhash   # browse a module

# 4. the book — log real mistakes the hook catches, then read them back:
#    (no setup: the hook auto-creates ~/.config/zforge/book.db on first .zig edit)
nu nu/zbook.nu                         # table of contents, ranked by frequency
```

The hook is fully reversible: `nu nu/zhook.nu --disable` / `--enable` toggle it with no
settings change; `--uninstall` removes only our entry and leaves the rest of your settings
intact.

## What it does and does not do

- **Does:** keep API usage current, surface the best variant, catch known footguns, run
  the compiler's syntax check on every edit, and find APIs by concept.
- **Does not:** make the model reason better, judge your algorithm, or guarantee
  correctness. The compiler and your tests remain the real safety net; zforge keeps the
  model from being confidently wrong about the API surface.

## Status

Tools built and tested (`nu nu/test.nu`). Validated on real third-party Zig
(zls, zig-clap, http.zig). The keystone that turns the tools into a true "install once,
better Zig everywhere" pack — the skill in `skill/SKILL.md` — and the longer roadmap are
in `PLAN.md`.

## Layout

```
src/      the Zig tools (zfact.zig, zsnag.zig) + build.zig
nu/       the Nushell glue (zmap, zhook, zbook, test, lib)
sql/      schema_zig_log.sql — the sqlite book
skill/    SKILL.md — the instruction that wires the tools into how the model writes Zig
test_fixtures/  smoke + false-positive regression fixtures
docs/     component notes
PLAN.md   how the pieces tie together + roadmap
```

Verified against Zig 0.16.0 / Nushell 0.113.1, 2026-06-29. No database server and no
embedding models: discovery reads zephem's std map, the book is one sqlite file.
