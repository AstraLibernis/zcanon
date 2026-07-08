# lib.nu — shared glue for zcanon's Nushell tools.
# zcanon is now footgun-linting + the edit hook + the mistake log: zsnag lints edited
# source, zhook runs it (and ast-check) on every .zig edit and feeds the book, zbook
# reads the book (one sqlite file). No database server. Std discovery/lookup lives in
# zephem, which owns the std map and its query layer (zlook/zmap) — see the zephem skill.

# Installed Zig's std dir + version (used by the hook to stamp the book; never snapshot it).
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

# ---- finding priority tiers ------------------------------------------------
# Findings are never hidden — the tier just LABELS how much to worry, so the noisy
# advisory rules don't read as alarms. It's a pure function of (severity, file):
# error→blocking, warn→caution, info→advisory; and an advisory finding in throwaway
# code (bench/scratch/experiment/tmp/test) demotes to 'expected' (no action needed).
# See the feedback note: tag, don't suppress.
export def finding-tier [severity: string, file: string] {
    let base = (match $severity {
        "error" => "blocking"
        "warn"  => "caution"
        _       => "advisory"
    })
    let scratch = ($file =~ '(?i)(/tmp/|/scratch|bench|experiment|_test\.zig$|/tests?/)')
    if (($base == "advisory") and $scratch) { "expected" } else { $base }
}

# Ordered tier metadata (rank + header) for grouped display. Lower rank = more urgent.
export def tier-meta [] {
    [
        {key: "blocking", rank: 0, head: "▲ BLOCKING — fix before continuing"}
        {key: "caution",  rank: 1, head: "⚠ CORRECTNESS RISK — review, likely a real bug"}
        {key: "advisory", rank: 2, head: "ℹ ADVISORY — usually fine, noted for awareness"}
        {key: "expected", rank: 3, head: "· EXPECTED (bench/test/scratch) — no action needed"}
    ]
}
