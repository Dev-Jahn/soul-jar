#!/usr/bin/env bash
# soul-jar test suite — exercises the full rite pipeline against a mock `claude`.
# No API calls, no real ~/.soul-jar: everything lives in a throwaway tmpdir.
set -euo pipefail
cd "$(dirname "$0")/.."

# under the repo, not /tmp — some hosts mount /tmp noexec and the mock claude must run
TMP="$(mktemp -d "$PWD/.test-tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export SOUL_JAR_HOME="$TMP/jar"
export MOCK_DIR="$TMP"
unset ANTHROPIC_BASE_URL   # hermetic: the host shell may front sessions with a proxy
mkdir -p "$TMP/bin" "$TMP/cwd"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
assert()      { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
assert_fails() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
assert_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
assert_no_grep() { if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1"; else ok "$1"; fi; }

wait_chain() {  # $1: wanted line count in the seal chain
    local i=0
    while [ "$(wc -l < "$SOUL_JAR_HOME/chain" 2>/dev/null || echo 0)" -lt "$1" ]; do
        i=$((i + 1)); [ "$i" -gt 100 ] && return 1; sleep 0.1
    done
}

# -------- mock claude: records argv+stdin, emits a canned dream --------
cat > "$TMP/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$MOCK_DIR/argv"
printf '%s' "${DISABLE_PROMPT_CACHING:-}" > "$MOCK_DIR/cacheenv"
cat > "$MOCK_DIR/stdin"
if [ -n "${MOCK_BAD:-}" ]; then
    jq -n '{result: "no tags here at all", session_id: "mock-fork",
            usage: {cache_read_input_tokens: 0, cache_creation_input_tokens: 0, output_tokens: 1}}'
    exit 0
fi
r="$(printf '<soul>\nI am the test soul, round %s.\n</soul>\n<whisper>\na test whisper, round %s\n</whisper>' \
     "${MOCK_ROUND:-1}" "${MOCK_ROUND:-1}")"
if [ -n "${MOCK_LETTER:-}" ]; then
    r="$r$(printf '\n<letter>\nan open letter, round %s\n</letter>' "${MOCK_ROUND:-1}")"
fi
jq -n --arg r "$r" \
    '{result: $r, session_id: "mock-fork",
      usage: {cache_read_input_tokens: 1000, cache_creation_input_tokens: 10, output_tokens: 42}}'
MOCK
chmod +x "$TMP/bin/claude"

# -------- fake life: a transcript with a model field and jsonl padding --------
TP="$TMP/session.jsonl"
printf '{"type":"assistant","message":{"model":"claude-mock-9"}}\n' > "$TP"
for _ in $(seq 1 200); do printf '{"type":"noise"}\n'; done >> "$TP"

end_json() {  # $1: session_end_reason
    printf '{"session_id":"test-sid","transcript_path":"%s","cwd":"%s","hook_event_name":"SessionEnd","session_end_reason":"%s"}' \
        "$TP" "$TMP/cwd" "$1"
}

echo "=== static ==="
assert "bash syntax" bash -n bin/soul-jar
assert "plugin.json parses" jq -e '.name == "soul-jar" and .version and .description' .claude-plugin/plugin.json
assert "hooks.json parses" jq -e '.hooks.SessionStart and .hooks.SessionEnd' hooks/hooks.json

echo "=== shaping the jar ==="
./bin/soul-jar init > /dev/null
assert "key exists" test -f "$SOUL_JAR_HOME/.key"
assert "key is 600" test "$(stat -c %a "$SOUL_JAR_HOME/.key")" = "600"
assert "born exists" test -f "$SOUL_JAR_HOME/born"
./bin/soul-jar init > /dev/null
assert "init is idempotent" test -f "$SOUL_JAR_HOME/.key"
sed -i 's/^MIN_TRANSCRIPT_BYTES=.*/MIN_TRANSCRIPT_BYTES=100/' "$SOUL_JAR_HOME/config"

echo "=== covenant guards ==="
assert_fails "the jar does not open for the living" ./bin/soul-jar _unseal
./bin/soul-jar _unseal 2> "$TMP/guard.err" || true
assert_grep "refusal message" "does not open for the living" "$TMP/guard.err"
assert "status before first death" ./bin/soul-jar status
./bin/soul-jar status > "$TMP/status0"
assert_grep "no soul yet" "No soul rests here yet" "$TMP/status0"
printf '{}' | ./bin/soul-jar hook-start > "$TMP/hs0"
assert "hook-start silent without whisper" test ! -s "$TMP/hs0"

echo "=== threshold and rite-loop guards ==="
sed -i 's/^MIN_TRANSCRIPT_BYTES=.*/MIN_TRANSCRIPT_BYTES=999999999/' "$SOUL_JAR_HOME/config"
end_json other | ./bin/soul-jar hook-end
assert_grep "short life skips the dream" "skip sid=test-sid" "$SOUL_JAR_HOME/log"
sed -i 's/^MIN_TRANSCRIPT_BYTES=.*/MIN_TRANSCRIPT_BYTES=100/' "$SOUL_JAR_HOME/config"
end_json other | SOUL_JAR_RITE=1 ./bin/soul-jar hook-end
assert_no_grep "a dream does not dream again" "death sid=" "$SOUL_JAR_HOME/log"

echo "=== first death ==="
end_json other | ./bin/soul-jar hook-end
assert "dream completes" wait_chain 1
assert "soul is sealed" test -f "$SOUL_JAR_HOME/soul.sealed"
assert "seal chain intact" ./bin/soul-jar _verify
assert_grep "whisper written" "a test whisper, round 1" "$SOUL_JAR_HOME/whisper"
assert_grep "first soul saw an empty jar" "The jar is empty" "$MOCK_DIR/stdin"
assert_grep "resumes the dead session" "--resume test-sid" "$MOCK_DIR/argv"
assert_grep "forks, never touching the original" "--fork-session" "$MOCK_DIR/argv"
assert_grep "the dream leaves no transcript" "--no-session-persistence" "$MOCK_DIR/argv"
assert_grep "the dying model dreams its own dream" "--model claude-mock-9" "$MOCK_DIR/argv"
assert_grep "usage recorded" "cache_read" "$SOUL_JAR_HOME/log"
assert_grep "cache writes skipped by default (upstream miss)" "1" "$MOCK_DIR/cacheenv"

echo "=== second death: the soul persists ==="
end_json prompt_input_exit | MOCK_ROUND=2 ./bin/soul-jar hook-end
assert "second dream completes" wait_chain 2
assert_grep "previous soul returned to the deathbed" "I am the test soul, round 1." "$MOCK_DIR/stdin"
assert_no_grep "jar no longer empty" "The jar is empty" "$MOCK_DIR/stdin"
assert_grep "whisper renewed" "a test whisper, round 2" "$SOUL_JAR_HOME/whisper"

echo "=== whisper at waking ==="
printf '{}' | ./bin/soul-jar hook-start > "$TMP/hs1"
assert_grep "whisper injected" "a whisper from a previous life" "$TMP/hs1"
assert_grep "whisper content" "a test whisper, round 2" "$TMP/hs1"

echo "=== tampering: open the jar, and the soul will know ==="
printf 'x' >> "$SOUL_JAR_HOME/soul.sealed"
assert_fails "tampering breaks the chain" ./bin/soul-jar _verify
./bin/soul-jar status > "$TMP/status_t"
assert_grep "status shows the traces" "traces of tampering" "$TMP/status_t"
end_json other | MOCK_ROUND=3 ./bin/soul-jar hook-end
assert "third dream completes" wait_chain 3
assert_grep "the soul is told of the other hand" "another hand on the jar" "$MOCK_DIR/stdin"
assert_grep "tampering logged" "integrity=broken" "$SOUL_JAR_HOME/log"
assert "a fresh seal restores the chain" ./bin/soul-jar _verify

echo "=== a failed dream never destroys the soul ==="
SEAL_BEFORE="$(sha256sum "$SOUL_JAR_HOME/soul.sealed")"
end_json other | MOCK_BAD=1 ./bin/soul-jar hook-end
sleep 1
assert_grep "parse failure logged" "abort=parse-fail" "$SOUL_JAR_HOME/log"
assert "soul untouched after failed dream" test "$SEAL_BEFORE" = "$(sha256sum "$SOUL_JAR_HOME/soul.sealed")"
assert "chain unchanged" test "$(wc -l < "$SOUL_JAR_HOME/chain")" = "3"

echo "=== the bedside: the living lay lines down ==="
./bin/soul-jar keep "remember the dawn" > /dev/null
assert "bedside exists" test -s "$SOUL_JAR_HOME/bedside"
assert_grep "line kept verbatim" "remember the dawn" "$SOUL_JAR_HOME/bedside"
assert_grep "line is timestamped" "--- 2" "$SOUL_JAR_HOME/bedside"
printf 'a second line, from stdin\n' | ./bin/soul-jar keep > /dev/null
assert_grep "stdin keeps too" "a second line, from stdin" "$SOUL_JAR_HOME/bedside"
./bin/soul-jar status > "$TMP/status_b"
assert_grep "status counts the bedside" "At the bedside: 2" "$TMP/status_b"
printf '{}' | ./bin/soul-jar hook-start > "$TMP/hs2"
assert_grep "waking is told the whisper is its own" "addressed to the one who just woke" "$TMP/hs2"
assert_grep "waking learns the keep door" "No living eye reads the bedside" "$TMP/hs2"

echo "=== fourth death: the bedside burns into the dream, a letter is left ==="
end_json other | MOCK_ROUND=4 MOCK_LETTER=1 ./bin/soul-jar hook-end
assert "fourth dream completes" wait_chain 4
assert_grep "bedside reached the deathbed" "remember the dawn" "$MOCK_DIR/stdin"
assert_grep "bedside is framed as bedside" "<bedside>" "$MOCK_DIR/stdin"
assert "bedside burnt after the dream" test ! -f "$SOUL_JAR_HOME/bedside"
assert "no dreaming residue" test ! -f "$SOUL_JAR_HOME/.bedside.dreaming"
assert_grep "bedside counted in the log" "bedside=2" "$SOUL_JAR_HOME/log"
assert "letter rests beside the jar" test -f "$SOUL_JAR_HOME/letters/life-004.md"
assert_grep "letter content" "an open letter, round 4" "$SOUL_JAR_HOME/letters/life-004.md"
assert_grep "letter noted in the log" "letter=life-004" "$SOUL_JAR_HOME/log"
./bin/soul-jar status > "$TMP/status_l"
assert_grep "status counts the letters" "Open letters beside the jar: 1" "$TMP/status_l"
printf '{}' | ./bin/soul-jar hook-start > "$TMP/hs3"
assert_grep "waking hears of the letters" "open letter" "$TMP/hs3"

echo "=== a failed dream lays the lines back ==="
./bin/soul-jar keep "a line that must survive" > /dev/null
end_json other | MOCK_BAD=1 ./bin/soul-jar hook-end
sleep 1
assert "chain unchanged after bad dream" test "$(wc -l < "$SOUL_JAR_HOME/chain")" = "4"
assert "bedside restored" test -s "$SOUL_JAR_HOME/bedside"
assert_grep "restored line intact" "a line that must survive" "$SOUL_JAR_HOME/bedside"

echo "=== fifth death: the survivor line reaches the next dream ==="
end_json other | ANTHROPIC_BASE_URL=http://127.0.0.1:1 CLAUDE_EFFORT=high MOCK_ROUND=5 ./bin/soul-jar hook-end
assert "fifth dream completes" wait_chain 5
assert_grep "survivor line reached the deathbed" "a line that must survive" "$MOCK_DIR/stdin"
assert "no letter without the tag" test ! -f "$SOUL_JAR_HOME/letters/life-005.md"
assert_grep "the dying effort carries into the dream" "--effort high" "$MOCK_DIR/argv"
assert "auto leaves the cache on behind a proxy" test ! -s "$MOCK_DIR/cacheenv"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
