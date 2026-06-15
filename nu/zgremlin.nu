#!/usr/bin/env nu
# zgremlin — emit plausible-but-flawed Zig, to probe what the toolchain catches.
#
# An LLM rarely fails by writing gibberish; it fails by writing code that LOOKS
# right. This generates three flaw classes so we can see which checker (if any)
# catches each — the seed of the generate -> test -> mine loop.
#
#   fmt      valid & compiles, but mis-formatted        (zig fmt --check should flag)
#   close    closes incorrectly: missing/extra/wrong delimiter (zig ast-check flags)
#   deadend  parses & compiles but accomplishes nothing  (often caught by NOTHING)
#
# Output is varied like a sampler: --temperature controls how far each gremlin
# drifts from the canonical form (0.0 = always the same; 1.0 = full variety in
# type, identifiers, bounds, and which sub-pattern), and --seed makes that variety
# reproducible. Omit --seed and a random one is drawn (and printed) each run.
#
#   nu nu/zgremlin.nu deadend --temperature 0.9        # one varied dead-end
#   nu nu/zgremlin.nu close --seed 42 --temperature 1  # reproducible
#   nu nu/zgremlin.nu all --count 15 --temperature 0.8 # batch + catch table + speed

# ---- deterministic PRNG (LCG), so (seed,temperature) fully decides the output --
def rnd [st: int] {
    let n = ((($st * 1664525) + 1013904223) mod 4294967296)
    {v: $n, st: $n}
}
# pick index 0 with prob (1 - temperature), else a uniform pick over [0,len)
def choose [st: int, len: int, temp: float] {
    let r = (rnd $st)
    if (($r.v / 4294967296.0) >= $temp) {
        {idx: 0, st: $r.st}
    } else {
        let r2 = (rnd $r.st)
        {idx: ($r2.v mod $len), st: $r2.st}
    }
}
# default value with prob (1 - temperature), else a uniform int in [lo,hi]
def choose-num [st: int, def: int, lo: int, hi: int, temp: float] {
    let r = (rnd $st)
    if (($r.v / 4294967296.0) >= $temp) {
        {v: $def, st: $r.st}
    } else {
        let r2 = (rnd $r.st)
        {v: ($lo + ($r2.v mod (($hi - $lo) + 1))), st: $r2.st}
    }
}

def make-choices [seed: int, temp: float] {
    let types = [u32 u8 u16 u64 usize i32 i64]
    let names = [total sum acc count tally result]
    let aas   = [a x lhs items]
    let fns   = [demo work run compute reduce step]
    mut st = $seed
    let t = (choose $st ($types | length) $temp); $st = $t.st
    let n = (choose $st ($names | length) $temp); $st = $n.st
    let a = (choose $st ($aas  | length) $temp); $st = $a.st
    let f = (choose $st ($fns  | length) $temp); $st = $f.st
    let b = (choose-num $st 10 3 99 $temp);      $st = $b.st
    let h = (choose-num $st 1000000 1000 9999999 $temp); $st = $h.st
    let v = (choose $st 4 $temp); $st = $v.st
    {
        type: ($types | get $t.idx)
        acc:  ($names | get $n.idx)
        arg:  ($aas  | get $a.idx)
        fn:   ($fns  | get $f.idx)
        bound: $b.v
        threshold: $h.v
        vsel: $v.idx
    }
}

# ---- builders: each returns valid-or-deliberately-broken Zig from the choices --

def build-fmt [ch: record] {
    let T = $ch.type; let f = $ch.fn; let a = $ch.arg
    match ($ch.vsel mod 3) {
        0 => $"const std=@import\(\"std\");\nfn ($f)\(($a):($T),b:($T))($T){return ($a)+b;}\n"
        1 => $"const std = @import\(\"std\");\nfn  ($f) \( ($a) : ($T) , b : ($T) )  ($T)  {  return ($a) + b ;  }\n"
        _ => $"const std = @import\( \"std\" ) ;\nfn ($f)\(($a): ($T) , b: ($T)) ($T)\n{\n        return ($a)+b ;\n}\n"
    }
}

# a valid summing function, as canonical lines we can then corrupt
def sum-fn [ch: record] {
    let T = $ch.type; let f = $ch.fn; let a = $ch.arg; let acc = $ch.acc
    $"const std = @import\(\"std\");\nfn ($f)\(($a): []const ($T)) ($T) {\n    var ($acc): ($T) = 0;\n    for \(($a)) |it| {\n        ($acc) += it;\n    }\n    return ($acc);\n}\n"
}

def build-close [ch: record] {
    let good = (sum-fn $ch)
    match ($ch.vsel mod 4) {
        # drop the final closing brace
        0 => ($good | str replace --regex '\}\n$' "")
        # turn the for-loop's closing brace into a paren
        1 => ($good | str replace "    }\n    return" "    )\n    return")
        # add a stray extra closing brace
        2 => ($good + "}\n")
        # unbalance the for-header parens
        _ => ($good | str replace "for (" "for ((")
    }
}

def build-deadend [ch: record] {
    let T = $ch.type; let f = $ch.fn; let a = $ch.arg; let acc = $ch.acc
    let n = $ch.bound; let hi = $ch.threshold
    match ($ch.vsel mod 4) {
        # breaks on the first iteration: looks like it sums, adds one element
        0 => $"const std = @import\(\"std\");\nfn ($f)\(($a): []const ($T)) ($T) {\n    var ($acc): ($T) = 0;\n    for \(($a)) |it| {\n        ($acc) += it;\n        break; // bails immediately — only the first element is added\n    }\n    return ($acc);\n}\n"
        # guard is always true, so the real work below is dead
        1 => $"const std = @import\(\"std\");\nfn ($f)\(($a): []const ($T)) ($T) {\n    if \(true) return 0;\n    var ($acc): ($T) = 0;\n    for \(($a)) |it| ($acc) += it; // unreachable\n    return ($acc);\n}\n"
        # builds the result into a local, then returns a constant instead
        2 => $"const std = @import\(\"std\");\nfn ($f)\(($a): []const ($T)) ($T) {\n    var ($acc): ($T) = 0;\n    for \(($a)) |it| {\n        _ = it;\n        ($acc) += 1;\n    }\n    return 0; // ($acc) is built up and then ignored\n}\n"
        # useful branch gated behind an impossible condition
        _ => $"const std = @import\(\"std\");\nfn ($f)\(($a): []const ($T)) ($T) {\n    var ($acc): ($T) = 0;\n    if \(($a).len > ($hi)) {\n        for \(($a)) |it| ($acc) += it;\n    }\n    return ($acc); // returns 0 for any realistic input\n}\n"
    }
}

def gen [class: string, seed: int, temp: float] {
    let ch = (make-choices $seed $temp)
    match $class {
        "fmt"     => (build-fmt $ch)
        "close"   => (build-close $ch)
        "deadend" => (build-deadend $ch)
        _ => ""
    }
}

def check-file [f: string, zs: string] {
    let fmt = ((^zig fmt --check $f | complete).exit_code != 0)
    let ast = ((^zig ast-check $f | complete).exit_code != 0)
    let snag = (if ($zs | path exists) {
        let r = (^$zs $f | complete)
        not (([$r.stdout, $r.stderr] | str join | str trim) | is-empty)
    } else { false })
    {
        "fmt --check": (if $fmt { "flags" } else { "clean" })
        "ast-check": (if $ast { "flags" } else { "clean" })
        "zsnag": (if $snag { "flags" } else { "clean" })
        "caught?": (if ($fmt or $ast or $snag) { "yes" } else { "NO — slips" })
    }
}

def run-all [count: int, seed: int, temp: float, out: string] {
    let root = ($env.FILE_PWD | path dirname)
    let zs = ($root | path join zig-out bin zsnag)
    mkdir $out
    let classes = [fmt close deadend]

    # --- generate (timed) ---
    let t0 = (date now)
    let gremlins = (0..($count - 1) | each {|i|
        let class = ($classes | get ($i mod ($classes | length)))
        let s = ($seed + ($i * 7919))   # distinct sub-seed per gremlin
        let f = ($out | path join $"g_($i)_($class).zig")
        (gen $class $s $temp) | save -f $f
        {i: $i, class: $class, file: $f}
    })
    let t1 = (date now)

    # --- check (timed) ---
    let rows = ($gremlins | each {|g|
        {class: $g.class} | merge (check-file $g.file $zs)
    })
    let t2 = (date now)

    print ($rows | table)

    let gen_ms = (($t1 - $t0) / 1ms)
    let chk_ms = (($t2 - $t1) / 1ms)
    let slipped = ($rows | where "caught?" =~ "NO" | length)
    print ""
    print $"seed=($seed)  temperature=($temp)  count=($count)"
    print $"($slipped) of ($count) slip past every checker \(all in the deadend class)."
    print ""
    print "── speed ──"
    print $"generation:  (($gen_ms | math round --precision 1)) ms total   (((($gen_ms / $count)) | math round --precision 2)) ms/gremlin   (((($count / ($gen_ms / 1000))) | math round --precision 0)) gremlins/s"
    print $"checking:    (($chk_ms | math round --precision 1)) ms total   (((($chk_ms / $count)) | math round --precision 2)) ms/gremlin   ((((($count * 3) / ($chk_ms / 1000))) | math round --precision 0)) checks/s"
}

def main [
    category?: string
    --count: int = 12
    --seed: int = -1
    --temperature: float = 0.7
    --out: string = "/tmp/zgremlin"
] {
    let seed = (if $seed < 0 { random int 0..999999 } else { $seed })
    match $category {
        "fmt"     => { print (gen "fmt" $seed $temperature) }
        "close"   => { print (gen "close" $seed $temperature) }
        "deadend" => { print (gen "deadend" $seed $temperature) }
        "all"     => { run-all $count $seed $temperature $out }
        _ => {
            print "usage: nu nu/zgremlin.nu <fmt|close|deadend|all> [--count N] [--seed N] [--temperature 0..1] [--out DIR]"
            print "  fmt     valid code, mangled formatting"
            print "  close   closes incorrectly (delimiter mismatch)"
            print "  deadend compiles but accomplishes nothing"
            print "  all     generate a batch, report what each checker catches + speed"
        }
    }
}
