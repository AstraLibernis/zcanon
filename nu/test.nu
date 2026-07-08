#!/usr/bin/env nu
# test.nu — zcanon smoke battery for the zsnag LLM-footgun linter. Run against installed Zig.
# (Std discovery/lookup — zlook/zmap — moved to zephem; its query layer is tested there
# by `nu query/test.nu`.)
#   nu nu/test.nu
use lib.nu *

let root = ($env.FILE_PWD | path dirname)
let ZS = ($root | path join zig-out bin zsnag)
let FX = ($root | path join test_fixtures)
mut fail = 0

def out-of [bin: string, args: list<string>] {
    let r = (^$bin ...$args | complete)
    [$r.stdout, $r.stderr] | str join
}

# ensure the binary is built
cd $root
let build = (^zig build | complete)
if $build.exit_code != 0 { print "FAIL: zig build"; print $build.stderr; exit 1 }

# --- zsnag (LLM footgun checker, compiled Zig) ---
let bad = (out-of $ZS [($FX | path join bad.zig)])
for r in [R001 R002 R003 R004 R005 R006 R007 R008 R009 R010] {
    if ($bad | str contains $r) { print $"PASS: zsnag catches ($r)" } else { print $"FAIL: zsnag missed ($r)"; $fail = 1 }
}
if ((^$ZS ($FX | path join bad.zig) | complete).exit_code != 0) {
    print "PASS: zsnag exits non-zero on errors"
} else {
    print "FAIL: zsnag should exit non-zero"; $fail = 1
}
let clean = (out-of $ZS [($FX | path join good.zig)])
if ($clean | str trim | is-empty) {
    print "PASS: zsnag clean on good file (no false positives)"
} else {
    print "FAIL: zsnag false-positived on good.zig"; print $clean; $fail = 1
}
let fp = (out-of $ZS [($FX | path join fp_regression.zig)])
if ($fp =~ "R001|R008") {
    print "FAIL: zsnag false-positive regressed"; print $fp; $fail = 1
} else {
    print "PASS: zsnag no FP on real-code patterns (method async/await, FixedBufferAllocator)"
}

if $fail == 0 { print "--- all passed ---" } else { print "--- failures present ---"; exit 1 }
