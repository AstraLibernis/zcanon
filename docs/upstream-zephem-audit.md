# Upstream audit: zephem's CLI, query commands, and `sig` column

**Scope, and what was deliberately left out.** Three layers were audited, on 2026-08-10:
argument handling across every subcommand, the read-only query commands (`look`, `map`), and
the shape of the `sig` column. **zephem was not modified** — this is findings only.

The map data itself was **not** audited, on purpose. It already carries the strongest
verification in the toolchain: forward-vs-backward reconciliation of all 63,494 nodes, SHA256
manifests per dataset, `--check` modes, and byte-reproducible rebuilds (observed: a full
regeneration left `git status` clean). Re-auditing that would be the most work for the least
return. Every finding below sits in a layer that has *no* such verification.

Scale for context: ~3,230 lines in `src/` plus ~1,080 in the parse/reflect/derive engines,
against 10 unit tests and a 9-assertion smoke battery.

---

## 1. Argument handling — unknown arguments are silently discarded

Every subcommand parses its own flags with an `if / else if` chain and **no final `else`**. An
unrecognised argument is dropped and execution continues into the action.

| Subcommand | Unknown flag | Destructive if it proceeds |
|---|---|---|
| `std` | silently ignored | **yes** — full map regeneration |
| `depth` | silently ignored | **yes** — multi-minute L5 reflection sweep |
| `overlays` | silently ignored (see 1b) | **yes** — rewrites overlay TSVs + manifests |
| `docs` | silently ignored | **yes** — rewrites every generated `.md` |
| `lookup` | silently ignored | **yes** — rebakes `lookup.tsv` |
| `test` | ignored entirely — the parameter is `_` | mild — builds `lookup.tsv` if absent |
| `look` | becomes a **search term** | no |
| `map` | becomes the **subcommand name** or a positional | no |

Consequence, observed: `zephem std --help` performs a full regeneration; `zephem depth --help`
starts the sweep. Neither prints usage. No data is lost — the build is byte-reproducible — but a
help flag silently performing the most expensive destructive operation is a poor default for
anyone who does not already know.

### 1b. `overlays` with a mistyped name silently succeeds having done nothing

`cmd/overlays.zig`:

```zig
for (args) |arg| {
    if (std.mem.eql(u8, arg, "--check")) check = true
    else if (!std.mem.startsWith(u8, arg, "--")) only = arg;
}
…
for (all) |ov| {
    if (only) |o| if (!std.mem.eql(u8, o, ov.name)) continue;
```

`zephem overlays canonn` (a typo) sets `only = "canonn"`, matches no overlay, skips every
iteration, prints **nothing**, and exits **0**. The operator believes an overlay was rebuilt.
This is a distinct failure from the `--help` case: not "did something unexpected" but
"reported success having done nothing".

### Suggested fix

- A final `else` in each parse loop: unknown argument → usage, exit non-zero.
- Intercept `-h` / `--help` in `main.zig`'s dispatcher, before any subcommand runs.
- `overlays`: validate `only` against the known overlay names and fail if it matches none.
- Optionally, confirm before `std` / `depth` when stdout is a TTY — those are the two that
  cost real time.

---

## 2. Query commands — no failure signal, and silent truncation

### 2a. Every outcome exits 0

Measured across every query path:

| Invocation | Exit |
|---|---|
| `map doc std.fmt.parseInt` (hit) | 0 |
| `map doc std.mem.copy` (miss) | 0 |
| `map doc "!!!not-a-path!!!"` (garbage) | 0 |
| `map show std.notathing` (miss) | 0 |
| `map find zzzznomatch` (no matches) | 0 |
| `map` / `map bogus` (no or unknown subcommand) | 0 |
| `look zzzznomatch` (no matches) | 0 |
| `look` (no arguments) | 0 |
| **`look` with the lookup table entirely absent** | **0** |

The last row is the important one: a consumer cannot distinguish "no results" from "the tool is
not working". Any script or agent must parse prose to find out — and the prose is not a
documented contract.

### 2b. 797 entries are truncated with no marker

`zlook.zig:100` and `zmap.zig:242` are both `return if (s.len > max) s[0..max] else s;` — a raw
byte slice, no ellipsis, no flag. Resolved types are cut at 140 bytes, docs at 120.

**797 entries** in the current table have a resolved type longer than 140 bytes.

Worked example — `std.Build.RunError`, an error set:

```
what zephem shows:
  → error{AccessDenied,AntivirusInterference,BadPathName,Canceled,DeviceBusy,
    ExecNotSupported,ExitCodeFailure,FileBusy,FileLocksUnsupported,File

what is actually in the map:
  error{AccessDenied,…,Unexpected,UnrecognizedVolume,WouldBlock}   ← 41 members
```

**10 errors shown, 41 real.** The output stops mid-identifier (`File`) with no closing brace and
no indication anything was removed. A reader — human or model — who handles what they were shown
believes they have covered the error set. For a tool whose stated purpose is *"the single source
of std truth, no live-lookup fallback"*, silently showing a third of an error set is the most
consequential finding here.

### 2c. Latent UTF-8 splitting

The same byte-slice truncation can cut a multibyte character in half. **Currently it does not** —
scanned all docs over 120 bytes and found zero invalid cuts, so no live corruption. Latent only,
but it will surface the first time a multibyte character lands on the boundary.

### Suggested fix

- Distinct exit codes: 0 hit, 1 no match, 2 usage, and something non-zero for "no map at all",
  which today is indistinguishable from an empty result.
- Mark truncation (`…`), or better, do not truncate an error set or signature at all — those are
  the fields whose completeness is the entire point.
- Truncate on a codepoint boundary.
- Optionally a `--json` mode, which would remove the need to parse prose entirely.

---

## 3. The `sig` column carries prose

`sig` mixes the declaration signature with any `///` doc comments written *inside* the parameter
list. Of 11,273 signatures:

- **68** contain inline `///` prose — 58 from plain parameter doc comments, 10 from doc comments
  on the fields of an inline anonymous-struct parameter.
- **All 68 of those contain a comma inside the prose.**
- 5 more carry `//` line comments.

The comma matters because a signature's commas are how a consumer counts parameters.
`std.Io.Threaded.init` is a two-parameter function whose doc prose reads *"If these functions are
avoided, then `Allocator.failing` may be passed"* — count commas and you get three. This produced
a real false positive in zcanon (ledger B16), found by an adversarial reviewer rather than by
either project's tests.

**The placement is also inconsistent.** Of the 68, **39 have an empty `doc` column** — the prose
exists *only* inside `sig`, so a consumer reading the documented field gets nothing while the
signature field is polluted. The other 29 carry it in both.

This is arguably faithful capture rather than a bug: parameter-level docs genuinely are inside
the parameter list in source. But `sig` is the field consumers parse structurally, and it is the
one field where prose is most harmful.

### Suggested fix

Pick one, in order of preference:

1. **Strip `///` runs from `sig` at parse time** and route them to a new `param_doc` column.
   Preserves the information, cleans the field consumers parse.
2. Strip them from `sig` and drop them. Simplest; loses 39 entries' only copy of that prose.
3. Leave as-is and **document it** — state in the data contract that `sig` may contain `///`
   runs and that consumers must strip them before parsing. zcanon now does exactly this
   (`src/zephem.zig` `arityOf`), so at minimum the next consumer should not have to rediscover it.

---

## Summary

| # | Finding | Severity |
|---|---|---|
| 1 | Unknown args silently ignored; `--help` runs destructive subcommands | high for a new user, low once known |
| 1b | `overlays <typo>` reports success having done nothing | medium — silent no-op |
| 2a | Every query outcome exits 0, including "no map at all" | medium — no failure signal for consumers |
| 2b | 797 entries silently truncated; error sets shown at a third of their real size | **high** — teaches wrong facts |
| 2c | Truncation can split UTF-8 | low — latent, not currently triggered |
| 3 | `sig` carries `///` prose in 68 entries, all containing commas | medium — already misled one consumer |

Nothing here touches the map's correctness. The data reconciles, hashes, and rebuilds
byte-identically. Every finding is in the presentation and control layers around it.
