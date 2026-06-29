#!/usr/bin/env nu
# zfind — Layer B semantic search over the Zig std API (the "find by concept" tool).
#
# Answers "what does X?" when you don't know the name. Embeds your query (after
# rephrasing it into mechanism vocabulary) and ranks the zig_map index by cosine
# similarity. Pipe a result name back into `zfact <symbol>` for the exact signature
# + neighborhood cluster.
#
#   zfind "hash a password securely"          concept search (rephrased first)
#   zfind "increase list capacity" --raw      skip rephrase (already mechanistic)
#   zfind "read a line of text" --limit 4     cap results
#
# Needs ollama (embeddings + rephrase) and postgres/pgvector (the zig_map index
# built by zmap from zephem's complete, verified std datasets). Refuses to serve a
# stale index (version != installed Zig).
use lib.nu *

def main [
    ...terms: string   # natural-language description of what you want to do
    --limit (-l): int = 8
    --raw              # skip the use-case -> mechanism rephrase
] {
    if ($terms | is-empty) {
        print 'usage: zfind "natural language description" [--limit N] [--raw]'
        return
    }
    let query = ($terms | str join " ")
    let ze = (zig-env)
    let ver = $ze.ver

    # index must exist and match the installed Zig (never serve stale truth)
    let have = (psql-query "SELECT DISTINCT zig_version FROM zig_map" | lines | where {|x| not ($x | is-empty)})
    if ($have | is-empty) {
        print "index empty — run: nu nu/zmap.nu"
        return
    }
    if not ($ver in $have) {
        print $"! no index for installed zig ($ver) \(have ($have)). Index is STALE — rerun zephem's build_std.nu, then: nu nu/zmap.nu"
        return
    }

    let search_text = if $raw { $query } else { (rephrase $query) }
    let qv = (vec (embed $search_text | get 0))

    let sql = ("SELECT symbol,namespace,kind,signature,doc,canon,round((1-(embedding<=>'" + $qv + "'::vector))::numeric,2) " +
        "FROM zig_map WHERE zig_version='" + $ver + "' " +
        "ORDER BY embedding<=>'" + $qv + "'::vector LIMIT " + ($limit | into string))
    let rows = (psql-query $sql | lines | where {|x| not ($x | is-empty)})
    if ($rows | is-empty) {
        print "no matches"
        return
    }

    print $"# find \"($query)\"  \(semantic search, zig ($ver), top ($rows | length))"
    if (not $raw) and ($search_text != $query) {
        print $'  rephrased → "($search_text)"'
    }
    print ""
    for row in $rows {
        let f = ($row | split row "|")
        let sym = ($f | get 0)
        let ns = ($f | get 1)
        let kind = ($f | get 2)
        let sig = ($f | get 3)
        let doc = ($f | get 4)
        let canon = ($f | get 5)
        let sim = ($f | get 6)
        let loc = (if ($ns | is-empty) { $sym } else { $"($ns).($sym)" })
        print $"  [($sim)] ($loc)  \(($kind))"
        if not ($sig | is-empty) { print $"         ($sig)" }
        if not ($canon | is-empty) { print $"         → alias of ($canon) — prefer the canonical name" }
        if not ($doc | is-empty) {
            print $"         ⌁ ($doc | str substring 0..110)"
        }
        print ""
    }
}
