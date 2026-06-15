-- zig_log — "the book": real Zig mistakes captured live by the zhook PostToolUse
-- hook as they happen on actual .zig edits, labeled by zsnag + zig ast-check.
-- Frequency is the signal — what the model actually gets wrong, not what we guessed.
-- Read it with `nu nu/zbook.nu`.
CREATE TABLE IF NOT EXISTS zig_log (
    id          BIGSERIAL PRIMARY KEY,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
    zig_version TEXT,
    file        TEXT NOT NULL,
    rule        TEXT NOT NULL,      -- R001..R010, or 'ast-check'
    severity    TEXT,               -- error | warn | info
    line        INT,
    col         INT,
    message     TEXT,
    snippet     TEXT                -- the offending source line, if available
);
CREATE INDEX IF NOT EXISTS zig_log_rule_idx ON zig_log (rule);
CREATE INDEX IF NOT EXISTS zig_log_ts_idx   ON zig_log (ts);
