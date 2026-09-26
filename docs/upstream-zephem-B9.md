# Upstream: zephem silently ignores unknown flags, so `--help` runs the command

**Status:** logged, not fixed. This is a defect in [zephem](https://github.com/AstraLibernis/zephem),
not in zcanon. Recorded here because zcanon consumes zephem's map and had to work around it.
zcanon's ledger tracks it as **B9**.

**Found:** 2026-08-10, by an agent exploring zephem's CLI. It ran `zephem std --help` expecting
usage text and instead performed a full regeneration of the std map.

**Severity:** high for a first-time user, low for an informed one. No data was lost — the build
is byte-reproducible, so `git status` came back clean afterwards. But the failure mode is
"a help flag silently does the most expensive destructive thing the tool can do."

## What happens

```
$ zephem std --help
[forward]  scanning /…/lib/std/std.zig  (zig 0.16.0, depth 24)
           rows: 63494   files: 340   private: 7406
…rewrites data/std/extracted/*.tsv, PINNED, SHA256SUMS…
```

`zephem depth --help` is worse: it starts the L5 reflection sweep, which is minutes of work
across every container in std (killed at a 2-minute timeout when observed).

## Why

`src/main.zig` dispatches on `args[1]` and hands the remainder to the subcommand. Each
subcommand parses its own flags with an `if / else if` chain **that has no final `else`**, so an
unrecognised argument is silently discarded and execution falls through to the action.

`src/cmd/std.zig`:

```zig
pub fn run(c: Ctx, args: []const []const u8) !void {
    var check = false;
    var depth: u32 = 24;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--check")) {
            check = true;
        } else if (std.mem.eql(u8, args[i], "--depth")) {
            i += 1;
            if (i < args.len) depth = std.fmt.parseInt(u32, args[i], 10) catch depth;
        }
        // ← no else: "--help" lands here and is dropped
    }
    // … falls through to the full regeneration
```

`src/cmd/depth.zig` has the same shape — the loop closes after the last `else if`, then proceeds
straight to `rel.load(...)` and the sweep.

Affected the same way: `std`, `depth`, and by inspection the other action subcommands
(`overlays`, `docs`, `lookup`). The read-only query commands degrade more gracefully but still
misinterpret the flag — `zephem look --help` treats `--help` as a **search term**
(`no lookup entry matches: --help`), and `zephem map --help` reports `unknown map command`.

## Suggested fix

Two changes, independent:

1. **Reject unknown arguments.** Add a final `else` to each subcommand's parse loop that prints
   usage and exits non-zero. An unrecognised flag should never be silently dropped by a command
   that then writes to disk.
2. **Handle `-h` / `--help` explicitly**, per subcommand, before any work begins — the dispatcher
   in `main.zig` is the natural place to intercept it for all subcommands at once.

Optionally: make the destructive subcommands print what they are about to do and require
confirmation (or a `--yes`) when stdout is a TTY. `std` and `depth` are the two that cost real
time.

## Workaround in zcanon, already in place

`src/zephem.zig` never shells out to the `zephem` binary at all — it reads the TSVs directly.
That was chosen for other reasons (no JSON mode, query commands always exit 0, doc text is
byte-truncated), but it also means zcanon cannot trigger this bug. The module carries a comment
saying so, so nobody "simplifies" it back into a subprocess call:

> NEVER shell out to `zephem <sub>` with pass-through flags: unknown flags fall through to the
> subcommand's action, so `zephem std --help` performs a full map regeneration and
> `zephem depth --help` starts a multi-minute sweep (ledger B9).
