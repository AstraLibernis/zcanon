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
itself); the glue that talks to ollama and postgres is written **in Nushell**.

| Tool | Lang | Job | Needs |
|------|------|-----|-------|
| `zig-out/bin/zfact` | Zig | Look up the **current** signature of a std symbol + its neighborhood (variants, cross-refs, efficiency notes) | nothing (reads local std) |
| `zig-out/bin/zsnag` | Zig | Flag the **10 mistakes an LLM makes** (removed APIs, footguns, leaks) | nothing |
| `nu/zfind.nu` | Nushell | Find an API **by concept** when you don't know the name (semantic search, with query rephrasing) | ollama + postgres index |
| `nu/zindex.nu` | Nushell | Build the semantic search index (`sql/schema_zig_api.sql`) via `zfact --dump` | ollama + postgres |
| `nu/zhook.nu` | Nushell | Run `zsnag` + `zig ast-check` automatically when a `.zig` file is edited, and feed findings back to the model | Claude Code |
| `skill/SKILL.md` | — | The instruction that makes the model actually *reach for* these every session | Claude Code |

The two Zig binaries need no dependencies and are always-current. `zfind`/`zindex` add an
optional semantic layer (local ollama embeddings + postgres/pgvector).

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

# 3. the optional semantic search layer:
psql ... -f sql/schema_zig_api.sql     # one-time table
nu nu/zindex.nu                        # build the index (needs `ollama serve`)
nu nu/zfind.nu "hash a password"
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

Tools built and tested (`nu nu/test.nu` — 26 checks). Validated on real third-party Zig
(zls, zig-clap, http.zig). The keystone that turns the tools into a true "install once,
better Zig everywhere" pack — the skill in `skill/SKILL.md` — and the longer roadmap are
in `PLAN.md`.

## Layout

```
src/      the Zig tools (zfact.zig, zsnag.zig) + build.zig
nu/       the Nushell glue (zfind, zindex, zhook, test, lib)
sql/      the semantic-index table schema
skill/    SKILL.md — the instruction that wires the tools into how the model writes Zig
test_fixtures/  smoke + false-positive regression fixtures
docs/     component notes
PLAN.md   how the pieces tie together + roadmap
```

Verified against Zig 0.16.0 / Nushell 0.99.1, 2026-06-15.
