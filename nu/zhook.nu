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

use lib.nu *

const MARKER = "zforge-zig-hook"

def here   [] { $env.FILE_PWD }
def root   [] { $env.FILE_PWD | path dirname }
def zsnag  [] { root | path join zig-out bin zsnag }
def self   [] { here | path join zhook.nu }
def flag   [] { $nu.home-path | path join .config zforge hook.disabled }
def settings-path [] { $env.ZFORGE_SETTINGS? | default ($nu.home-path | path join .claude settings.json) }

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

# ---- writing the book (postgres) -----------------------------------------
def sql-str [s: string] { "'" + ($s | str replace --all "'" "''") + "'" }
def line-at [lines: list, ln: int] {
    let i = ($ln - 1)
    if ($i >= 0) and ($i < ($lines | length)) { ($lines | get $i | str trim) } else { "" }
}

def log-book [fp: string, ver: string, findings: list, ast_errs: list, src: list] {
    let rows = ($findings | each {|f|
        let snip = (line-at $src $f.line)
        "(" + ([(sql-str $ver) (sql-str $fp) (sql-str $f.rule) (sql-str $f.severity) ($f.line | into string) ($f.col | into string) (sql-str $f.message) (sql-str $snip)] | str join ",") + ")"
    })
    let arows = ($ast_errs | each {|e|
        let snip = (line-at $src ($e.line | into int))
        "(" + ([(sql-str $ver) (sql-str $fp) "'ast-check'" "'error'" $e.line $e.col (sql-str $e.message) (sql-str $snip)] | str join ",") + ")"
    })
    let all = ($rows | append $arows)
    if ($all | is-empty) { return }
    psql-exec ("INSERT INTO zig_log (zig_version,file,rule,severity,line,col,message,snippet) VALUES " + ($all | str join ","))
}

# ---- the hook itself -----------------------------------------------------
def run-hook [] {
    if ((flag) | path exists) { return }          # disabled: silent no-op
    let raw = (^cat)
    let data = (try { $raw | from json } catch { return })
    let fp = ($data | get tool_input?.file_path? | default "")
    if (not ($fp | str ends-with ".zig")) or (not ($fp | path exists)) { return }

    let src = (try { open --raw $fp | lines } catch { [] })

    # zsnag findings, structured (--json; zsnag writes to stderr)
    let zs = (zsnag)
    let findings = (if ($zs | path exists) {
        let r = (^$zs --json $fp | complete)
        ([$r.stdout, $r.stderr] | str join "\n" | lines
            | where {|l| ($l | str trim) | str starts-with "{" }
            | each {|l| try { $l | from json } catch { null } }
            | where {|x| $x != null })
    } else { [] })

    # zig ast-check errors
    let ac = (^zig ast-check $fp | complete)
    let ast_errs = (if ($ac.exit_code != 0) {
        ($ac.stderr | lines | parse --regex '^(?<file>[^:]+):(?<line>\d+):(?<col>\d+): error: (?<message>.+)$')
    } else { [] })

    if (($findings | is-empty) and ($ast_errs | is-empty)) { return }

    # write to the book — best-effort, never let logging break the hook
    try {
        let ver = (try { (zig-env).ver } catch { "?" })
        log-book $fp $ver $findings $ast_errs $src
    }

    # feed the findings back to me
    let flines = ($findings | each {|f| $"[($f.rule) ($f.severity)] ($fp | path basename):($f.line):($f.col)  ($f.message)" })
    let alines = ($ast_errs | each {|e| $"[ast-check] ($fp | path basename):($e.line):($e.col)  ($e.message)" })
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
] {
    if $disable { do-disable } else if $enable { do-enable
    } else if $status { do-status } else if $install { do-install
    } else if $uninstall { do-uninstall } else { run-hook }
}
