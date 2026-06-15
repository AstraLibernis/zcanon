#!/usr/bin/env nu
# zbook — read the book: the corpus of real Zig mistakes that zhook captures live
# into postgres (the library) as they happen on actual .zig edits. Frequency is the
# signal — this is what the model genuinely gets wrong, not a guess or a synthetic.
#
#   nu nu/zbook.nu                 # table of contents: mistakes by rule, most frequent first
#   nu nu/zbook.nu recent          # the latest entries
#   nu nu/zbook.nu files           # which files trip the most
#   nu nu/zbook.nu R001            # every entry filed under one rule
use lib.nu *

def show-toc [] {
    let toc = (psql-json "SELECT rule, count(*) AS hits, count(DISTINCT file) AS files, max(ts)::date AS last FROM zig_log GROUP BY rule ORDER BY hits DESC")
    if ($toc | is-empty) {
        print "The book is empty. It fills as zhook catches mistakes on real .zig edits."
        return
    }
    let total = ($toc | get hits | math sum)
    print $"# zforge book — ($total) findings logged across ($toc | length) rules\n"
    $toc | table
}

def main [section?: string, --limit: int = 20] {
    match $section {
        null => (show-toc)
        "recent" => {
            psql-json $"SELECT to_char\(ts,'MM-DD HH24:MI') AS at, rule, severity, regexp_replace\(file,'^.*/','') AS file, line, message FROM zig_log ORDER BY ts DESC LIMIT ($limit)" | table
        }
        "files" => {
            psql-json "SELECT regexp_replace(file,'^.*/','') AS file, count(*) AS hits, count(DISTINCT rule) AS rules, max(ts)::date AS last FROM zig_log GROUP BY 1 ORDER BY hits DESC" | table
        }
        _ => {
            if ($section | str starts-with "R") {
                psql-json $"SELECT to_char\(ts,'MM-DD HH24:MI') AS at, regexp_replace\(file,'^.*/','') AS file, line, message FROM zig_log WHERE rule = '($section)' ORDER BY ts DESC LIMIT ($limit)" | table
            } else {
                print "usage: nu nu/zbook.nu [recent | files | R0NN]"
            }
        }
    }
}
