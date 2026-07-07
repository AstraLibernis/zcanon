#!/usr/bin/env nu
# build_lookup.nu — emit the denormalized "lookup" table that `zlook` searches.
#
# Joins zephem's published per-decl datasets into ONE row per map node, so a single
# line carries everything discovery needs:
#   path · depth · kind · name · n_children · detail · sig · doc · rkind · rdetail · canon
#   · ftype · fval · delegate
# (rkind/rdetail = resolved.tsv's kind/detail, renamed to avoid colliding with the
# parser's own kind/detail; canon = alias-family head, blank if not aliased;
# ftype/fval = fields.tsv's type/value for a field/tag node; delegate = delegates.tsv's
# raw target for a delegating factory. All blank when not applicable.)
#
# This is a pure left-join over the map's nodes — same symbol universe as nodes.tsv,
# just enriched. Deterministic: same zephem snapshot -> byte-identical lookup.tsv.
#
#   nu nu/build_lookup.nu                 # write ~/.config/zcanon/lookup.tsv (what zlook reads)
#   nu nu/build_lookup.nu --out other.tsv
#
# Reads zephem's source TSVs at $ZEPHEM_DATA (default ~/projects/zephem/data/std);
# writes the lookup table zcanon owns at $ZCANON_LOOKUP (default ~/.config/zcanon/lookup.tsv).
use lib.nu *

def zephem-dir [] { $env.ZEPHEM_DATA? | default ([$env.HOME projects zephem data std] | path join) }
def lookup-path [] { $env.ZCANON_LOOKUP? | default ([$env.HOME ".config" zcanon lookup.tsv] | path join) }

def main [--out: string, --force] {
    let d = (zephem-dir)
    for f in ["extracted/nodes.tsv" "extracted/sigs.tsv" "extracted/docs.tsv" "extracted/resolved.tsv" "derived/canon.tsv" "extracted/fields.tsv" "extracted/delegates.tsv"] {
        if not ($d | path join $f | path exists) {
            error make {msg: $"zephem dataset ($f) not found at ($d) — clone zephem + run `nu scripts/build_std.nu`, or set $ZEPHEM_DATA"}
        }
    }
    # A baked lookup.tsv is read later by zlook WITHOUT zephem present, so a stale one
    # can't be caught at read time — refuse to build it if the map's pinned zig differs
    # from the installed zig. --force overrides (e.g. deliberately snapshotting an old map).
    let stale = (zephem-staleness $d)
    if not ($stale | is-empty) {
        if $force { print -e $stale } else {
            error make {msg: $"($stale)\nrefusing to build a possibly-stale lookup.tsv — pass --force to override."}
        }
    }
    let out = ($out | default (lookup-path))
    mkdir ($out | path dirname)

    let nodes = (open ($d | path join extracted nodes.tsv))
    let sigs  = (open ($d | path join extracted sigs.tsv))
    let docs  = (open ($d | path join extracted docs.tsv))
    let resolved = (open ($d | path join extracted resolved.tsv) | rename --column {kind: rkind, detail: rdetail})
    let canon = (open ($d | path join derived canon.tsv))
    let fields = (open ($d | path join extracted fields.tsv) | rename --column {type: ftype, value: fval})
    let delegates = (open ($d | path join extracted delegates.tsv) | rename --column {target: delegate})

    let lookup = ($nodes
        | join --left $sigs path
        | join --left $docs path
        | join --left $resolved path
        | join --left $canon path
        | join --left $fields path
        | join --left $delegates path)

    # self-check: a left-join over nodes must preserve exactly the node rows.
    if ($lookup | length) != ($nodes | length) {
        error make {msg: $"lookup row count (($lookup | length)) != nodes (($nodes | length)) — join not 1:1"}
    }

    $lookup | save -f $out
    print $"lookup: ($lookup | length) rows -> ($out)"
}
