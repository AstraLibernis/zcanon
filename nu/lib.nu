# lib.nu — shared glue for zforge's Nushell tools.
# zforge reads ground truth two ways, both dependency-light: the Zig binaries
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
# Book path: $ZFORGE_BOOK, else ~/.config/zforge/book.db.
export def book-db [] {
    $env.ZFORGE_BOOK? | default ($env.HOME | path join .config zforge book.db)
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
