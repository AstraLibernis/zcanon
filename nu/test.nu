#!/usr/bin/env nu
# test.nu — zforge smoke battery. Asserts current std via the compiled Zig tools
# (zfact, zsnag) plus the Nushell semantic layer (zfind). Run against installed Zig.
#   nu nu/test.nu
use lib.nu *

let root = ($env.FILE_PWD | path dirname)
let ZF = ($root | path join zig-out bin zfact)
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

# --- zfact lookup (compiled Zig) ---
let cases = [
    ["exact fn signature"        "Io.Reader.stream"     "pub fn stream(r: *Reader, w: *Writer"]
    ["managed+unmanaged append"  "ArrayList.append"     "gpa: Allocator"]
    ["doc comment captured"      "HashMap.put"          "Clobbers any existing data"]
    ["fuzzy fallback"            "crypto.ChaCha20"      "fuzzy: declared name contains the query"]
    ["one-hop @import resolve"   "crypto.ChaCha20IETF"  "via @import"]
    ["stale namespace widens"    "fs.File.openFile"     "may be stale"]
    ["true negative is clean"    "Io.Reader.frobnicate" "no `pub` decl named"]
    ["cluster: name family"      "ArrayList.append"     "◆ family:"]
    ["cluster: AssumeCapacity"   "ArrayList.append"     "skips the capacity/alloc check"]
    ["cluster: see-also xref"    "HashMap.put"          "getOrPut"]
]
for c in $cases {
    let o = (out-of $ZF [$c.1])
    if ($o | str contains $c.2) {
        print $"PASS: ($c.0)"
    } else {
        print $"FAIL: ($c.0) \(expected: ($c.2))"; $fail = 1
    }
}

# --sig suppresses the cluster (hook mode)
if ((out-of $ZF ["ArrayList.append" "--sig"]) | str contains "◆ family:") {
    print "FAIL: --sig should suppress cluster"; $fail = 1
} else {
    print "PASS: --sig suppresses cluster"
}

# --- Layer B semantic (zfind.nu): only if ollama up AND index populated ---
let ollama_up = (try { http get http://localhost:11434/api/tags | ignore; true } catch { false })
let index_rows = (try { (psql-query "SELECT count(*) FROM zig_api" | str trim | into int) } catch { 0 })
if $ollama_up and ($index_rows > 0) {
    let zfind = ($root | path join nu zfind.nu)
    let pw = (^nu $zfind "hash a password securely" --raw --limit 5 | complete | get stdout)
    if ($pw =~ "(?i)pwhash|strHash|password") {
        print "PASS: semantic find (password hashing)"
    } else {
        print "FAIL: semantic find returned no password-hash API"; $fail = 1
    }
    let has_qwen = (try { (http get http://localhost:11434/api/tags | get models.name | str join " ") | str contains "qwen2.5-coder" } catch { false })
    if $has_qwen {
        let rd = (^nu $zfind "read a line of text from stdin" --limit 4 | complete | get stdout)
        if ($rd =~ "(?i)delimiter|stream") {
            print "PASS: rephrase bridges use-case -> mechanism"
        } else {
            print "FAIL: rephrase did not surface delimiter/stream"; $fail = 1
        }
    } else {
        print "SKIP: rephrase test (qwen2.5-coder not pulled)"
    }
} else {
    print "SKIP: Layer B semantic test (ollama down or index empty)"
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
