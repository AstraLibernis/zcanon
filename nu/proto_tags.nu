#!/usr/bin/env nu
# proto_tags — A/B prototype: does enriching each std symbol with a generated
# use-case GLOSS + TAGS improve semantic search ranking vs the current index?
#
# Baseline = the symbol's EXISTING embedding in zig_api (the current map).
# Enriched = re-embed (signature + doc + gloss + tags), tags from a local model.
# Both tables hold the SAME candidate set, so the only variable is the embedding.
#
#   nu nu/proto_tags.nu build      # generate gloss+tags, build proto_base / proto_enr
#   nu nu/proto_tags.nu eval       # run the test queries against both, side by side
#   nu nu/proto_tags.nu tags       # show the generated gloss+tags (inspect quality)
use lib.nu *

# Candidate set: high-value std.mem free functions our test queries target,
# plus strong distractors so ranking is a real contest.
const CANDS = [
    copyForwards copyBackwards eql allEqual order lessThan
    zeroes zeroInit asBytes toBytes
    indexOf indexOfScalar findScalar find containsAtLeastScalar count countScalar
    splitScalar splitSequence splitAny tokenizeScalar tokenizeAny
    trim trimStart trimEnd startsWith endsWith cutPrefix cutSuffix
    concat join joinZ replace replaceScalar
    reverse rotate swap window
    nativeToBig bigToNative nativeToLittle byteSwapAllElements
    sliceTo span len max min sort
]

# Test queries -> the symbol(s) a good search should surface near the top.
const QUERIES = [
    [q, want];
    ["copy bytes from one slice to another"      "copyForwards"]
    ["compare two slices for equality"           "eql"]
    ["zero out a value in memory"                "zeroes"]
    ["find the index of a byte in a slice"       "indexOfScalar"]
    ["split a string on a delimiter"             "splitScalar"]
    ["remove whitespace from both ends"          "trim"]
    ["check if a slice begins with a prefix"     "startsWith"]
    ["join slices with a separator"              "join"]
    ["reverse the elements of a slice"           "reverse"]
    ["convert an integer to big-endian bytes"    "nativeToBig"]
]

def sql-str [s: string] { "'" + ($s | str replace --all "'" "''") + "'" }

# Ask a local model for a one-line use-case gloss + comma tags for a symbol.
def gloss-tags [sym: string, sig: string, doc: string] {
    let prompt = ("You label standard-library functions for search. Given a function, output exactly two lines.\n" +
        "Line 1 `gloss:` one short plain-English sentence of what a programmer USES it for (no function/language names).\n" +
        "Line 2 `tags:` 4-8 comma-separated lowercase search keywords a programmer would type (operations, data, synonyms).\n\n" +
        $"function: ($sym)\nsignature: ($sig)\ndoc: ($doc)\n\ngloss:")
    try {
        let r = (http post --content-type application/json http://localhost:11434/api/generate {
            model: "qwen2.5-coder:3b"
            prompt: $prompt
            stream: false
            options: {temperature: 0.0, num_predict: 90}
        })
        let txt = ("gloss:" + $r.response)
        let gloss = ($txt | parse --regex '(?i)gloss:\s*(?<g>[^\n]+)' | get g.0? | default "" | str trim)
        let tags  = ($txt | parse --regex '(?i)tags:\s*(?<t>[^\n]+)'  | get t.0? | default "" | str trim)
        {gloss: $gloss, tags: $tags}
    } catch {
        {gloss: "", tags: ""}
    }
}

def fetch-cands [] {
    let inlist = ($CANDS | each {|s| sql-str $s } | str join ",")
    # one row per symbol (dedupe nested-struct collisions by lowest line)
    psql-json ("SELECT DISTINCT ON (symbol) symbol, kind, signature, coalesce(doc,'') AS doc, file, line, " +
        "embedding::text AS emb FROM zig_api WHERE file='mem.zig' AND symbol IN (" + $inlist + ") ORDER BY symbol, line")
}

def do-build [] {
    let cands = (fetch-cands)
    print $"candidates resolved: ($cands | length) / ($CANDS | length)"
    if ($cands | is-empty) { print "no candidates found in zig_api"; return }

    # generate gloss+tags, then build the enriched embedding text
    mut enriched = []
    let total = ($cands | length)
    mut i = 0
    for c in $cands {
        $i = $i + 1
        let gt = (gloss-tags $c.symbol $c.signature ($c.doc | str substring 0..300))
        let etext = ($"($c.symbol) \(($c.kind))\n($c.signature)\n($c.doc)\nuse: ($gt.gloss)\ntags: ($gt.tags)")
        let ev = (vec (embed $etext | get 0))
        $enriched = ($enriched | append { symbol: $c.symbol, kind: $c.kind, signature: $c.signature, gloss: $gt.gloss, tags: $gt.tags, emb: $c.emb, enr: $ev })
        print -n $"\r  enriched ($i)/($total): ($c.symbol)                    "
    }
    print ""

    # baseline table (existing embeddings) and enriched table (new embeddings)
    psql-exec "DROP TABLE IF EXISTS proto_base; DROP TABLE IF EXISTS proto_enr;"
    psql-exec "CREATE TABLE proto_base (symbol TEXT, kind TEXT, signature TEXT, embedding VECTOR(768));"
    psql-exec "CREATE TABLE proto_enr  (symbol TEXT, kind TEXT, signature TEXT, gloss TEXT, tags TEXT, embedding VECTOR(768));"

    let bvals = ($enriched | each {|r|
        "(" + ([(sql-str $r.symbol) (sql-str $r.kind) (sql-str $r.signature) ((sql-str $r.emb) + "::vector")] | str join ",") + ")"
    } | str join ",")
    psql-exec ("INSERT INTO proto_base (symbol,kind,signature,embedding) VALUES " + $bvals)

    let evals = ($enriched | each {|r|
        "(" + ([(sql-str $r.symbol) (sql-str $r.kind) (sql-str $r.signature) (sql-str $r.gloss) (sql-str $r.tags) ((sql-str $r.enr) + "::vector")] | str join ",") + ")"
    } | str join ",")
    psql-exec ("INSERT INTO proto_enr (symbol,kind,signature,gloss,tags,embedding) VALUES " + $evals)
    print $"built: proto_base & proto_enr with ($enriched | length) rows each."
}

def rank [table: string, qv: string, n: int = 5] {
    psql-query ($"SELECT symbol FROM ($table) ORDER BY embedding<=>'($qv)'::vector LIMIT ($n)")
        | lines | where {|x| not ($x | is-empty)}
}

def do-eval [] {
    print "# A/B: baseline (current index) vs enriched (gloss+tags)\n"
    mut bscore = 0
    mut escore = 0
    for row in $QUERIES {
        let search = (rephrase $row.q)
        let qv = (vec (embed $search | get 0))
        let b = (rank "proto_base" $qv 5)
        let e = (rank "proto_enr"  $qv 5)
        let brank = ($b | enumerate | where item == $row.want | get index.0? )
        let erank = ($e | enumerate | where item == $row.want | get index.0? )
        let bpos = (if $brank == null { "miss" } else { $"#($brank + 1)" })
        let epos = (if $erank == null { "miss" } else { $"#($erank + 1)" })
        if $brank != null { $bscore = $bscore + (5 - $brank) }
        if $erank != null { $escore = $escore + (5 - $erank) }
        print $'Q: "($row.q)"  want: ($row.want)'
        print $"   baseline ($bpos): ($b | str join ', ')"
        print $"   enriched ($epos): ($e | str join ', ')"
        print ""
    }
    print $"score \(higher=better, rank-weighted top5\): baseline ($bscore)  vs  enriched ($escore)"
}

def main [cmd: string = "eval"] {
    match $cmd {
        "build" => (do-build)
        "eval"  => (do-eval)
        "tags"  => (psql-json "SELECT symbol, gloss, tags FROM proto_enr ORDER BY symbol" | table -e)
        _ => (print "usage: nu nu/proto_tags.nu [build|eval|tags]")
    }
}
