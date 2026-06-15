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

# ---- the hook itself -----------------------------------------------------
def run-hook [] {
    if ((flag) | path exists) { return }          # disabled: silent no-op
    let raw = (^cat)
    let data = (try { $raw | from json } catch { return })
    let fp = ($data | get tool_input?.file_path? | default "")
    if (not ($fp | str ends-with ".zig")) or (not ($fp | path exists)) { return }

    mut findings = []
    let zs = (zsnag)
    if ($zs | path exists) {
        let r = (^$zs $fp | complete)
        let out = ([$r.stdout, $r.stderr] | str join | str trim)
        if not ($out | is-empty) { $findings = ($findings | append $out) }
    }
    let ac = (^zig ast-check $fp | complete)
    if ($ac.exit_code != 0) and (not ($ac.stderr | str trim | is-empty)) {
        $findings = ($findings | append $"zig ast-check:\n($ac.stderr | str trim)")
    }
    if ($findings | is-empty) { return }

    let ctx = ($"zfact/zsnag checked ($fp | path basename) and flagged issues — please review and fix:\n\n" +
        ($findings | str join "\n\n") +
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
