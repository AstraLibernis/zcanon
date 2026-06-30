#!/usr/bin/env nu
# build_lookup.nu — emit the denormalized "lookup" table that `zlook` searches.
#
# Joins zephem's published per-decl datasets into ONE row per map node, so a single
# line carries everything discovery needs:
#   path · depth · kind · name · n_children · detail · sig · doc · rkind · rdetail · canon
# (rkind/rdetail = resolved.tsv's kind/detail, renamed to avoid colliding with the
# parser's own kind/detail; canon = alias-family head, blank if not aliased.)
#
# This is a pure left-join over the map's nodes — same symbol universe as nodes.tsv,
# just enriched. Deterministic: same zephem snapshot -> byte-identical lookup.tsv.
#
#   nu nu/build_lookup.nu                 # write ~/.config/zforge/lookup.tsv (what zlook reads)
#   nu nu/build_lookup.nu --out other.tsv
#
# Reads zephem's source TSVs at $ZEPHEM_DATA (default ~/projects/zephem/data/std);
# writes the lookup table zforge owns at $ZFORGE_LOOKUP (default ~/.config/zforge/lookup.tsv).

def zephem-dir [] { $env.ZEPHEM_DATA? | default ([$env.HOME projects zephem data std] | path join) }
def lookup-path [] { $env.ZFORGE_LOOKUP? | default ([$env.HOME ".config" zforge lookup.tsv] | path join) }

def main [--out: string] {
    let d = (zephem-dir)
    for f in [nodes.tsv sigs.tsv docs.tsv resolved.tsv canon.tsv] {
        if not ($d | path join $f | path exists) {
            error make {msg: $"zephem dataset ($f) not found at ($d) — clone zephem + run `nu scripts/build_std.nu`, or set $ZEPHEM_DATA"}
        }
    }
    let out = ($out | default (lookup-path))
    mkdir ($out | path dirname)

    let nodes = (open ($d | path join nodes.tsv))
    let sigs  = (open ($d | path join sigs.tsv))
    let docs  = (open ($d | path join docs.tsv))
    let resolved = (open ($d | path join resolved.tsv) | rename --column {kind: rkind, detail: rdetail})
    let canon = (open ($d | path join canon.tsv))

    let lookup = ($nodes
        | join --left $sigs path
        | join --left $docs path
        | join --left $resolved path
        | join --left $canon path)

    # self-check: a left-join over nodes must preserve exactly the node rows.
    if ($lookup | length) != ($nodes | length) {
        error make {msg: $"lookup row count (($lookup | length)) != nodes (($nodes | length)) — join not 1:1"}
    }

    $lookup | save -f $out
    print $"lookup: ($lookup | length) rows -> ($out)"
}
