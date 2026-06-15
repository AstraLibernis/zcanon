#!/usr/bin/env nu
# zgremlin — emit plausible-but-flawed Zig, to probe what the toolchain catches.
#
# An LLM rarely fails by writing gibberish; it fails by writing code that LOOKS
# right. This generates three such flaw classes so we can see which checker (if
# any) catches each — the seed of the generate -> test -> mine loop.
#
#   fmt      valid & compiles, but mis-formatted        (zig fmt --check should flag)
#   close    closes incorrectly: missing/extra/wrong delimiter (zig ast-check flags)
#   deadend  parses & compiles but accomplishes nothing  (often caught by NOTHING)
#
#   nu nu/zgremlin.nu fmt                # print one ugly-but-valid program
#   nu nu/zgremlin.nu close --seed 2     # a specific broken-close variant
#   nu nu/zgremlin.nu deadend --seed 1
#   nu nu/zgremlin.nu all                # write all three + report what each checker catches

# --- flaw class: valid code, mangled formatting (zig fmt would rewrite it) ---
# (these compile cleanly — the ONLY thing wrong is the layout)
def fmt-variants [] {
    [
'const std=@import("std");
fn add(a:u32,b:u32)u32{return a+b;}'
'const std = @import("std");
fn  pick ( cond : bool )  u32  {
    if(cond){return 1;}else{return 2;}
}'
'const std = @import( "std" ) ;
const Point=struct{x:u32,y:u32} ;
fn origin( ) Point { return Point{ .x=0 , .y=0 } ; }'
    ]
}

# --- flaw class: closes incorrectly (mismatched/missing/wrong delimiter) ---
def close-variants [] {
    [
# missing closing brace for the function body
'const std = @import("std");
fn demo() void {
    var x: u32 = 0;
    x += 1;
    _ = x;
'
# wrong delimiter: a ) where a } is expected
'const std = @import("std");
fn demo() void {
    var x: u32 = 0;
    while (x < 10) : (x += 1) {
        x += 1;
    )
    _ = x;
}'
# extra stray closing brace
'const std = @import("std");
fn demo() void {
    var x: u32 = 0;
    _ = x;
}
}'
# unclosed call paren
'const std = @import("std");
fn demo() void {
    std.debug.print("{}\n", .{42}
}'
    ]
}

# --- flaw class: compiles cleanly but accomplishes nothing (the subtle one) ---
# (all verified to slip past zig fmt, zig ast-check, AND zsnag — this is the gap)
def deadend-variants [] {
    [
# loop that breaks on the first iteration: looks like it sums, adds one element
'const std = @import("std");
fn sumAll(items: []const u32) u32 {
    var total: u32 = 0;
    for (items) |it| {
        total += it;
        break; // bails immediately — only the first element is ever added
    }
    return total;
}'
# guard is always true, so all the real work below is dead
'const std = @import("std");
fn process(items: []const u32) u32 {
    if (true) return 0;
    var total: u32 = 0;
    for (items) |it| total += it; // unreachable
    return total;
}'
# does the work into a local, then returns a constant instead of it
'const std = @import("std");
fn count(items: []const u32) u32 {
    var n: u32 = 0;
    for (items) |it| {
        _ = it;
        n += 1;
    }
    return 0; // n is built up and then ignored
}'
# the useful branch is gated behind an impossible condition
'const std = @import("std");
fn maybe(items: []const u32) u32 {
    var total: u32 = 0;
    if (items.len > 1000000) {
        for (items) |it| total += it;
    }
    return total; // returns 0 for any realistic input
}'
    ]
}

def pick [variants: list, seed: int] {
    $variants | get ($seed mod ($variants | length))
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
        "caught?": (if ($fmt or $ast or $snag) { "yes" } else { "NO — slips through" })
    }
}

def run-all [out: string] {
    let root = ($env.FILE_PWD | path dirname)
    let zs = ($root | path join zig-out bin zsnag)
    mkdir $out

    let classes = {fmt: (fmt-variants), close: (close-variants), deadend: (deadend-variants)}
    mut rows = []
    for cls in ($classes | columns) {
        let variants = ($classes | get $cls)
        for i in 0..(($variants | length) - 1) {
            let f = ($out | path join $"gremlin_($cls)_($i).zig")
            (($variants | get $i) + "\n") | save -f $f   # zig fmt wants a trailing newline
            let c = (check-file $f $zs)
            $rows = ($rows | append ({class: $cls, "#": $i} | merge $c))
        }
    }
    print $"wrote ($rows | length) gremlins to ($out)/\n"
    print ($rows | table)
    let slipped = ($rows | where "caught?" =~ "NO")
    print $"\n($slipped | length) of ($rows | length) slip past every checker — all in the `deadend` class \(valid code, useless logic). That gap is what a generate→test→mine loop would target."
}

def main [category?: string, --seed: int = 0, --out: string = "/tmp/zgremlin"] {
    match $category {
        "fmt"     => { print (pick (fmt-variants) $seed) }
        "close"   => { print (pick (close-variants) $seed) }
        "deadend" => { print (pick (deadend-variants) $seed) }
        "all"     => { run-all $out }
        _ => {
            print "usage: nu nu/zgremlin.nu <fmt|close|deadend|all> [--seed N] [--out DIR]"
            print "  fmt     valid code, mangled formatting"
            print "  close   closes incorrectly (delimiter mismatch)"
            print "  deadend compiles but accomplishes nothing"
            print "  all     write all three and report what each checker catches"
        }
    }
}
