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

## Layer B — semantic search (`zfind`, Nushell)

Layers A above are zero-dependency and exact. Layer B adds the one thing structure
cannot: finding an API **by concept when you don't know its name**. It is a Nushell
tool (`nu/zfind.nu`) because it is ollama + postgres glue, not Zig-source analysis.

```
nu nu/zfind.nu "authenticated encryption with associated data"   # -> ChaCha20Poly1305, ...
nu nu/zfind.nu "hash a password securely"                        # -> pwhash, strHashWithSalt
nu nu/zfind.nu "read until a delimiter" --limit 5
```

It embeds the query with ollama `nomic-embed-text` and cosine-ranks it against an
index of std declarations (pgvector). This needs **ollama running** and the index
built; the pure-lookup commands do not.

### Building the index

```
psql ... -f schema_zig_api.sql   # one-time: create the table
nu nu/zindex.nu            # documented decls only (~24% of std, higher signal)
nu nu/zindex.nu --all      # include undocumented decls too (~4x larger, slower)
```

`zindex` gets its declarations from the Zig binary (`zfact --dump`), then embeds and
upserts them — extraction stays in Zig, glue stays in Nushell. The index is a
**derived, version-stamped cache** in the `zig_api` table — the installed std remains
the source of truth. `zfind` refuses to answer (and tells you to rebuild) if the index
version != the installed Zig version, so it can never silently serve stale results.
Re-run `nu nu/zindex.nu` after any Zig upgrade.

### The vocabulary gap, and the rephrase bridge

std docs describe the *mechanism* ("read from the stream until `delimiter` is found"),
not the *use case* ("a line from stdin"). A raw embedding search is therefore
vocabulary-sensitive: "read bytes until a delimiter" hits the right `streamDelimiter`
family, but "read a line from stdin" used to return formatting functions.

`find` fixes this by **rephrasing the query before embedding** — a local reasoning
model (`qwen2.5-coder:3b`) translates use-case wording into mechanism keywords, *then*
the embedding search runs. Reasoning in front of similarity:

```
nu nu/zfind.nu "read a line of text from stdin"
  rephrased → "read characters from input stream until newline delimiter"
  → Io.streamDelimiter, streamDelimiterLimit, discardDelimiterExclusive   ✓
```

Pass `--raw` to skip the rephrase when your query is already mechanistic (e.g. an LLM
caller that phrased it well) — saves the ~3s model call.

Honest scope: ranking is still approximate (it ranks the *neighborhood*, not a
guaranteed #1), and the rephrase adds a local-model dependency + latency. The reliable
backbone remains the exact lookup — **`zfind` to discover a name → `zfact <symbol>` for
the truth.**

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

`nu nu/test.nu` runs the smoke battery (26 checks) against the installed std — it builds
the Zig tools, exercises zfact/zsnag, and (if ollama + the index are up) zfind. Expected
signature substrings are version-specific and must be updated when Zig's std changes.

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
- **Layer B — semantic search** (`zfind`, embeddings + pgvector): done. Derived,
  version-stamped, rebuildable index (`zindex`); live std stays the source of truth.
- **Phase 2 — Claude Code hook** (`zhook`, `PostToolUse` on `.zig` edits → `zsnag` +
  `ast-check`, findings injected back): done, reversible, installed.
- **Implementation:** `zfact`/`zsnag` are Zig (they read and judge Zig source);
  `zfind`/`zindex`/`zhook`/`test` are Nushell (ollama + postgres + hook glue).

Verified against: Zig 0.16.0 / Nushell 0.99.1, std at `/usr/lib/zig/std`, 2026-06-15.
`nu nu/test.nu` = 26 checks.
