-- zig_log — "the book": real Zig mistakes captured live by the zhook PostToolUse
-- hook as they happen on actual .zig edits, labeled by zsnag + zig ast-check.
--
-- Deduplicated: one row per DISTINCT finding (file, rule, message, snippet), with
-- an occurrence counter (`hits`) and first/last-seen timestamps. The hook upserts
-- — re-saving a file bumps `hits`, it does not add a row — so `hits` is true
-- frequency (how often the mistake recurs), not how often the file was saved.
-- Read it with `nu nu/zbook.nu`.
CREATE TABLE IF NOT EXISTS zig_log (
    id          BIGSERIAL PRIMARY KEY,
    first_ts    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_ts     TIMESTAMPTZ NOT NULL DEFAULT now(),
    hits        INT NOT NULL DEFAULT 1,   -- times this exact finding has recurred
    zig_version TEXT,
    file        TEXT NOT NULL,
    rule        TEXT NOT NULL,            -- R001..R010, or 'ast-check'
    severity    TEXT,                     -- error | warn | info
    line        INT,
    col         INT,
    message     TEXT,
    snippet     TEXT                       -- the offending source line, if available
);
CREATE INDEX IF NOT EXISTS zig_log_rule_idx ON zig_log (rule);
CREATE INDEX IF NOT EXISTS zig_log_ts_idx   ON zig_log (last_ts);
-- the dedup key: line/col are deliberately excluded (they drift as a file is
-- edited); coalesce so NULL and '' collapse to one finding. Matches the hook's
-- ON CONFLICT target exactly.
CREATE UNIQUE INDEX IF NOT EXISTS zig_log_finding_uidx
    ON zig_log (file, rule, coalesce(message,''), coalesce(snippet,''));
