#!/usr/bin/env bash
# zfact smoke test — asserts current std (run against the installed Zig).
# Signature substrings are version-specific; update when Zig std changes.
set -u
Z="$(dirname "$0")/bin/zfact"
fail=0
check() { # desc  query  expected-substring
  out="$("$Z" "$2" 2>&1)"
  if grep -qF -- "$3" <<<"$out"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected substring: $3)"; echo "$out" | head -4; fail=1
  fi
}

check "exact fn signature"        "Io.Reader.stream"   "pub fn stream(r: *Reader, w: *Writer"
check "managed+unmanaged append"  "ArrayList.append"   "gpa: Allocator"
check "doc comment captured"      "HashMap.put"        "Clobbers any existing data"
check "fuzzy fallback"            "crypto.ChaCha20"    "fuzzy: declared name contains the query"
check "one-hop @import resolve"   "crypto.ChaCha20IETF" "via @import"
check "stale namespace widens"    "fs.File.openFile"   "may be stale"
check "true negative is clean"    "Io.Reader.frobnicate" "no \`pub\` decl named"
check "cluster: name family"      "ArrayList.append"   "◆ family:"
check "cluster: AssumeCapacity"   "ArrayList.append"   "skips the capacity/alloc check"
check "cluster: see-also xref"    "HashMap.put"        "see also: \`getOrPut\`"

# --sig suppresses the cluster (hook mode)
if ./bin/zfact ArrayList.append --sig 2>&1 | grep -qF "◆ family:"; then
  echo "FAIL: --sig should suppress cluster"; fail=1
else
  echo "PASS: --sig suppresses cluster"
fi

# --- Layer B (semantic): only if ollama is up AND an index exists ---
if curl -s http://localhost:11434/api/tags >/dev/null 2>&1 \
   && [ "$(psql "postgresql:///llmlab?host=/tmp" -At -c 'SELECT count(*) FROM zig_api;' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
  out="$(./bin/zfact find "hash a password securely" --raw --limit 5 2>&1)"
  if grep -qiE "pwhash|strHash|password" <<<"$out"; then
    echo "PASS: semantic find (password hashing)"
  else
    echo "FAIL: semantic find returned no password-hash API"; echo "$out" | head -4; fail=1
  fi
  # rephrase bridge: a use-case query that fails raw should succeed with rephrase
  if curl -s http://localhost:11434/api/tags 2>/dev/null | grep -q "qwen2.5-coder"; then
    out="$(./bin/zfact find "read a line of text from stdin" --limit 4 2>&1)"
    if grep -qiE "delimiter|stream" <<<"$out"; then
      echo "PASS: rephrase bridges use-case -> mechanism"
    else
      echo "FAIL: rephrase did not surface delimiter/stream"; echo "$out" | head -5; fail=1
    fi
  else
    echo "SKIP: rephrase test (qwen2.5-coder not pulled)"
  fi
else
  echo "SKIP: Layer B semantic test (ollama down or index empty)"
fi

# --- zsnag (LLM footgun checker, compiled Zig) ---
zig build >/dev/null 2>&1 || { echo "FAIL: zig build"; fail=1; }
ZS=./zig-out/bin/zsnag
bad="$($ZS test_fixtures/bad.zig 2>&1)"
for r in R001 R002 R003 R004 R005 R006 R007 R008 R009 R010; do
  if grep -q "$r" <<<"$bad"; then echo "PASS: zsnag catches $r"; else echo "FAIL: zsnag missed $r"; fail=1; fi
done
$ZS test_fixtures/bad.zig >/dev/null 2>&1
[ $? -ne 0 ] && echo "PASS: zsnag exits non-zero on errors" || { echo "FAIL: zsnag should exit non-zero"; fail=1; }
clean="$($ZS test_fixtures/good.zig 2>&1)"
if [ -z "$clean" ]; then echo "PASS: zsnag clean on good file (no false positives)"; else echo "FAIL: zsnag false-positived on good.zig"; echo "$clean"; fail=1; fi
# real-code false-positive regression: method-named async/await + FixedBufferAllocator
fp="$($ZS test_fixtures/fp_regression.zig 2>&1)"
if grep -qE "R001|R008" <<<"$fp"; then echo "FAIL: zsnag false-positive regressed"; echo "$fp"; fail=1; else echo "PASS: zsnag no FP on real-code patterns (method async/await, FixedBufferAllocator)"; fi

[ "$fail" = 0 ] && echo "--- all passed ---" || echo "--- failures present ---"
exit $fail
