#!/usr/bin/env nu
# zbook — read the book: the corpus of real Zig mistakes that zhook captures live
# into the sqlite book (~/.config/zcanon/book.db) as they happen on actual .zig
# edits. Frequency is the signal — this is what the model genuinely gets wrong, not
# a guess or a synthetic.
#
#   nu nu/zbook.nu                 # table of contents: mistakes by rule, most frequent first
#   nu nu/zbook.nu recent          # the latest entries
#   nu nu/zbook.nu files           # which files trip the most
#   nu nu/zbook.nu R001            # every entry filed under one rule
use lib.nu *

# file paths are stored absolute; show just the basename in tables.
def base [] { update file {|r| $r.file | path basename } }

def show-toc [] {
    let toc = (book-query "SELECT rule, severity, count(*) AS findings, sum(hits) AS occurrences, count(DISTINCT file) AS files, date(max(last_ts)) AS last FROM zig_log GROUP BY rule, severity ORDER BY findings DESC")
    if ($toc | is-empty) {
        print "The book is empty. It fills as zhook catches mistakes on real .zig edits."
        return
    }
    let meta = (tier-meta)
    # tag each rule with its base tier and order most-urgent-first (stable within a tier
    # by frequency). Rule-level tier ignores per-file context, so advisory rules show as
    # 'advisory' here even where individual hits demote to 'expected' in scratch files.
    let ranked = ($toc
        | insert tier {|r| finding-tier $r.severity "" }
        | insert _rank {|r| ($meta | where key == $r.tier | get 0.rank) }
        | sort-by findings --reverse | sort-by _rank
        | select tier rule severity findings occurrences files last)
    let total = ($toc | get findings | math sum)
    print $"# zcanon book — ($total) distinct findings across ($toc | length) rules \(occurrences = total recurrences\)\n"
    print "  tiers: ▲ blocking   ⚠ caution   ℹ advisory   · expected \(bench/scratch — no action\)\n"
    $ranked | table
}

def main [section?: string, --limit: int = 20] {
    match $section {
        null => (show-toc)
        "recent" => {
            book-query ("SELECT strftime('%m-%d %H:%M', last_ts) AS at, rule, severity, hits, file, line, message FROM zig_log ORDER BY last_ts DESC LIMIT " + ($limit | into string))
                | insert tier {|r| finding-tier $r.severity $r.file }   # per-file: demotes to 'expected' in scratch
                | base
                | select at tier rule severity hits file line message
                | table
        }
        "files" => {
            book-query "SELECT file, count(*) AS findings, sum(hits) AS occurrences, count(DISTINCT rule) AS rules, date(max(last_ts)) AS last FROM zig_log GROUP BY file ORDER BY findings DESC" | base | table
        }
        _ => {
            if ($section | str starts-with "R") {
                book-query ("SELECT strftime('%m-%d %H:%M', last_ts) AS at, hits, file, line, message FROM zig_log WHERE rule = '" + $section + "' ORDER BY hits DESC LIMIT " + ($limit | into string)) | base | table
            } else {
                print "usage: nu nu/zbook.nu [recent | files | R0NN]"
            }
        }
    }
}
