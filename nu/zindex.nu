#!/usr/bin/env nu
# zindex — build the Layer B semantic index over the Zig std API.
#
# The Zig binary (`zfact --dump`) does the Zig-source extraction; this script does
# the glue: embed each decl with ollama and upsert into the `zig_api` postgres
# table, STAMPED with the current Zig version. This is a DERIVED cache — the
# installed std stays the source of truth. Re-run after any Zig upgrade.
#
#   nu nu/zindex.nu                 (re)build the index (documented decls)
#   nu nu/zindex.nu --all           include undocumented decls too (~4x larger)
#   nu nu/zindex.nu --module crypto only decls whose path contains 'crypto'
#   nu nu/zindex.nu --limit 300     index only the first N decls (smoke test)
use lib.nu *

def sql-str [s: string] {
    "'" + ($s | str replace --all "'" "''") + "'"
}

def main [
    --all              # include undocumented decls (default: documented only)
    --module: string   # only files whose path contains this string
    --limit: int       # cap the number of decls (smoke test)
] {
    let zf = ($env.FILE_PWD | path dirname | path join zig-out bin zfact)
    if not ($zf | path exists) {
        print $"zfact binary not found at ($zf) — run: zig build"
        return
    }
    let ze = (zig-env)
    let ver = $ze.ver
    let scope = (if $all { "[--all]" } else { "[documented only]" })
    print $"zig ($ver)  std=($ze.std)  ($scope)"

    # extraction happens in Zig; we just parse the JSONL it emits
    mut dump_args = ["--dump"]
    if $all { $dump_args = ($dump_args | append "--all") }
    if ($module | is-not-empty) { $dump_args = ($dump_args | append ["--module" $module]) }
    mut decls = (^$zf ...$dump_args | lines | where {|x| not ($x | is-empty)} | each {|l| $l | from json })
    if ($limit | is-not-empty) { $decls = ($decls | first $limit) }
    let modnote = (if ($module | is-not-empty) { $" \(module=($module))" } else { "" })
    print $"extracted ($decls | length) decls($modnote)"
    if ($decls | is-empty) { return }

    # clear this version's rows first (scoped to the module if given)
    if ($module | is-not-empty) {
        psql-exec $"DELETE FROM zig_api WHERE zig_version=(sql-str $ver) AND file LIKE (sql-str $'%($module)%')"
    } else {
        psql-exec $"DELETE FROM zig_api WHERE zig_version=(sql-str $ver)"
    }

    let total = ($decls | length)
    mut done = 0
    for batch in ($decls | chunks 64) {
        let texts = ($batch | each {|d| $"($d.namespace).($d.symbol) \(($d.kind))\n($d.signature)\n($d.doc)" })
        let embs = (embed $texts)
        let values = ($batch | enumerate | each {|it|
            let d = $it.item
            let v = (vec ($embs | get $it.index))
            "(" + ([
                (sql-str $ver) (sql-str $d.symbol) (sql-str $d.namespace) (sql-str $d.kind)
                (sql-str $d.signature) (sql-str $d.doc) (sql-str $d.file) ($d.line | into string)
                ((sql-str $v) + "::vector")
            ] | str join ",") + ")"
        } | str join ",")
        let sql = ("INSERT INTO zig_api (zig_version,symbol,namespace,kind,signature,doc,file,line,embedding) VALUES " +
            $values +
            " ON CONFLICT (zig_version,file,line) DO UPDATE SET symbol=EXCLUDED.symbol, signature=EXCLUDED.signature, doc=EXCLUDED.doc, embedding=EXCLUDED.embedding")
        psql-exec $sql
        $done = ($done + ($batch | length))
        print -n $"\r  embedded ($done)/($total)"
    }
    print $"\ndone: ($done) decls indexed for zig ($ver)"
}
