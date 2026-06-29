-- zforge Layer B, zephem-sourced: a semantic index over the FULL Zig std API,
-- built from zephem's verified TSV datasets (data/std/*.tsv) instead of a live
-- `zfact --dump`. zephem maps ALL of std (parse-based, survives poison decls) and
-- self-verifies (conservation law), so this index is COMPLETE and de-duplicated
-- where the zfact-dump index (sql/schema_zig_api.sql) is partial and live.
--
-- Keyed on `path` — zephem's canonical, globally-unique dotted identity — not on
-- (file,line) like zig_api, because zephem does not yet emit per-decl source
-- location (that is its next parser step; `file` here is the nearest ns-ancestor).
--
-- Still a DERIVED, version-stamped cache: the installed std stays the source of
-- truth. Rebuild by re-running zephem's `build_std.nu` against the active
-- toolchain, then `nu nu/zmap.nu`. Coexists with zig_api; nothing here replaces it.
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS zig_map (
    id          BIGSERIAL PRIMARY KEY,
    zig_version TEXT NOT NULL,
    path        TEXT NOT NULL,       -- zephem canonical dotted path (the identity)
    namespace   TEXT,                -- parent path (path minus its leaf)
    symbol      TEXT NOT NULL,       -- leaf name
    kind        TEXT,                -- ns/struct/enum/union/opaque/fn/const/alias/...
    signature   TEXT,                -- as-written fn signature (sigs.tsv); '' for non-fns
    doc         TEXT,                -- /// doc comment (docs.tsv); '' if undocumented
    file        TEXT,                -- source file, nearest ns ancestor (derived)
    canon       TEXT,                -- canonical type / alias target (canon.tsv); '' if none
    witness     TEXT,                -- both / reflect-only / parser-only (callcard.tsv)
    embedding   VECTOR(768),
    UNIQUE (zig_version, path)
);

CREATE INDEX IF NOT EXISTS zig_map_embedding_idx
    ON zig_map USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS zig_map_version_idx ON zig_map (zig_version);
CREATE INDEX IF NOT EXISTS zig_map_path_idx    ON zig_map (zig_version, path);
