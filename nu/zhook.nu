#!/usr/bin/env nu
# zhook — Claude Code PostToolUse hook that runs zsnag (+ zig ast-check) on edited
# .zig files and feeds findings back to Claude, so I react to my own mistakes
# without you having to ask. Fully reversible.
#
# As a hook (no flags): reads PostToolUse JSON on stdin, emits additionalContext.
# Management:
#   nu zhook.nu --status        is it on?
#   nu zhook.nu --disable       turn OFF (just a flag file — no settings change)
#   nu zhook.nu --enable        turn back ON
#   nu zhook.nu --install       add the hook to ~/.claude/settings.json (backs up first)
#   nu zhook.nu --uninstall     remove ONLY our entry; leave other settings intact
#   nu zhook.nu --prune         sweep the book: drop resolved findings + dead files
#
# The book records only findings that SURVIVE. Each save re-scans the whole file, so
# anything no longer present has been fixed and is pruned — transient mid-edit errors
# don't linger, and `hits` counts real recurrences, not repeated saves of a fix.

use lib.nu *

const MARKER = "zcanon-zig-hook"

def here   [] { $env.FILE_PWD }
def root   [] { $env.FILE_PWD | path dirname }
def zsnag  [] { root | path join zig-out bin zsnag }
def self   [] { here | path join zhook.nu }
def flag   [] { $nu.home-dir | path join .config zcanon hook.disabled }
def settings-path [] { $env.ZCANON_SETTINGS? | default ($nu.home-dir | path join .claude settings.json) }

# ---- management ----------------------------------------------------------
def do-disable [] {
    let f = (flag)
    mkdir ($f | path dirname)
    touch $f
    print $"zhook OFF \(flag: ($f)). The settings entry stays but does nothing.\nRe-enable: nu zhook.nu --enable"
}

def do-enable [] {
    let f = (flag)
    if ($f | path exists) { rm $f }
    print "zhook ON."
}

def do-status [] {
    let sp = (settings-path)
    let installed = (($sp | path exists) and ((open --raw $sp) | str contains $MARKER))
    let off = ((flag) | path exists)
    print $"installed in settings: ($installed)"
    print $"runtime state: (if $off { 'DISABLED \(flag set)' } else { 'enabled' })"
}

def do-install [] {
    let sp = (settings-path)
    let settings = (if ($sp | path exists) { open $sp } else { {} })
    if ($sp | path exists) { cp $sp $"($sp).bak" }
    let prior = ($settings | get hooks?.PostToolUse? | default [])
    let kept = ($prior | where {|e| not (($e | to json) | str contains $MARKER) })
    let entry = {
        matcher: "Edit|Write|MultiEdit"
        hooks: [{ type: "command", command: $"nu (self)  # ($MARKER)", timeout: 30 }]
    }
    let ptu = ($kept | append $entry)
    let hooks = (($settings | get hooks? | default {}) | upsert PostToolUse $ptu)
    let out = ($settings | upsert hooks $hooks)
    $out | to json --indent 2 | save -f $sp
    print $"Installed into ($sp) \(backup: ($sp).bak)."
    print "Off switch: nu zhook.nu --disable   |   Full removal: nu zhook.nu --uninstall"
}

def do-uninstall [] {
    let sp = (settings-path)
    if not ($sp | path exists) { print "no settings file"; return }
    let settings = (open $sp)
    let prior = ($settings | get hooks?.PostToolUse? | default [])
    let kept = ($prior | where {|e| not (($e | to json) | str contains $MARKER) })
    mut hooks = ($settings | get hooks? | default {})
    if ($kept | is-empty) {
        $hooks = ($hooks | reject PostToolUse? )
    } else {
        $hooks = ($hooks | upsert PostToolUse $kept)
    }
    let out = (if ($hooks | is-empty) { $settings | reject hooks? } else { $settings | upsert hooks $hooks })
    $out | to json --indent 2 | save -f $sp
    print $"Removed our hook from ($sp). Other settings untouched."
}

# Sweep the whole book against reality: drop rows for files that no longer exist,
# and re-check the ones that do, pruning findings that have since been resolved.
# One-shot cleanup for backlog accumulated before prune-on-resolution existed.
def do-sweep [] {
    let files = (book-query "SELECT DISTINCT file FROM zig_log" | get file)
    if ($files | is-empty) { print "book is empty — nothing to sweep."; return }
    let before = (book-query "SELECT count(*) AS n FROM zig_log" | get n.0)
    mut gone = 0
    mut checked = 0
    for fp in $files {
        if (not ($fp | path exists)) {
            book-exec ("DELETE FROM zig_log WHERE file = " + (sql-str $fp))
            $gone += 1
            continue
        }
        if not ($fp | str ends-with ".zig") { continue }
        let c = (check-file $fp)
        prune-file $fp $c.recs $c.ran_zsnag $c.ran_ast
        $checked += 1
    }
    let after = (book-query "SELECT count(*) AS n FROM zig_log" | get n.0)
    print $"swept: re-checked ($checked) live files, dropped rows for ($gone) missing files."
    print $"book went from ($before) to ($after) findings \(removed ($before - $after))."
}

# ---- writing the book (sqlite) -------------------------------------------
def sql-str [s] { "'" + ($s | into string | str replace --all "'" "''") + "'" }
def line-at [lines: list, ln: int] {
    let i = ($ln - 1)
    if ($i >= 0) and ($i < ($lines | length)) { ($lines | get $i | str trim) } else { "" }
}

# Build one record per finding, deduped WITHIN this batch on the same key the DB
# dedups on — two identical lines in one file would otherwise collide in a single
# ON CONFLICT statement.
def build-recs [fp: string, ver: string, findings: list, ast_errs: list, src: list] {
    let frecs = ($findings | each {|f|
        { ver: $ver, file: $fp, rule: $f.rule, severity: $f.severity, line: ($f.line | into int), col: ($f.col | into int), message: $f.message, snippet: (line-at $src $f.line) }
    })
    let arecs = ($ast_errs | each {|e|
        { ver: $ver, file: $fp, rule: "ast-check", severity: "error", line: ($e.line | into int), col: ($e.col | into int), message: $e.message, snippet: (line-at $src ($e.line | into int)) }
    })
    ($frecs | append $arecs | uniq-by file rule message snippet)
}

# Prune-on-resolution: each save re-scans the WHOLE file, so `recs` is the complete
# current truth for it. Any book row for this file NOT in `recs` has been fixed —
# delete it. Scope the delete to the checkers that actually ran this pass, so a
# checker that failed to run (e.g. a crashed zsnag) never wipes its own history.
# This is what keeps transient mid-edit errors from lingering: fix + save purges them.
def prune-file [fp: string, recs: list, ran_zsnag: bool, ran_ast: bool] {
    let scope = ([
        (if $ran_ast   { "rule = 'ast-check'" } else { null })
        (if $ran_zsnag { "rule <> 'ast-check'" } else { null })
    ] | where {|x| $x != null })
    if ($scope | is-empty) { return }
    let scope_sql = "(" + ($scope | str join " OR ") + ")"
    let keep = ($recs | each {|r|
        "(" + ([(sql-str $r.rule) (sql-str $r.message) (sql-str $r.snippet)] | str join ",") + ")"
    })
    let keep_clause = (if ($keep | is-empty) { "" } else {
        " AND (rule, message, snippet) NOT IN (" + ($keep | str join ",") + ")"
    })
    book-exec ("DELETE FROM zig_log WHERE file = " + (sql-str $fp) + " AND " + $scope_sql + $keep_clause)
}

# Upsert current findings: a recurring finding bumps hits + last_ts instead of adding
# a row. message/snippet are NOT NULL DEFAULT '' so the conflict target is a plain
# composite (no coalesce). book-exec auto-creates the book on first use.
def upsert-recs [recs: list] {
    if ($recs | is-empty) { return }
    let values = ($recs | each {|r|
        "(" + ([(sql-str $r.ver) (sql-str $r.file) (sql-str $r.rule) (sql-str $r.severity) ($r.line | into string) ($r.col | into string) (sql-str $r.message) (sql-str $r.snippet)] | str join ",") + ")"
    })
    book-exec ("INSERT INTO zig_log (zig_version,file,rule,severity,line,col,message,snippet) VALUES "
        + ($values | str join ",")
        + " ON CONFLICT (file, rule, message, snippet) DO UPDATE SET"
        + " hits = hits + 1, last_ts = datetime('now'), line = excluded.line, col = excluded.col,"
        + " severity = excluded.severity, zig_version = excluded.zig_version")
}

# Run both checkers over the whole file and return the complete current state, plus
# ran_* flags recording whether each checker actually executed. Shared by the live
# hook and the --prune sweep so they see the file identically.
def check-file [fp: string] {
    let src = (try { open --raw $fp | lines } catch { [] })
    let ver = (try { (zig-env).ver } catch { "?" })

    # zsnag findings, structured (--json; writes to stderr). exits 0 with or without
    # findings, so a nonzero exit means it actually failed → don't trust emptiness.
    let zs = (zsnag)
    let zres = (if ($zs | path exists) { (^$zs --json $fp | complete) } else { null })
    let ran_zsnag = (($zres != null) and ($zres.exit_code == 0))
    let findings = (if $ran_zsnag {
        ([$zres.stdout, $zres.stderr] | str join "\n" | lines
            | where {|l| ($l | str trim) | str starts-with "{" }
            | each {|l| try { $l | from json } catch { null } }
            | where {|x| $x != null })
    } else { [] })

    # zig ast-check. nonzero exit here is EXPECTED (it means errors were found), so
    # ran_ast is about whether the command ran at all, not its exit code.
    let ac = (try { ^zig ast-check $fp | complete } catch { null })
    let ran_ast = ($ac != null)
    let ast_errs = (if ($ran_ast and ($ac.exit_code != 0)) {
        ($ac.stderr | lines | parse --regex '^(?<file>[^:]+):(?<line>\d+):(?<col>\d+): error: (?<message>.+)$')
    } else { [] })

    {
        findings: $findings, ast_errs: $ast_errs,
        ran_zsnag: $ran_zsnag, ran_ast: $ran_ast,
        recs: (build-recs $fp $ver $findings $ast_errs $src)
    }
}

# ---- the hook itself -----------------------------------------------------
def run-hook [] {
    if ((flag) | path exists) { return }          # disabled: silent no-op
    let raw = (^cat)
    let data = (try { $raw | from json } catch { return })
    let fp = ($data | get tool_input?.file_path? | default "")
    if (not ($fp | str ends-with ".zig")) or (not ($fp | path exists)) { return }

    let c = (check-file $fp)

    # sync the book — best-effort, never let logging break the hook. prune runs even
    # when nothing is flagged now, so fixing the last issue in a file clears its rows.
    try {
        prune-file $fp $c.recs $c.ran_zsnag $c.ran_ast
        upsert-recs $c.recs
    }

    if (($c.findings | is-empty) and ($c.ast_errs | is-empty)) { return }

    # feed the findings back to me
    let flines = ($c.findings | each {|f| $"[($f.rule) ($f.severity)] ($fp | path basename):($f.line):($f.col)  ($f.message)" })
    let alines = ($c.ast_errs | each {|e| $"[ast-check] ($fp | path basename):($e.line):($e.col)  ($e.message)" })
    let ctx = ($"zfact/zsnag checked ($fp | path basename) and flagged issues — please review and fix:\n\n" +
        (($flines | append $alines) | str join "\n") +
        "\n\n\(Confirm current APIs with `zfact <symbol>` before changing.)")
    {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ($ctx | str substring 0..9000)}} | to json
}

def main [
    --status
    --disable
    --enable
    --install
    --uninstall
    --prune      # sweep the book: drop resolved findings + rows for vanished files
] {
    if $disable { do-disable } else if $enable { do-enable
    } else if $status { do-status } else if $install { do-install
    } else if $uninstall { do-uninstall } else if $prune { do-sweep
    } else { run-hook }
}
