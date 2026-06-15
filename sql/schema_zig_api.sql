-- zfact Layer B: semantic index over the Zig std API.
-- A DERIVED, version-stamped cache — the installed std stays the source of truth.
-- Rebuild with `zfact-index` whenever the Zig version changes.
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS zig_api (
    id          BIGSERIAL PRIMARY KEY,
    zig_version TEXT NOT NULL,
    symbol      TEXT NOT NULL,
    namespace   TEXT,
    kind        TEXT,
    signature   TEXT NOT NULL,
    doc         TEXT,
    file        TEXT NOT NULL,
    line        INT  NOT NULL,
    embedding   VECTOR(768),
    UNIQUE (zig_version, file, line)
);

CREATE INDEX IF NOT EXISTS zig_api_embedding_idx
    ON zig_api USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS zig_api_version_idx ON zig_api (zig_version);
