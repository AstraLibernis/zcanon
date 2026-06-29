#!/usr/bin/env nu
# zmap — build zforge's semantic index from ZEPHEM's verified TSV datasets.
#
# Where zindex.nu feeds the index from a live `zfact --dump` (partial, per-symbol),
# zmap feeds it from zephem's data/std/*.tsv — the COMPLETE, self-verified std map
# (16k decls, parse-based so poison decls survive), de-duplicated via canon, and
# carrying richer provenance (alias target, parse/reflect witness). It joins
# nodes+sigs+docs+canon+callcard into one record per decl, embeds with ollama, and
# upserts into the `zig_map` table (sql/schema_zig_map.sql), stamped with the Zig
# version zephem pinned. A DERIVED cache — regenerate zephem against the live
# toolchain (build_std.nu) on any Zig upgrade, then re-run this.
#
#   nu nu/zmap.nu --dump --limit 20      transform only, print JSONL (NO db/ollama)
#   nu nu/zmap.nu                         (re)build the index (decls with a sig or doc)
#   nu nu/zmap.nu --all                   include bare decls too (every node)
#   nu nu/zmap.nu --module crypto         only paths containing 'crypto'
#   nu nu/zmap.nu --data /path/to/std     point at a different zephem data dir
use lib.nu *

# Default zephem data dir: $ZEPHEM_DATA, else ~/projects/zephem/data/std.
def zephem-dir [] {
    $env.ZEPHEM_DATA? | default ([$env.HOME projects zephem data std] | path join)
}

def build-records [ddir: string, all: bool, module: string] {
    let nodes = (open ($ddir | path join nodes.tsv))
    let sigs  = (open ($ddir | path join sigs.tsv))                       # path sig
    let docs  = (open ($ddir | path join docs.tsv))                       # path doc
    let canon = (try { open ($ddir | path join canon.tsv) | select path canon } catch { [] })
    let cards = (try { open ($ddir | path join callcard.tsv) | select path witness } catch { [] })

    # `file` is left empty in v1: it is non-essential here (the key is `path`, and
    # the embedding text uses namespace/symbol/kind/sig/doc, not file). Populate it
    # precisely once zephem emits per-decl source location (file+line) — its next
    # parser step, which this index is exactly the consumer for.
    mut rows = ($nodes | select path kind name
        | join --left $sigs path
        | join --left $docs path
        | join --left $canon path
        | join --left $cards path)
    if ($module | is-not-empty) { $rows = ($rows | where path =~ $module) }
    let recs = ($rows | each {|r| {
        path:      $r.path
        namespace: ($r.path | split row '.' | drop | str join '.')
        symbol:    $r.name
        kind:      $r.kind
        sig:       ($r.sig?     | default '')
        doc:       ($r.doc?     | default '')
        file:      ''
        canon:     ($r.canon?   | default '')
        witness:   ($r.witness? | default '')
    }})
    if $all { $recs } else { $recs | where {|r| ($r.sig | is-not-empty) or ($r.doc | is-not-empty) } }
}

def main [
    --data: string     # zephem data dir (default: ~/projects/zephem/data/std)
    --all              # include decls with neither signature nor doc
    --module: string   # only paths containing this substring
    --limit: int       # cap the number of decls (smoke test)
    --dump             # print the records as JSONL and exit (no ollama/postgres)
] {
    let ddir = ($data | default (zephem-dir))
    if not ($ddir | path join nodes.tsv | path exists) {
        print -e $"zephem data not found at ($ddir) — clone zephem and run `nu scripts/build_std.nu`"
        return
    }
    # PINNED reads e.g. "zig 0.16.0"; normalise to the bare version ("0.16.0") so it
    # matches the zig_version that zindex.nu writes (from `zig env`).
    let pinned = ($ddir | path join PINNED)
    let ver = (if ($pinned | path exists) {
        open $pinned | str trim | split row ' ' | last
    } else { (zig-env).ver })

    mut recs = (build-records $ddir $all ($module | default ''))
    if ($limit | is-not-empty) { $recs = ($recs | first $limit) }
    let modnote = (if ($module | is-not-empty) { $" \(module=($module))" } else { "" })
    print -e $"zig ($ver)  zephem=($ddir)  decls=($recs | length)($modnote)"
    if ($recs | is-empty) { return }

    if $dump {
        $recs | each {|r| $r | to json --raw } | str join (char nl) | print
        return
    }

    # clear this version's rows (scoped to module if given), then embed + upsert
    if ($module | is-not-empty) {
        psql-exec $"DELETE FROM zig_map WHERE zig_version='($ver)' AND path LIKE '%($module)%'"
    } else {
        psql-exec $"DELETE FROM zig_map WHERE zig_version='($ver)'"
    }

    # `into string` first: Nushell auto-types TSV cells, so a numeric-looking doc or
    # signature can arrive as int/float — coerce before quoting.
    def sql-str [s] { "'" + ($s | into string | str replace --all "'" "''") + "'" }
    let total = ($recs | length)
    mut done = 0
    for batch in ($recs | chunks 64) {
        let texts = ($batch | each {|d| $"($d.namespace).($d.symbol) \(($d.kind))\n($d.sig)\n($d.doc)" })
        let embs = (embed $texts)
        let values = ($batch | enumerate | each {|it|
            let d = $it.item
            let v = (vec ($embs | get $it.index))
            "(" + ([
                (sql-str $ver) (sql-str $d.path) (sql-str $d.namespace) (sql-str $d.symbol)
                (sql-str $d.kind) (sql-str $d.sig) (sql-str $d.doc) (sql-str $d.file)
                (sql-str $d.canon) (sql-str $d.witness) ((sql-str $v) + "::vector")
            ] | str join ",") + ")"
        } | str join ",")
        let sql = ("INSERT INTO zig_map (zig_version,path,namespace,symbol,kind,signature,doc,file,canon,witness,embedding) VALUES " +
            $values +
            " ON CONFLICT (zig_version,path) DO UPDATE SET symbol=EXCLUDED.symbol, kind=EXCLUDED.kind, signature=EXCLUDED.signature, doc=EXCLUDED.doc, file=EXCLUDED.file, canon=EXCLUDED.canon, witness=EXCLUDED.witness, embedding=EXCLUDED.embedding")
        psql-exec $sql
        $done = ($done + ($batch | length))
        print -n $"\r  embedded ($done)/($total)"
    }
    print $"\ndone: ($done) decls indexed for zig ($ver) into zig_map"
}
