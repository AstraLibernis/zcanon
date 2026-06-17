-- One-time migration (2026-06-17): collapse the save-driven duplicate rows in
-- zig_log into one row per distinct finding (file, rule, message, snippet), with
-- hits = how many raw rows collapsed and first/last_ts spanning them. Adds the
-- hits/first_ts/last_ts columns and the dedup unique index used by the hook's
-- upsert. The raw log is archived (not deleted) into zig_log_backup_20260617.
BEGIN;

-- archive the raw log before collapsing (archive, don't delete)
DROP TABLE IF EXISTS zig_log_backup_20260617;
CREATE TABLE zig_log_backup_20260617 AS SELECT * FROM zig_log;

CREATE TABLE zig_log_new (
    id          BIGSERIAL PRIMARY KEY,
    first_ts    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_ts     TIMESTAMPTZ NOT NULL DEFAULT now(),
    hits        INT NOT NULL DEFAULT 1,
    zig_version TEXT,
    file        TEXT NOT NULL,
    rule        TEXT NOT NULL,
    severity    TEXT,
    line        INT,
    col         INT,
    message     TEXT,
    snippet     TEXT
);

INSERT INTO zig_log_new (first_ts, last_ts, hits, zig_version, file, rule, severity, line, col, message, snippet)
SELECT min(ts), max(ts), count(*),
       (array_agg(zig_version ORDER BY ts DESC))[1],
       file, rule,
       (array_agg(severity ORDER BY ts DESC))[1],
       max(line), max(col),
       coalesce(message,''), coalesce(snippet,'')
FROM zig_log
GROUP BY file, rule, coalesce(message,''), coalesce(snippet,'');

DROP TABLE zig_log;
ALTER TABLE zig_log_new RENAME TO zig_log;

CREATE INDEX zig_log_rule_idx ON zig_log (rule);
CREATE INDEX zig_log_ts_idx   ON zig_log (last_ts);
CREATE UNIQUE INDEX zig_log_finding_uidx
    ON zig_log (file, rule, coalesce(message,''), coalesce(snippet,''));

COMMIT;
