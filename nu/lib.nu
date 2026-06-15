# lib.nu — shared glue for zforge's Nushell tools.
# This is the "cannot be Zig" half: ollama HTTP + postgres/pgvector. The Zig
# binaries (zfact, zsnag) do the Zig-source analysis; these helpers do the
# embedding + database plumbing for the semantic layer.

# Installed Zig's std dir + version (the source of truth — never snapshot it).
export def zig-env [] {
    let out = (^zig env | str join)
    {
        std: ($out | parse --regex '\.std_dir\s*=\s*"(?<v>[^"]+)"' | get v.0)
        ver: ($out | parse --regex '\.version\s*=\s*"(?<v>[^"]+)"' | get v.0)
    }
}

# Postgres DSN (override with $env.LLMLAB_DSN).
export def dsn [] {
    $env.LLMLAB_DSN? | default "postgresql:///llmlab?host=/tmp"
}

# Embed text(s) with ollama nomic-embed-text. Pass a string or a list of strings;
# returns a list of 768-dim vectors (one per input).
export def embed [input] {
    let r = (http post --content-type application/json http://localhost:11434/api/embed {
        model: "nomic-embed-text"
        input: $input
    })
    $r.embeddings
}

# Reasoning-in-front-of-similarity: translate a use-case query into the std's
# mechanism vocabulary with a local model, so "read a line from stdin" finds the
# delimiter readers. Returns the rephrased string (or the original on failure).
export def rephrase [query: string] {
    let prompt = ("Convert a programming intent into GENERIC mechanism keywords describing the " +
        "underlying operation, to search a standard library's docs. Do NOT name any " +
        "language or function. Use plain technical terms only.\n" +
        "Example: 'read a line from stdin' => read bytes from input stream until newline delimiter\n" +
        "Example: 'make a string uppercase' => convert ascii letters to upper case\n" +
        "Example: 'grow a dynamic array' => increase list capacity, append elements, reallocate buffer\n" +
        $"Intent: '($query)' =>")
    try {
        let r = (http post --content-type application/json http://localhost:11434/api/generate {
            model: "qwen2.5-coder:3b"
            prompt: $prompt
            stream: false
            options: {temperature: 0.0, num_predict: 40}
        })
        let line = ($r.response | str trim | lines | first | default "" | str trim --char '"' | str trim)
        if ($line | is-empty) { $query } else { $line }
    } catch {
        $query
    }
}

# A list of floats -> a pgvector literal, e.g. "[0.1,0.2,...]".
export def vec [e: list] {
    $"[($e | each {|v| $v | into string } | str join ',')]"
}

# Run a SELECT and return raw psql output (tuples-only, unaligned).
export def psql-query [sql: string] {
    ^psql (dsn) -At -c $sql
}

# Execute SQL piped via stdin (avoids ARG_MAX on big multi-row INSERTs).
export def psql-exec [sql: string] {
    $sql | ^psql (dsn) -q -v ON_ERROR_STOP=1
}

# Run a SELECT and get back parsed records (wraps the query as json_agg).
export def psql-json [sql: string] {
    psql-query $"SELECT coalesce\(json_agg\(row_to_json\(t)),'[]'::json) FROM \(($sql)) t" | from json
}
