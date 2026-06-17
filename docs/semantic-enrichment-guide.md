# Guide: enriching the semantic index with gloss + tags

**Goal.** Make `zfind` (concept → symbol search) more accurate by adding, to each
indexed std symbol, a generated **use-case gloss** and **search tags**, then
embedding *those* alongside the signature/doc. The win is *targeted vocabulary*:
the search query and the symbol now share the words a programmer actually types.

**Status.** Validated on a small slice (see "Prototype result" below). This guide is
the plan to roll it out fully — intended to run **overnight on an accelerated
machine**, because the generation step is the expensive part.

---

## Prototype result (the evidence this is worth doing)

Run on the fedora-KDE VM (no GPU), 2026-06-17, via `nu/proto_tags.nu`:

- Slice: 48 `std.mem` free functions; 10 natural-language test queries.
- Metric: rank-weighted top-5 (a #1 hit = 5 pts … #5 = 1, a miss = 0), summed.
- **baseline 32 → enriched 44.** Three outright baseline *misses* became hits
  (`indexOfScalar`, `splitScalar`, `startsWith`); one #3 → #1; **zero regressions**
  on queries baseline already won.
- That score is a *lower bound*: the prototype had a parser bug (below) that left
  noise in the embedding text. Clean parsing should score higher.

Generation cost there: 48 symbols ≈ 9 min (~11 s/symbol on CPU). Extrapolated to the
full documented index (≈6,016 decls) that is **~19 hours on CPU** — hence "do it on
the accelerated box, overnight." With `--all` (undocumented too) it is ~4× larger.

---

## Prerequisites on the home machine

1. **Zig** installed (the same version you'll search against). Check: `zig version`.
2. **ollama with AMD acceleration (ROCm).**
   - Install ollama; on a supported AMD GPU it uses ROCm automatically.
   - Verify the GPU is actually used: run any model, then `ollama ps` — the
     PROCESSOR column should say `GPU` (or a GPU/CPU split), not `100% CPU`.
   - If it says CPU only, you gained nothing; fix ROCm before the overnight run.
   - Models needed:
     - `nomic-embed-text` — embeddings (768-dim). Already used by the index.
     - a small instruct model for glossing — `qwen2.5-coder:3b` worked well.
       A larger model (e.g. `qwen2.5-coder:7b`) may give cleaner tags if the GPU
       can afford it; bigger = slower, so weigh it.
   - `ollama pull nomic-embed-text qwen2.5-coder:3b`
3. **Postgres + pgvector**, with the std index already built:
   - `psql ... -f sql/schema_zig_api.sql`
   - `nu nu/zindex.nu` (builds `zig_api` for the installed Zig version)
   - Confirm: `SELECT zig_version, count(*) FROM zig_api GROUP BY zig_version;`
4. **zforge built**: `zig build` (gives `zig-out/bin/{zfact,zsnag}`).

---

## Step 1 — schema: add the new columns

Add to `zig_api` (idempotent):

```sql
ALTER TABLE zig_api ADD COLUMN IF NOT EXISTS gloss TEXT;
ALTER TABLE zig_api ADD COLUMN IF NOT EXISTS tags  TEXT[];   -- array, for filtering
-- fast tag filtering later (#3):
CREATE INDEX IF NOT EXISTS zig_api_tags_idx ON zig_api USING gin (tags);
```

Keep `tags` as `TEXT[]` (not a comma string) so the soft filter in Step 6 can do
`WHERE tags && ARRAY['memory']` cheaply.

---

## Step 2 — the generation prompt (and the parser fix)

For each symbol, ask the local model for a one-line gloss + 4–8 tags. The prototype
prompt is in `nu/proto_tags.nu` (`gloss-tags`). **Two fixes to apply before the big run:**

**(a) Stop the echoed-prefix leak.** The model sometimes returns
`Line 1 \`gloss:\` Checks if…`. Parse robustly: take the model's raw response, then
strip any leading `Line 1`, backticks, and a leading `gloss:` token before storing.
Same for tags. Sanity-check a few rows after a small batch — the stored `gloss`
should be a clean sentence with no `Line 1`/backtick litter.

**(b) Normalize tags** to a clean array: lowercase, trim, split on commas, drop
empties and duplicates. Store as a Postgres array literal `'{a,b,c}'`.

Recommended embedding text (what actually gets embedded), unchanged from the proto:

```
<symbol> (<kind>)
<signature>
<doc>
use: <gloss>
tags: <tag, tag, ...>
```

**Optional speedup — batch the prompt.** Generating one symbol per call dominates the
cost. Ask for ~10 symbols per prompt and have the model return one JSON object per
symbol (`[{symbol, gloss, tags}, …]`). That cuts generation calls ~10×. Trade-off:
multi-item prompts occasionally drop or mis-key an item — validate the returned
symbols against what you asked for and re-queue any misses. Worth it for 6,016 rows.

---

## Step 3 — make the run chaptered and resumable

This is what makes an overnight run safe (a crash at hour 6 shouldn't waste hours 1–5).

- **Chapter by namespace/file.** `zindex.nu` already takes `--module <substr>`. Do the
  same here: enrich one chapter at a time. Order by what you actually use first:
  `mem`, `fmt`, `fs`, `Io`, `heap`, `ArrayList`, `hash_map`, `json`, then the rest.
- **Resumable:** before generating, `SELECT` rows in the chapter where `gloss IS NULL`
  and only do those. Re-running the script then skips finished work for free.
- **Write incrementally:** `UPDATE zig_api SET gloss=…, tags=… WHERE id=…` per batch
  (or per symbol), not one giant commit at the end. Progress survives a crash.
- **Log:** `tee` stdout to a file so you can see in the morning where it got to and
  whether any chapters errored.

---

## Step 4 — re-embed with the enriched text

After a chapter's gloss/tags are filled, recompute that chapter's `embedding` from the
enriched text (Step 2 format). This mirrors `zindex.nu`'s embed-and-upsert loop; the
only change is the text fed to `embed`. Keep it version-scoped: only touch rows whose
`zig_version` matches the installed Zig.

> Two model passes happen here per symbol: one *generate* (gloss/tags, the slow one)
> and one *embed* (fast). Don't re-generate on a re-run — only re-embed if the text
> changed.

---

## Step 5 — run it overnight

Sketch (adapt to a finalized `nu` script — `proto_tags.nu` is the working starting point):

```sh
# hot chapters first, each resumable; log everything
for m in mem fmt fs Io heap ArrayList hash_map json ; do
    nu nu/enrich.nu build --module $m
done 2>&1 | tee ~/zforge-enrich-$(date +%Y%m%d).log
# then the long tail (everything still NULL):
nu nu/enrich.nu build 2>&1 | tee -a ~/zforge-enrich-$(date +%Y%m%d).log
```

In the morning: check the log tail, and
`SELECT count(*) FILTER (WHERE gloss IS NOT NULL), count(*) FROM zig_api;`

---

## Step 6 — wire the soft `--tag` filter into zfind (the "narrow" lever)

The embedding enrichment (above) is the *wide* win — it improves plain similarity.
Tags also give an optional *narrowing* filter without exiling anything (a symbol has
many tags, so narrowing by one for one query doesn't shrink its reach elsewhere).

- Add `--tag <t>` (repeatable) to `zfind`. When given, add to the SQL:
  `AND tags && ARRAY[$tags]` (the GIN index from Step 1 makes this fast).
- Default (no `--tag`) stays the current full vector search — wide by default.
- **Controlled vocabulary for filtering.** Free-form tags drift (`alloc` vs
  `allocation` vs `memory`). For the *embedding* that's fine (the embedder handles
  synonyms). For the *filter* it isn't. Recommended: after generation, look at the
  distinct tags produced, collapse them into a curated set of ~40–60 mechanism tags,
  and map each symbol's free tags onto that set in a second `tags_controlled TEXT[]`
  column used only by the filter. Start free-form; add the controlled layer once you
  see what actually emerges.

---

## Step 7 — confirm it helped (don't trust, measure)

- Reuse `nu/proto_tags.nu eval` as the template: a list of `(query, expected symbol)`
  pairs, ranked against the index, scored by rank-weighted top-5.
- **Expand the query battery** beyond the 10 in the prototype — add queries for the
  chapters you enriched (fmt, fs, Io…), ideally 30–50 total, so the score is meaningful.
- Compare against a saved copy of the pre-enrichment index (keep a `zig_api_backup`
  before Step 4 — archive, don't overwrite, so you can A/B and roll back).
- Ship the enrichment only if it wins overall **and** shows no meaningful regressions
  on queries the baseline already answered well.

---

## Decisions to make before you start

1. **Documented only, or `--all`?** Documented (~6k) is the high-value core and ~4×
   cheaper. Start there; add `--all` later only if searches miss undocumented decls.
2. **Gloss model size.** `qwen2.5-coder:3b` was good enough on CPU. With GPU headroom,
   try `:7b` on one chapter and eyeball whether tags get cleaner before committing.
3. **Batch or per-symbol generation.** Batching ~10×-fewer calls is the single biggest
   speedup; per-symbol is simpler and easier to validate. With acceleration you may not
   need batching — measure one chapter's rate first, then decide.

---

## Files this builds on

- `nu/proto_tags.nu` — the working A/B prototype; the `gloss-tags`, embed, and `eval`
  logic to lift into a production `enrich.nu`.
- `nu/zindex.nu` — the existing embed-and-upsert loop and `--module`/`--limit`/`--all`
  flags; the enrichment is the same loop with richer text.
- `nu/zfind.nu` — where the `--tag` filter (Step 6) goes.
- `nu/lib.nu` — `embed`, `vec`, `rephrase`, `psql-*`, `zig-env` helpers.
- `sql/schema_zig_api.sql` — add the Step 1 columns here so a fresh install gets them.
```
