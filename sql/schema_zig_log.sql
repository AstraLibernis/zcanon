-- zig_log — "the book": real Zig mistakes captured live by the PostToolUse hook as
-- they happen on actual .zig edits, labeled by zsnag + zig ast-check.
--
-- HISTORICAL, as of 2026-08-10. This file is no longer executed: the book moved from
-- sqlite to a plain TSV (~/.config/zcanon/book.tsv, override $ZCANON_BOOK). The reason
-- was not preference — the sqlite path shelled out to an `sqlite3` binary that was not
-- installed, so every write failed silently and the book never recorded anything at all.
-- TSV needs no external binary, no process spawns on the hook's hot path, and no
-- hand-rolled SQL quoting. It is the format the companion zephem already uses at 10 MB+.
--
-- Kept because it remains the authoritative statement of the COLUMN SET and the dedup
-- semantics below, which the Zig implementation (src/book.zig) reproduces exactly.
--
-- Deduplicated: one row per DISTINCT finding (file, rule, message, snippet), with
-- an occurrence counter (hits) and first/last-seen timestamps. The hook UPSERTs —
-- re-saving a file bumps hits, it does not add a row — so hits is true frequency
-- (how often the mistake recurs), not how often the file was saved. Read it with
-- `nu nu/zbook.nu`.
CREATE TABLE IF NOT EXISTS zig_log (
    id          INTEGER PRIMARY KEY,
    first_ts    TEXT NOT NULL DEFAULT (datetime('now')),
    last_ts     TEXT NOT NULL DEFAULT (datetime('now')),
    hits        INTEGER NOT NULL DEFAULT 1,   -- times this exact finding has recurred
    zig_version TEXT,
    file        TEXT NOT NULL,
    rule        TEXT NOT NULL,                -- R001..R010, or 'ast-check'
    severity    TEXT,                         -- error | warn | info
    line        INTEGER,
    col         INTEGER,
    message     TEXT NOT NULL DEFAULT '',
    snippet     TEXT NOT NULL DEFAULT ''      -- the offending source line, if available
);

-- the dedup key: line/col are deliberately excluded (they drift as a file is
-- edited). message/snippet are NOT NULL DEFAULT '' so a plain composite UNIQUE is
-- the UPSERT conflict target (no coalesce/expression index needed).
CREATE UNIQUE INDEX IF NOT EXISTS zig_log_finding_uidx
    ON zig_log (file, rule, message, snippet);
CREATE INDEX IF NOT EXISTS zig_log_rule_idx ON zig_log (rule);
CREATE INDEX IF NOT EXISTS zig_log_ts_idx   ON zig_log (last_ts);
