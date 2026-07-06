# lib.nu — shared glue for zcanon's Nushell tools.
# zcanon reads ground truth two ways, both dependency-light: the Zig binaries
# (zfact, zsnag) analyse the installed std directly, and the Nushell tools read
# zephem's complete verified std map (zmap) + keep the local mistake log (the book,
# one sqlite file). No database server, no embedding models.

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
# Callers decide severity — discovery only answers "what's it called" and the
# workflow re-confirms with zfact (live std), so reading WARNS; building the
# baked lookup table (read later without zephem present) should refuse.
export def zephem-staleness [dir: string] {
    let pinned = (zephem-pinned $dir)
    let live = (try { (zig-env).ver } catch { null })
    if ($pinned == null) {
        $"⚠ zephem map at ($dir) has no PINNED stamp — cannot verify it matches your zig; confirm names with `zfact`."
    } else if (($live != null) and ($pinned != $live)) {
        $"⚠ zephem map is pinned to zig ($pinned) but you're on ($live) — map may be stale; discovered names could be wrong. Regenerate zephem's map, or confirm each name with `zfact` \(reads live std)."
    } else { "" }
}
