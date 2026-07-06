#!/usr/bin/env nu
# test.nu — zcanon smoke battery. Asserts std facts via the map (zlook over the baked
# lookup table + zmap over zephem's TSVs) and the zsnag linter. Run against installed Zig.
#   nu nu/test.nu
use lib.nu *

let root = ($env.FILE_PWD | path dirname)
let ZL = ($root | path join zig-out bin zlook)
let ZS = ($root | path join zig-out bin zsnag)
let FX = ($root | path join test_fixtures)
mut fail = 0

def out-of [bin: string, args: list<string>] {
    let r = (^$bin ...$args | complete)
    [$r.stdout, $r.stderr] | str join
}

# ensure binaries are built
cd $root
let build = (^zig build | complete)
if $build.exit_code != 0 { print "FAIL: zig build"; print $build.stderr; exit 1 }

# --- zlook: keyword lookup over the map's baked lookup.tsv (the primary std lookup) ---
# Needs the lookup table (nu/build_lookup.nu); skip cleanly if absent.
let lookup = ($env.ZCANON_LOOKUP? | default ($env.HOME | path join .config zcanon lookup.tsv))
if ($lookup | path exists) {
    let zcases = [
        ["factory member path"        ["HashMap" "get"]      "std.hash_map.HashMap().get"]
        ["factory member signature"   ["HashMap" "get"]      "fn get(self: Self, key: K) ?V"]
        ["struct field + its type"    ["Allocator" "vtable"] "*const VTable"]
        ["delegation target shown"    ["AutoHashMap"]        "HashMap("]
        ["resolved error-set search"  ["OutOfMemory"]        "OutOfMemory"]
    ]
    for c in $zcases {
        let o = (out-of $ZL $c.1)
        if ($o | str contains $c.2) { print $"PASS: ($c.0)" } else { print $"FAIL: ($c.0) \(expected: ($c.2))"; $fail = 1 }
    }
} else {
    print $"SKIP: zlook test \(no lookup.tsv at ($lookup) — run nu nu/build_lookup.nu)"
}

# --- zmap reader (deterministic keyword search over the zephem map) ---
# Only if the zephem map is present (the reader's only dependency, no server).
let zmap = ($root | path join nu zmap.nu)
let zdata = ($env.ZEPHEM_DATA? | default ([$env.HOME projects zephem data std] | path join))
if ($zdata | path join nodes.tsv | path exists) {
    # the case the old embedding search failed: "parse int" must surface fmt.parseInt
    let pi = (^nu $zmap find parse int --limit 5 | complete | get stdout)
    if ($pi | str contains "std.fmt.parseInt") {
        print "PASS: zmap find surfaces fmt.parseInt (top hits)"
    } else {
        print "FAIL: zmap find did not surface fmt.parseInt"; $fail = 1
    }
    let ct = (^nu $zmap find "constant time" --limit 3 | complete | get stdout)
    if ($ct | str contains "timing_safe") {
        print "PASS: zmap find surfaces timing_safe (constant time)"
    } else {
        print "FAIL: zmap find did not surface timing_safe"; $fail = 1
    }
} else {
    print $"SKIP: zmap reader test \(zephem map not at ($zdata))"
}

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
