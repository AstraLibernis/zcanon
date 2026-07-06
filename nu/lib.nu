# lib.nu — shared glue for zcanon's Nushell tools.
# Ground truth is zephem's complete, self-verified std map. The Zig binaries are
# dependency-light: zlook searches the map's baked lookup table, zsnag lints edited
# source. The Nushell tools read the map directly (zmap) + keep the local mistake log
# (the book, one sqlite file). No live-std fallback (a shallow one would be less
# accurate than the map), no database server, no embedding models.

# Installed Zig's std dir + version (the source of truth — never snapshot it).
export def zig-env [] {
    let out = (^zig env | str join)
    {
        std: ($out | parse --regex '\.std_dir\s*=\s*"(?<v>[^"]+)"' | get v.0)
        ver: ($out | parse --regex '\.version\s*=\s*"(?<v>[^"]+)"' | get v.0)
    }
}

# ---- the book (sqlite) ---------------------------------------------------
# The mistake log is single-user local state: ONE sqlite file, no server needed.
# Book path: $ZCANON_BOOK, else ~/.config/zcanon/book.db.
export def book-db [] {
    $env.ZCANON_BOOK? | default ($env.HOME | path join .config zcanon book.db)
}

# Apply the schema idempotently so the book auto-creates on first use — no setup.
export def ensure-book [] {
    let db = (book-db)
    mkdir ($db | path dirname)
    let schema = ($env.FILE_PWD | path dirname | path join sql schema_zig_log.sql)
    open --raw $schema | ^sqlite3 $db
}

# Execute SQL against the book (DDL/DML). Ensures the book exists first.
export def book-exec [sql: string] {
    ensure-book
    $sql | ^sqlite3 (book-db)
}

# Run a SELECT against the book, return parsed records (sqlite3 -json; [] if empty).
export def book-query [sql: string] {
    ensure-book
    let out = (^sqlite3 -json (book-db) $sql)
    if ($out | str trim | is-empty) { [] } else { $out | from json }
}

# ---- zephem map freshness -------------------------------------------------
# The map is derived from ONE std snapshot; zephem stamps that version in
# data/std/PINNED (e.g. "zig 0.16.0"). Staleness therefore reduces to a version
# compare — no hashing or mtimes. Return the pinned version ("0.16.0"), or null
# if the stamp is missing/absent.
export def zephem-pinned [dir: string] {
    let p = ($dir | path join PINNED)
    if ($p | path exists) { (open --raw $p | str trim | str replace 'zig ' '') } else { null }
}

# One-line staleness check: pinned map version vs the installed zig. Returns a
# human warning string when they differ (or the stamp is missing), else "".
# The map is the SOLE source of truth — there is no live fallback — so on a version
# mismatch the fix is to REGENERATE zephem, never to trust memory. Callers decide
# severity: reading WARNS; building the baked lookup table (read later without zephem
# present) should refuse.
export def zephem-staleness [dir: string] {
    let pinned = (zephem-pinned $dir)
    let live = (try { (zig-env).ver } catch { null })
    if ($pinned == null) {
        $"⚠ zephem map at ($dir) has no PINNED stamp — cannot verify it matches your zig; regenerate it with `nu scripts/build_std.nu` in zephem."
    } else if (($live != null) and ($pinned != $live)) {
        $"⚠ zephem map is pinned to zig ($pinned) but you're on ($live) — map may be stale; discovered facts could be wrong. Regenerate zephem's map: `nu scripts/build_std.nu` then `nu nu/build_lookup.nu`."
    } else { "" }
}
