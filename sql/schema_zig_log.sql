-- zig_log — "the book": real Zig mistakes captured live by the zhook PostToolUse
-- hook as they happen on actual .zig edits, labeled by zsnag + zig ast-check.
--
-- SQLite (was postgres). The book is single-user local state — it needs no server,
-- so it lives in one file (~/.config/zforge/book.db, override $ZFORGE_BOOK). The
-- hook applies this schema idempotently on first write; no setup step. The semantic
-- INDEX (zig_api/zig_map) stays on postgres+pgvector — that one needs vector search.
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
