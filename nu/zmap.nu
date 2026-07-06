#!/usr/bin/env nu
# zmap — read the complete, verified zephem std map. Deterministic: no AI, no DB.
# Discovery + browsing over the 100%-mapped truth (this replaces the old semantic
# search; keyword search over the full map has 100% literal recall and no false
# ranking — "parse int" finds fmt.parseInt, which the embedding search missed).
#
#   zmap find parse int            decls whose name/path/sig/doc contain ALL terms
#   zmap find "constant time"      multi-word term (quote it)
#   zmap show std.fmt              list one module/namespace subtree
#   zmap doc std.fmt.parseInt      signature + doc for one exact path
#
# Reads zephem's TSVs at $ZEPHEM_DATA (default ~/projects/zephem/data/std) — the sole
# source of truth. If the map's PINNED zig differs from yours, regenerate zephem.
use lib.nu *

def zephem-dir [] { $env.ZEPHEM_DATA? | default ([$env.HOME projects zephem data std] | path join) }

def load-map [] {
    let d = (zephem-dir)
    if not ($d | path join nodes.tsv | path exists) {
        error make {msg: $"zephem map not found at ($d) — clone zephem + run `nu scripts/build_std.nu`, or set $ZEPHEM_DATA"}
    }
    let stale = (zephem-staleness $d)
    if not ($stale | is-empty) { print -e $stale }   # warn on stderr; results still print
    let nodes = (open ($d | path join nodes.tsv))      # path depth kind name n_children detail
    let sigs  = (open ($d | path join sigs.tsv))       # path sig
    let docs  = (open ($d | path join docs.tsv))       # path doc
    $nodes | join --left $sigs path | join --left $docs path
}

# keyword search: every term must appear (case-insensitive) in path/name/sig/doc.
# rank: all terms in the leaf NAME (0) > in the PATH (1) > only sig/doc (2);
# shorter path breaks ties (the canonical decl over a deep re-export).
def cmd-find [map: table, terms: list, limit: int] {
    if ($terms | is-empty) { print "usage: zmap find <terms...>"; return }
    let lc = ($terms | each {|t| $t | str downcase})
    let hits = ($map | where {|r|
        let hay = ([$r.path $r.name ($r.sig? | default '') ($r.doc? | default '')] | str join ' ' | str downcase)
        $lc | all {|t| $hay | str contains $t}
    })
    let scored = ($hits
        | insert _s {|r|
            let nm = ($r.name | str downcase)
            let pa = ($r.path | str downcase)
            if ($lc | all {|t| $nm | str contains $t}) { 0
            } else if ($lc | all {|t| $pa | str contains $t}) { 1
            } else { 2 } }
        | insert _pl {|r| $r.path | str length }
        | sort-by _s _pl
        | first $limit)
    if ($scored | is-empty) { print $"no map entry matches: ($terms | str join ' ')"; return }
    print $"# map find: ($terms | str join ' ')  \(top ($scored | length) of ($hits | length) hits)\n"
    for r in $scored {
        print $"  ($r.path)  \(($r.kind))"
        let sig = ($r.sig? | default '')
        let doc = ($r.doc? | default '')
        if not ($sig | is-empty) { print $"      ($sig)" }
        if not ($doc | is-empty) { print $"      ⌁ ($doc | str substring 0..120)" }
    }
}

def cmd-show [map: table, pathprefix: string] {
    if ($pathprefix | is-empty) { print "usage: zmap show <path>"; return }
    let sub = ($map | where {|r| ($r.path == $pathprefix) or ($r.path | str starts-with $"($pathprefix).")} | sort-by path)
    if ($sub | is-empty) { print $"nothing under ($pathprefix)"; return }
    print $"# map show ($pathprefix)  \(($sub | length) decls)\n"
    $sub | select path kind | table
}

def cmd-doc [map: table, path: string] {
    if ($path | is-empty) { print "usage: zmap doc <path>"; return }
    let row = ($map | where path == $path)
    if ($row | is-empty) { print $"($path) not in the map"; return }
    let r = ($row | first)
    print $"($r.path)  \(($r.kind))"
    let sig = ($r.sig? | default '')
    let doc = ($r.doc? | default '')
    if not ($sig | is-empty) { print $"  ($sig)" }
    if not ($doc | is-empty) { print $"\n  ($doc)" }
    print "\n(from the zephem map — the source of truth; if it's stale, regenerate zephem)"
}

def main [cmd?: string, ...args: string, --limit (-l): int = 12] {
    match $cmd {
        "find" => (cmd-find (load-map) $args $limit)
        "show" => (cmd-show (load-map) ($args | get 0? | default ""))
        "doc"  => (cmd-doc  (load-map) ($args | get 0? | default ""))
        _ => {
            print "zmap — read the complete zephem std map (deterministic, no AI/DB)"
            print "  zmap find <terms...>   keyword search over the whole map (path/name/sig/doc)"
            print "  zmap show <path>       list a module/namespace subtree"
            print "  zmap doc  <path>       signature + doc for one exact path"
        }
    }
}
