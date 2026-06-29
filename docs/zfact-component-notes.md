# zfact

A zero-dependency **current-Zig-std API fact-checker**, built to fight one specific
failure mode: an AI (or a human) confidently using a `std` API that *changed*.
Zig's standard library churns fast; trained knowledge and old docs go stale. `zfact`
answers "what is the signature of this symbol **in the std installed on this machine**,
right now?" by reading the std source directly.

## What it does

Given a symbol query, it locates the matching `pub fn` / `pub const` / `pub var`
declarations in the local std source and prints, for each:

- preceding `///` doc comment(s)
- the exact declaration line
- `file:line` of the definition
- one hop of `@import` re-export / same-file alias resolution to the underlying signature

It then prints a **neighborhood cluster** (Layer A) so the caller builds *grouped*
knowledge instead of a single fact — the difference between "is this the right call?"
and "what's the best call for this?":

- **family** — name siblings sharing the camelCase stem (`append` → `appendSlice`,
  `appendAssumeCapacity`, `appendNTimes`, …)
- **see also** — identifiers the doc comment cross-references (`getOrPut`); these are
  ~4,400 author-curated links already present in std doc comments
- **notes** — efficiency signals: `*AssumeCapacity` (skips alloc check), `*Unmanaged`
  variants, and "use X instead" steers pulled from the docs

Pass `--sig` (or `-s`) to print signatures only and suppress the cluster (hook mode).

## Layer B — reading the complete std map (`zmap`, Nushell)

Layer A above is zero-dependency and exact, but answers only "I know the name." Layer B
adds discovery — finding an API **by concept when you don't know its name** — by reading
the **complete, verified std map** that [zephem](https://codeberg.org/AstraLibernis/zephem)
extracts (every name, signature, and doc, as plain TSVs). It is a Nushell tool
(`nu/zmap.nu`) because it reads files, not Zig source.

```
nu nu/zmap.nu find aead associated      # keyword search (AND of terms) over the whole map
nu nu/zmap.nu find "hash password"      # -> pwhash, strHash, ...
nu nu/zmap.nu show std.crypto.pwhash    # browse a module/subtree
nu nu/zmap.nu doc std.fmt.parseInt      # signature + doc for one path
```

`find` is a **deterministic keyword search** over every name, path, signature, and doc
in the map, ranked name-match-first. Because the map is complete and the match is
literal, a hit is never missed and never mis-ranked — `find parse int` returns
`fmt.parseInt` at the top. The LLM supplies the *meaning* by choosing the mechanism
words ("delimiter", "alloc", "hash"); if a search comes up empty, it rethinks the
wording and searches again.

This replaced an earlier embedding/vector search (ollama `nomic-embed-text` + pgvector).
That was removed deliberately: when the consumer is a capable LLM, a small embedding
model is a *worse* semantic layer than letting the LLM keyword-search the full map
itself — it confused "parse an integer from a string" with `Uri.parse`; keyword search
does not. The retired design is archived in `docs/archive/semantic-enrichment-guide.md`.

Honest scope: `find` matches *literal* substrings, so a true synonym with no shared word
("make text loud" vs `toUpper`) won't hit — that is the LLM's job to rephrase and retry.
The reliable flow stays **`zmap find` to discover a name → `zfact <symbol>` for the
live, exact signature.**

## Usage

```
zfact Io.Reader.stream      # exact fn signature under Io/Reader
zfact ArrayList.append      # surfaces BOTH managed and unmanaged variants
zfact crypto.ChaCha20       # fuzzy: lists ChaCha20IETF, ChaCha20Poly1305, ...
zfact crypto.ChaCha20IETF   # follows @import to the real definition
zfact fs.File.openFile      # stale namespace: widens std-wide and flags it
```

The std location is auto-detected via `zig env`; override with `ZFACT_STD=/path/to/std`.

## How resolution works (and its limits)

Resolution is **textual (grep over std source), not semantic.** It is deliberately
zero-dependency — no ZLS, no compiler introspection.

- **Scoping:** namespace parts of the query (e.g. `Io.Reader`) select candidate files
  (`Io.zig`, `Io/`, snake_case variants). A bare symbol searches std-wide.
- **Fuzzy fallback:** if no exact-named decl is found, it matches declarations whose
  name *contains* the query (e.g. `ChaCha20` → `ChaCha20IETF`), and says so.
- **Widening:** if a scoped query finds nothing, it retries std-wide and flags that the
  namespace may be stale — itself a useful signal that the API moved.
- **One-hop resolution:** follows `= @import("...").Member` and same-file `= Base`
  aliases a single hop; it does **not** recurse further.

Known limits: cannot follow multi-hop re-export chains; cannot disambiguate
identically-named symbols semantically; relies on `pub` declarations being grep-shaped
(true for current std). It reports *candidates*, not a guaranteed single answer.

## Testing

`nu nu/test.nu` runs the smoke battery against the installed std — it builds the Zig
tools, exercises zfact/zsnag, and (if zephem's map is present) zmap. Expected signature
substrings are version-specific and must be updated when Zig's std changes.

## zsnag — the LLM footgun checker

`zfact` keeps API knowledge current; `zsnag` catches the *mistakes* an LLM makes writing
Zig. It reads `.zig` files and flags 10 specific patterns, each verified against the
installed std (so it doesn't flag things that are actually still valid):

```
zsnag file.zig            # human-readable
zsnag --json file.zig     # machine-readable (for a hook)
```

The 10 rules, by confidence:

- **Removed from the language/std (certain):** `async`/`await` (R001), `usingnamespace`
  (R002), `std.mem.copy`/`set` (R003)
- **Footguns — compiles but behaves wrong:** `catch unreachable` (R004), empty `catch {}`
  (R005), `stream()==0` treated as end-of-stream (R006), casual `@intCast`/`@ptrCast`/
  `@alignCast` (R007)
- **Smells — usual LLM tells:** acquire without release / no `deinit`/`close` (R008),
  `page_allocator` as the default allocator (R009), leftover `debug.print` (R010)

Exit code is non-zero if any `error`-severity finding is present (so it can gate CI/a hook).

Honest limits: `zsnag` is written in Zig and runs the **real Zig tokenizer**, so strings,
comments, and identifier boundaries are handled structurally (not by regex) — e.g. a
method named `.async()` is correctly *not* flagged, because R001 checks the token before
it. It is not yet a full parser. R006 and R008 are heuristics (they look at nearby tokens
/ the whole token stream), so they favor precision over completeness: R006 only flags the
one-line `if (n==0) break;` form; R008 only fires for an allowlist of types that actually
have a `deinit` (ArrayList, HashMap, ArenaAllocator, …) plus `openFile`/`createFile`→
`close`. R004 (`catch unreachable`) and R007 (casual casts) are correct but high-volume —
they are "review these" flags, not "these are bugs." The precise version would use Zig's
real parse tree (`std.zig.Ast`) on top of the tokens — a later upgrade.

Validated on real third-party code (zls, zig-clap, http.zig, ~6.5k lines): the first pass
surfaced two false-positive classes (method-named `async`/`await`; `init()` of types with no
`deinit` like `FixedBufferAllocator`), both since fixed and locked by a regression test.

## Status

- **zsnag — LLM footgun checker (10 rules):** done, tested (no false positives on the good fixture).
- **Phase 1 — L2 lookup engine:** done, tested.
- **Layer A — neighborhood cluster** (family / see-also / efficiency notes): done, tested.
- **Layer B — map reader** (`zmap`): done. Deterministic keyword `find` / `show` / `doc`
  over zephem's complete, verified std map. Replaced the removed embedding/pgvector
  search (archived in `docs/archive/`).
- **Phase 2 — Claude Code hook** (`zhook`, `PostToolUse` on `.zig` edits → `zsnag` +
  `ast-check`, findings injected back + logged to the sqlite book): done, reversible, installed.
- **Implementation:** `zfact`/`zsnag` are Zig (they read and judge Zig source);
  `zmap`/`zhook`/`zbook`/`test` are Nushell (map + sqlite glue — no server, no models).

Verified against: Zig 0.16.0 / Nushell 0.113.1, std at `/usr/local/zig/lib/std`, 2026-06-29.
