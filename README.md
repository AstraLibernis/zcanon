# zcanon

> **Currently built for [Claude Code](https://claude.com/claude-code) only.** The automatic
> hook, `zcanon setup` and the skill all target Claude Code. Other AI coding tools are not
> supported yet.

A **Zig-mistake guard for an LLM**. Install it next to Claude Code
and it catches the errors an LLM tends to make in Zig — removed builtins, footguns, leaks —
the moment they're written, and logs them so the recurring ones can be pre-empted.

It is **not** a linter you run for its own sake, and **not** a replacement for the Zig
compiler. It is plumbing: tools that put self-checks in front of the model right after it
writes code. The model still does the writing and the reasoning; zcanon removes a class of
sabotage — the small set of traps an LLM falls into repeatedly in a fast-moving language.

> **Companion: [zephem](https://github.com/AstraLibernis/zephem).** The *other* half of
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
| `zig-out/bin/zcanon` | The PostToolUse hook (`zsnag` + `zig ast-check` on every `.zig` edit, including ones a Bash command made, findings fed back to the model and logged to the book), plus install/uninstall and the book reader | Claude Code |
| `skill/SKILL.md` | The instruction that makes the model actually *reach for* the check every session | Claude Code |

The **book** is single-user local state in **one TSV** (`~/.config/zcanon/book.tsv`, override
`$ZCANON_BOOK`) — auto-created on first write. It records what the model *actually* gets wrong
on real edits, judged by the compiler — no synthetic generation. Findings are deduped on
`(file, rule, message, snippet)`, deliberately excluding line/col so a finding survives edits
that shift it; each save re-scans the whole file, so anything fixed is pruned and `hits` counts
real recurrences rather than repeated saves.

## Install

You need [Zig 0.16.0](https://ziglang.org/download/) on your PATH, and the companion
[zephem](https://github.com/AstraLibernis/zephem) cloned **next to** zcanon:

```sh
git clone https://github.com/AstraLibernis/zephem.git
git clone https://github.com/AstraLibernis/zcanon.git
cd zcanon
zig build
zig-out/bin/zcanon setup
```

`zcanon setup` is the whole install. It works in three steps and stops at the first problem,
printing the exact command that fixes it:

1. **zephem** — finds your zephem checkout (beside zcanon, or `$ZEPHEM_HOME`) and records where
   it is, so nothing needs an environment variable afterwards; builds zephem if needed; checks
   its std map is pinned to the Zig on your PATH; bakes and loads the lookup table.
2. **Claude Code** — checks zsnag was built, and that Claude Code's `settings.json` (in
   `~/.claude`, or `$CLAUDE_CONFIG_DIR`) is valid JSON in a writable directory. zcanon never
   rewrites a settings file it cannot parse.
3. **The hook** — installs it (backing up `settings.json` first, touching nothing but its own
   entry), switches it on, then **proves it works**: it reads the command back from
   `settings.json`, runs it through a shell exactly as Claude Code will, on a probe file with
   one known problem per check. It only reports success if the core rules, the zephem map
   rules and `zig ast-check` all fire. Finally it installs the skill with this machine's real
   paths filled in.

Run it again at any time; it only changes what is wrong. `zcanon doctor` runs the same checks
and changes nothing, so it is the first thing to try if findings ever stop appearing.

### Other AI tools

Not supported yet: zcanon is built for Claude Code only. The hook speaks Claude Code's
PostToolUse protocol and `zcanon setup` installs into Claude Code's settings. The checks
themselves can still be run by hand on any file:

```sh
zig-out/bin/zcanon check path/to/file.zig    # exit 0 clean, 1 something blocking, 3 unreadable
```

It prints the findings in the same grouped form the hook feeds Claude, and records them to the
same book. Wiring it into another tool automatically is up to you for now.

### Day to day

```sh
zig-out/bin/zcanon book              # the real mistakes the hook caught, ranked by frequency
zig-out/bin/zcanon book recent 20    # newest findings
zig-out/bin/zcanon book files        # per-file roll-up
zig-out/bin/zcanon book R004         # detail for one rule
zig-out/bin/zsnag yourfile.zig       # the linter alone
zig build test                       # unit tests + the end-to-end CLI tests
```

`zcanon disable` / `zcanon enable` switch the hook off and on without touching settings;
`zcanon prune` drops findings for files that no longer exist.

### Uninstall

```sh
zig-out/bin/zcanon uninstall            # remove the hook and the skill, keep your book of findings
zig-out/bin/zcanon uninstall --purge    # also delete ~/.config/zcanon (the book, zephem's location)
```

It removes only what `setup` put outside the checkout, then re-reads everything to confirm it is
gone:

| Where | What | Removed by |
|---|---|---|
| `~/.claude/settings.json` | zcanon's hook entry only; your other settings and hooks are untouched | `uninstall` |
| `~/.claude/skills/zcanon/` | the skill, and `SKILL.md.bak` if setup made one (only if they are zcanon skills) | `uninstall` |
| `~/.config/zcanon/` | the book of findings and the recorded zephem location | `uninstall --purge` |

It leaves `settings.json.bak` (a copy of your own settings) and never touches zephem, which is
its own project. Then delete the zcanon folder, and restart any open Claude Code session.

**Windows:** the same commands work in PowerShell with `zig-out\bin\zcanon.exe`. Claude Code
runs hooks through Git Bash there, so the installed command uses forward slashes and quotes
its path. This build is cross-compiled and unit-tested, but has not yet been run on a real
Windows machine; `zcanon doctor` is the first thing to try if anything misbehaves.

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
src/test/       unit tests, out-of-line, one <mod>_test.zig per module
src/test/cli/   end-to-end tests that spawn the REAL binaries in a sandbox
                (settings and book redirected via env; HOME deliberately unset)
sql/            schema_zig_log.sql — the book's column set (historical; the book is TSV now)
skill/          SKILL.md — the instruction that wires the check into how the model writes Zig
test_fixtures/  smoke + false-positive regression fixtures
docs/archive/   notes on removed components (zfact, the pgvector search)
PLAN.md         how the pieces tie together + roadmap + bug ledger
```

Verified against Zig 0.16.0, 2026-08-10. Pure Zig: no Nushell, no sqlite3, no database server —
the book is one TSV. Std discovery/lookup lives in the companion zephem.

## License

GPL-3.0-or-later · Copyright (C) 2026 AstraLibernis

zcanon is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See `LICENSE`.

Versions up to and including commit `bdfcaee` were released under the MIT License; copies obtained under those terms keep them.

Contributions are welcome under the [Developer Certificate of Origin](https://developercertificate.org/): sign off each commit with `git commit -s`. You keep the copyright on your contribution.
