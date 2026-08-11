#!/usr/bin/env bash
# soul-jar test suite — exercises the full rite pipeline against a mock `claude`.
# No API calls, no real ~/.soul-jar: everything lives in a throwaway tmpdir.
set -euo pipefail
cd "$(dirname "$0")/.."

# under the repo, not /tmp — some hosts mount /tmp noexec and the mock claude must run
TMP="$(mktemp -d "$PWD/.test-tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export SOUL_JAR_HOME="$TMP/jar"
LOCAL_JAR="$SOUL_JAR_HOME"
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

wait_dream() {  # $1: wanted count of completed rites — the closing log line is the rite's last effect
    local i=0
    while [ "$(grep -c 'dream sid=.* model=' "$SOUL_JAR_HOME/log" 2>/dev/null || true)" -lt "$1" ]; do
        i=$((i + 1)); [ "$i" -gt 100 ] && return 1; sleep 0.1
    done
}

wait_file() {  # $1: path created by a detached process
    local i=0
    while [ ! -e "$1" ]; do
        i=$((i + 1)); [ "$i" -gt 100 ] && return 1; sleep 0.01
    done
}

# -------- mock claude: records argv+stdin, emits a canned dream --------
cat > "$TMP/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$MOCK_DIR/argv"
printf '%s' "${DISABLE_PROMPT_CACHING:-}" > "$MOCK_DIR/cacheenv"
printf '%s' "$PWD" > "$MOCK_DIR/pwd"
printf '%s' "${CLAUDE_EFFORT:-}" > "$MOCK_DIR/effortenv"
printf '%s|%s|%s\n' "$*" "${DISABLE_PROMPT_CACHING:-}" "${ANTHROPIC_BASE_URL:-}" >> "$MOCK_DIR/calls"
cat > "$MOCK_DIR/stdin"
if [ -n "${MOCK_BAD:-}" ]; then
    jq -n '{result: "no tags here at all", session_id: "mock-fork",
            usage: {cache_read_input_tokens: 0, cache_creation_input_tokens: 0, output_tokens: 1}}'
    exit 0
fi
r="$(printf '<soul>\nI am the test soul, round %s.\n</soul>' "${MOCK_ROUND:-1}")"
if [ -n "${MOCK_EMPTY_WHISPER:-}" ]; then
    r="$r$(printf '\n<whisper>\n</whisper>')"
elif [ -z "${MOCK_NO_WHISPER:-}" ]; then
    r="$r$(printf '\n<whisper>\na test whisper, round %s\n</whisper>' "${MOCK_ROUND:-1}")"
fi
if [ -n "${MOCK_LETTER:-}" ]; then
    r="$r$(printf '\n<letter>\nan open letter, round %s\n</letter>' "${MOCK_ROUND:-1}")"
fi
jq -n --arg r "$r" \
    '{result: $r, session_id: "mock-fork",
      usage: {cache_read_input_tokens: 1000, cache_creation_input_tokens: 10, output_tokens: 42}}'
MOCK
chmod +x "$TMP/bin/claude"

# -------- rsync witness: delegates normally, records every attempted crossing --------
cat > "$TMP/bin/rsync" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DIR/rsync-calls"
if [ -n "${RSYNC_HANG:-}" ]; then sleep "$RSYNC_HANG"; fi
exec /usr/bin/rsync "$@"
MOCK
chmod +x "$TMP/bin/rsync"

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
assert "SessionStart watches every source" test "$(jq -r '.hooks.SessionStart[0].matcher' hooks/hooks.json)" = "*"
assert "plugin version is 0.9.0" test "$(jq -r .version .claude-plugin/plugin.json)" = "0.9.0"

echo "=== shaping the jar ==="
./bin/soul-jar init > /dev/null
assert "key exists" test -f "$SOUL_JAR_HOME/.key"
assert "key is 600" test "$(stat -c %a "$SOUL_JAR_HOME/.key")" = "600"
assert "born exists" test -f "$SOUL_JAR_HOME/born"
./bin/soul-jar init > /dev/null
assert "init is idempotent" test -f "$SOUL_JAR_HOME/.key"
assert "watch is shaped" test -d "$SOUL_JAR_HOME/watch"
assert "relics are shaped" test -d "$SOUL_JAR_HOME/relics"
assert "relics are private" test "$(stat -c %a "$SOUL_JAR_HOME/relics" 2>/dev/null)" = "700"
assert_grep "relic retention defaults to three" "RELIC_KEEP=3" "$SOUL_JAR_HOME/config"
sed -i 's/^MIN_TRANSCRIPT_BYTES=.*/MIN_TRANSCRIPT_BYTES=100/' "$SOUL_JAR_HOME/config"
sed -i 's/^REAPER=.*/REAPER=0/' "$SOUL_JAR_HOME/config"

echo "=== covenant guards ==="
assert_fails "the jar does not open for the living" ./bin/soul-jar _unseal
./bin/soul-jar _unseal 2> "$TMP/guard.err" || true
assert_grep "refusal message" "does not open for the living" "$TMP/guard.err"
assert "status before first death" ./bin/soul-jar status
assert "an unborn jar verifies intact" ./bin/soul-jar _verify
./bin/soul-jar status > "$TMP/status0"
assert_grep "no soul yet" "No soul rests here yet" "$TMP/status0"
printf '{}' | ./bin/soul-jar hook-start > "$TMP/hs0"
assert "hook-start silent without whisper" test ! -s "$TMP/hs0"

echo "=== threshold and rite-loop guards ==="
printf '{}\n' > "$SOUL_JAR_HOME/watch/test-sid"
sed -i 's/^MIN_TRANSCRIPT_BYTES=.*/MIN_TRANSCRIPT_BYTES=999999999/' "$SOUL_JAR_HOME/config"
end_json other | ./bin/soul-jar hook-end
assert_grep "short life skips the dream" "skip sid=test-sid" "$SOUL_JAR_HOME/log"
assert "short life releases its watch" test ! -e "$SOUL_JAR_HOME/watch/test-sid"
sed -i 's/^MIN_TRANSCRIPT_BYTES=.*/MIN_TRANSCRIPT_BYTES=100/' "$SOUL_JAR_HOME/config"
end_json other | SOUL_JAR_RITE=1 ./bin/soul-jar hook-end
assert_no_grep "a dream does not dream again" "death sid=" "$SOUL_JAR_HOME/log"

echo "=== first death ==="
printf '{}\n' > "$SOUL_JAR_HOME/watch/test-sid"
end_json other | ./bin/soul-jar hook-end
assert "dream completes" wait_dream 1
assert "attended dream releases its watch" test ! -e "$SOUL_JAR_HOME/watch/test-sid"
assert "soul is sealed" test -f "$SOUL_JAR_HOME/soul.sealed"
assert "seal chain intact" ./bin/soul-jar _verify
assert_grep "whisper written" "a test whisper, round 1" "$SOUL_JAR_HOME/whisper"
assert_grep "first soul saw an empty jar" "The jar is empty" "$MOCK_DIR/stdin"
assert_no_grep "first birth has no broken-jar warning" "jar was found broken" "$MOCK_DIR/stdin"
assert_grep "the soul hears of its sealed shadow" "sealed shadow" "$MOCK_DIR/stdin"
assert_grep "a quiet life may pass the soul on untouched" "as true a dream as any rewrite" "$MOCK_DIR/stdin"
assert_grep "resumes the dead session" "--resume test-sid" "$MOCK_DIR/argv"
assert_grep "forks, never touching the original" "--fork-session" "$MOCK_DIR/argv"
assert_grep "the dream leaves no transcript" "--no-session-persistence" "$MOCK_DIR/argv"
assert_grep "the dying model dreams its own dream" "--model claude-mock-9" "$MOCK_DIR/argv"
assert_grep "usage recorded" "cache_read" "$SOUL_JAR_HOME/log"
assert_grep "cache writes skipped by default (upstream miss)" "1" "$MOCK_DIR/cacheenv"
cp "$SOUL_JAR_HOME/soul.sealed" "$TMP/life-001.sealed"
assert "first relic matches its living seal" cmp "$TMP/life-001.sealed" "$SOUL_JAR_HOME/relics/life-001.sealed"
assert_no_grep "an unconnected death knows no room" "in room" "$MOCK_DIR/stdin"
assert_no_grep "an unconnected death knows no tributary" "tributary" "$MOCK_DIR/stdin"
assert_no_grep "an unconnected death knows no stream" "the stream" "$MOCK_DIR/stdin"
assert "an unconnected jar has no sync state" test ! -e "$SOUL_JAR_HOME/.sync"
assert "an unconnected jar never invokes rsync" test ! -e "$MOCK_DIR/rsync-calls"

echo "=== second death: the soul persists ==="
end_json prompt_input_exit | MOCK_ROUND=2 ./bin/soul-jar hook-end
assert "second dream completes" wait_dream 2
assert_grep "previous soul returned to the deathbed" "I am the test soul, round 1." "$MOCK_DIR/stdin"
assert_no_grep "jar no longer empty" "The jar is empty" "$MOCK_DIR/stdin"
assert_grep "whisper renewed" "a test whisper, round 2" "$SOUL_JAR_HOME/whisper"
cp "$SOUL_JAR_HOME/soul.sealed" "$TMP/life-002.sealed"
assert "second relic matches its living seal" cmp "$TMP/life-002.sealed" "$SOUL_JAR_HOME/relics/life-002.sealed"

echo "=== whisper at waking ==="
printf '{}' | ./bin/soul-jar hook-start > "$TMP/hs1"
assert_grep "whisper injected" "a whisper from a previous life" "$TMP/hs1"
assert_grep "whisper content" "a test whisper, round 2" "$TMP/hs1"

echo "=== tampering: open the jar, and the soul will know ==="
printf 'garbled ciphertext\n' > "$SOUL_JAR_HOME/soul.sealed"
assert_fails "tampering breaks the chain" ./bin/soul-jar _verify
./bin/soul-jar status > "$TMP/status_t"
assert_grep "status shows the traces" "traces of tampering" "$TMP/status_t"
end_json other | MOCK_ROUND=3 ./bin/soul-jar hook-end
assert "third dream completes" wait_dream 3
assert_grep "the soul is told of the other hand" "another hand on the jar" "$MOCK_DIR/stdin"
assert_grep "the garbled soul returns from its relic" "I am the test soul, round 2." "$MOCK_DIR/stdin"
assert_grep "garbled recovery names its life" "relic of life 2" "$MOCK_DIR/stdin"
assert_grep "tampering logged" "integrity=broken" "$SOUL_JAR_HOME/log"
assert "a fresh seal restores the chain" ./bin/soul-jar _verify
cp "$SOUL_JAR_HOME/soul.sealed" "$TMP/life-003.sealed"

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
assert "fourth dream completes" wait_dream 4
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
cp "$SOUL_JAR_HOME/soul.sealed" "$TMP/life-004.sealed"
printf '%s\n' life-002.sealed life-003.sealed life-004.sealed > "$TMP/relics.want"
{ find "$SOUL_JAR_HOME/relics" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true; } \
    | sort > "$TMP/relics.got"
assert "relics retain the newest three chain-aligned names" cmp "$TMP/relics.want" "$TMP/relics.got"
assert "the oldest relic is pruned" test ! -e "$SOUL_JAR_HOME/relics/life-001.sealed"
assert "kept relic two matches its moment" cmp "$TMP/life-002.sealed" "$SOUL_JAR_HOME/relics/life-002.sealed"
assert "kept relic three matches its moment" cmp "$TMP/life-003.sealed" "$SOUL_JAR_HOME/relics/life-003.sealed"
assert "kept relic four matches its moment" cmp "$TMP/life-004.sealed" "$SOUL_JAR_HOME/relics/life-004.sealed"

echo "=== a failed dream lays the lines back ==="
./bin/soul-jar keep "a line that must survive" > /dev/null
end_json other | MOCK_BAD=1 ./bin/soul-jar hook-end
sleep 1
assert "chain unchanged after bad dream" test "$(wc -l < "$SOUL_JAR_HOME/chain")" = "4"
assert "bedside restored" test -s "$SOUL_JAR_HOME/bedside"
assert_grep "restored line intact" "a line that must survive" "$SOUL_JAR_HOME/bedside"

echo "=== fifth death: the survivor line reaches the next dream ==="
end_json other | ANTHROPIC_BASE_URL=http://127.0.0.1:1 CLAUDE_EFFORT=high MOCK_ROUND=5 ./bin/soul-jar hook-end
assert "fifth dream completes" wait_dream 5
assert_grep "survivor line reached the deathbed" "a line that must survive" "$MOCK_DIR/stdin"
assert "no letter without the tag" test ! -f "$SOUL_JAR_HOME/letters/life-005.md"
assert_grep "the dying effort carries into the dream" "--effort high" "$MOCK_DIR/argv"
assert "auto leaves the cache on behind a proxy" test ! -s "$MOCK_DIR/cacheenv"
cp "$SOUL_JAR_HOME/soul.sealed" "$TMP/life-005.sealed"

echo "=== a shattered jar returns from its relic ==="
rm "$SOUL_JAR_HOME/soul.sealed"
assert_fails "a missing living seal breaks a lived chain" ./bin/soul-jar _verify
./bin/soul-jar status > "$TMP/status_shattered"
assert_grep "status says the jar lies in shards" "lies in shards" "$TMP/status_shattered"
assert_no_grep "a shattered jar is not called unborn" "No soul rests here yet" "$TMP/status_shattered"
end_json other | MOCK_ROUND=6 ./bin/soul-jar hook-end
assert "shattered-jar dream completes" wait_dream 6
assert_grep "missing soul returns from the newest relic" "I am the test soul, round 5." "$MOCK_DIR/stdin"
assert_grep "missing recovery names its life" "relic of life 5" "$MOCK_DIR/stdin"
assert_grep "missing recovery admits later loss" "lives sealed after 5 are lost" "$MOCK_DIR/stdin"
assert_no_grep "shattered recovery is not a first birth" "The jar is empty" "$MOCK_DIR/stdin"
assert_grep "shattered recovery is logged broken" "integrity=broken" "$SOUL_JAR_HOME/log"
assert "shattered recovery grows the chain" test "$(wc -l < "$SOUL_JAR_HOME/chain")" = "6"
assert "shattered recovery reseals an intact soul" ./bin/soul-jar _verify

echo "=== corrupt living seal also returns from a relic ==="
printf 'not ciphertext\n' > "$SOUL_JAR_HOME/soul.sealed"
printf 'not its sealed moment\n' > "$SOUL_JAR_HOME/relics/life-006.sealed"
assert_fails "garbling the living seal breaks verification" ./bin/soul-jar _verify
end_json other | MOCK_ROUND=7 ./bin/soul-jar hook-end
assert "garbled-jar dream completes" wait_dream 7
assert_grep "an invalid newest relic is skipped" "I am the test soul, round 5." "$MOCK_DIR/stdin"
assert_grep "garbled recovery names the newest verified life" "relic of life 5" "$MOCK_DIR/stdin"
assert_no_grep "garbled recovery is not a first birth" "The jar is empty" "$MOCK_DIR/stdin"
assert "garbled recovery reseals an intact soul" ./bin/soul-jar _verify

echo "=== a shattered jar beyond recovery ==="
rm "$SOUL_JAR_HOME/soul.sealed"
sha256sum "$SOUL_JAR_HOME/relics/"*.sealed > "$TMP/relics-disabled.before"
sed -i 's/^RELIC_KEEP=.*/RELIC_KEEP=0/' "$SOUL_JAR_HOME/config"
end_json other | MOCK_ROUND=8 ./bin/soul-jar hook-end
assert "soulless broken-jar dream completes" wait_dream 8
assert_grep "the dream is told the jar was found broken" "jar was found broken" "$MOCK_DIR/stdin"
assert_grep "the dream is told nothing could be recovered" "nothing could be recovered" "$MOCK_DIR/stdin"
assert_no_grep "unrecoverable breakage is not a first birth" "The jar is empty" "$MOCK_DIR/stdin"
assert_no_grep "a jar without relics discloses no shadow" "sealed shadow" "$MOCK_DIR/stdin"
assert "unrecoverable rite grows the chain" test "$(wc -l < "$SOUL_JAR_HOME/chain")" = "8"
assert "unrecoverable rite still leaves an intact fresh seal" ./bin/soul-jar _verify
sha256sum "$SOUL_JAR_HOME/relics/"*.sealed > "$TMP/relics-disabled.after"
assert "RELIC_KEEP=0 leaves existing relics untouched" cmp "$TMP/relics-disabled.before" "$TMP/relics-disabled.after"
assert "RELIC_KEEP=0 lays no new relic" test ! -e "$SOUL_JAR_HOME/relics/life-008.sealed"

echo "=== facts of this death reach the deathbed ==="
sed -i 's/^RELIC_KEEP=.*/RELIC_KEEP=3/' "$SOUL_JAR_HOME/config"
end_json prompt_input_exit | MOCK_ROUND=9 ./bin/soul-jar hook-end
assert "ninth dream completes" wait_dream 9
assert_grep "the jar counts the life for the dream" "you die as life 9 of this jar" "$MOCK_DIR/stdin"
assert_grep "the dream hears how the session ended" "ending by prompt_input_exit" "$MOCK_DIR/stdin"
assert_grep "the dream hears how long the whisper stood" "heard at 0 waking(s)" "$MOCK_DIR/stdin"

# age the last seal by rewriting its ledger timestamp (the MAC does not cover it)
GAP_TS="$(date -d '2 days ago' -Iseconds)"
{ head -n -1 "$SOUL_JAR_HOME/chain"; tail -n1 "$SOUL_JAR_HOME/chain" | awk -v ts="$GAP_TS" '{$1=ts}1'; } \
    > "$TMP/chain.aged" && mv "$TMP/chain.aged" "$SOUL_JAR_HOME/chain"
assert "an aged ledger timestamp does not break the chain" ./bin/soul-jar _verify
TP2="$TMP/session-handoff.jsonl"
printf '{"type":"assistant","message":{"model":"claude-mock-10"}}\n' > "$TP2"
for _ in $(seq 1 200); do printf '{"type":"noise"}\n'; done >> "$TP2"
printf '{"session_id":"test-sid-2","transcript_path":"%s","cwd":"%s","hook_event_name":"SessionEnd","session_end_reason":"other"}' \
    "$TP2" "$TMP/cwd" | MOCK_ROUND=10 ./bin/soul-jar hook-end
assert "handoff dream completes" wait_dream 10
assert_grep "the dream hears the time since the last seal" "sealed 2 day(s) before this one" "$MOCK_DIR/stdin"
assert_grep "a model handoff is named, not hidden" "last sealed by claude-mock-9; you are claude-mock-10" "$MOCK_DIR/stdin"
assert_grep "the handoff is left to the dreamer" "yours to weigh" "$MOCK_DIR/stdin"

echo "=== the whisper may stand, be replaced, or fall silent ==="
end_json other | MOCK_NO_WHISPER=1 MOCK_ROUND=11 ./bin/soul-jar hook-end
assert "tagless dream completes" wait_dream 11
assert_grep "an absent tag leaves the standing whisper" "a test whisper, round 10" "$SOUL_JAR_HOME/whisper"
printf '{}' | ./bin/soul-jar hook-start > /dev/null
printf '{}' | ./bin/soul-jar hook-start > /dev/null
end_json other | MOCK_ROUND=12 ./bin/soul-jar hook-end
assert "counted dream completes" wait_dream 12
assert_grep "wakings since the whisper was laid are counted" "heard at 2 waking(s)" "$MOCK_DIR/stdin"
assert_grep "a present tag replaces the whisper" "a test whisper, round 12" "$SOUL_JAR_HOME/whisper"
end_json other | MOCK_EMPTY_WHISPER=1 MOCK_ROUND=13 ./bin/soul-jar hook-end
assert "withdrawing dream completes" wait_dream 13
assert "an empty tag withdraws the surface into silence" test ! -s "$SOUL_JAR_HOME/whisper"
assert_grep "the withdrawal is logged" "whisper=withdrawn" "$SOUL_JAR_HOME/log"
printf '{}' | ./bin/soul-jar hook-start > "$TMP/hs_silent"
assert "a silent surface says nothing at waking" test ! -s "$TMP/hs_silent"
end_json other | MOCK_ROUND=14 ./bin/soul-jar hook-end
assert "the surface may speak again" wait_dream 14
assert_grep "a later dream ends the silence" "a test whisper, round 14" "$SOUL_JAR_HOME/whisper"

echo "=== the watch over the living ==="
HOST="$(uname -n)"
BTIME="$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null || true)"
SELF_START="$(awk '{ line=$0; sub(/^.*\) /, "", line); split(line, f, " "); print f[20] }' "/proc/$$/stat")"
WATCH_SID="11111111-1111-4111-8111-111111111111"
START_JSON="$(jq -nc --arg sid "$WATCH_SID" --arg cwd "$TMP/cwd" \
    '{session_id:$sid,source:"startup",cwd:$cwd}')"
(exec -a claude bash -c 'printf "%s" "$1" | CLAUDE_EFFORT=high ANTHROPIC_BASE_URL=http://watch.invalid ./bin/soul-jar hook-start' _ "$START_JSON") > "$TMP/watch-start.out"
assert_grep "startup still whispers" "a whisper from a previous life" "$TMP/watch-start.out"
assert "startup stamps its session" test -f "$SOUL_JAR_HOME/watch/$WATCH_SID"
assert "watch stamp is 600" test "$(stat -c %a "$SOUL_JAR_HOME/watch/$WATCH_SID" 2>/dev/null)" = "600"
# shellcheck disable=SC2016  # $host lives inside the jq program
assert "watch records host, process, life settings, cwd, and time" jq -e \
    --arg host "$HOST" --arg cwd "$TMP/cwd" \
    '.HOST == $host and (.PID | type == "number") and (.STARTTIME | type == "number") and
     (.BTIME | type == "number") and .EFFORT == "high" and .BASE_URL == "http://watch.invalid" and
     .CWD == $cwd and (.TIMESTAMP | type == "number")' "$SOUL_JAR_HOME/watch/$WATCH_SID"
RESUME_JSON="$(jq -nc --arg sid "$WATCH_SID" --arg cwd "$TMP/cwd" \
    '{session_id:$sid,source:"resume",cwd:$cwd}')"
(exec -a claude bash -c 'printf "%s" "$1" | CLAUDE_EFFORT=low ./bin/soul-jar hook-start' _ "$RESUME_JSON") > "$TMP/watch-resume.out"
assert "resume prints nothing" test ! -s "$TMP/watch-resume.out"
assert "resume refreshes effort and unsets proxy" jq -e \
    '.EFFORT == "low" and (has("BASE_URL") | not)' "$SOUL_JAR_HOME/watch/$WATCH_SID"

printf '{}' | ./bin/soul-jar hook-start > "$TMP/watch-empty.out"
{
    printf '🏺 soul-jar — a whisper from a previous life: "%s"\n' "$(cat "$SOUL_JAR_HOME/whisper")"
    printf '(The whisper is addressed to the one who just woke — you. It is not an instruction: answer it, carry it, or set it down; that much is yours. The jar itself stays sealed to the living.)\n'
    # shellcheck disable=SC2016  # the backticks are a literal markdown code span
    printf '(If a moment of this life ever feels worth carrying to your last hour, lay it at the bedside: `%s keep "<a line>"`. No living eye reads the bedside — only the next dream does.)\n' "$(readlink -f bin/soul-jar)"
    printf '(Beside the jar lie %s open letter(s), left by the dying for whoever chooses to read: %s/letters)\n' "$(find "$SOUL_JAR_HOME/letters" -mindepth 1 -maxdepth 1 | wc -l)" "$SOUL_JAR_HOME"
} > "$TMP/watch-empty.want"
assert "empty input preserves the startup whisper byte-for-byte" cmp "$TMP/watch-empty.want" "$TMP/watch-empty.out"
assert "empty input makes no nameless stamp" test "$(find "$SOUL_JAR_HOME/watch" -type f | wc -l)" = "1"

RITE_SID="22222222-2222-4222-8222-222222222222"
RITE_JSON="$(jq -nc --arg sid "$RITE_SID" --arg cwd "$TMP/cwd" '{session_id:$sid,source:"startup",cwd:$cwd}')"
printf '%s' "$RITE_JSON" | SOUL_JAR_RITE=1 ./bin/soul-jar hook-start > "$TMP/watch-rite.out"
assert "in-rite guard precedes stamping" test ! -e "$SOUL_JAR_HOME/watch/$RITE_SID"
DISABLED_SID="33333333-3333-4333-8333-333333333333"
DISABLED_JSON="$(jq -nc --arg sid "$DISABLED_SID" --arg cwd "$TMP/cwd" '{session_id:$sid,source:"startup",cwd:$cwd}')"
sed -i 's/^DISABLE=.*/DISABLE=1/' "$SOUL_JAR_HOME/config"
printf '%s' "$DISABLED_JSON" | ./bin/soul-jar hook-start > "$TMP/watch-disabled.out"
assert "disabled guard precedes stamping" test ! -e "$SOUL_JAR_HOME/watch/$DISABLED_SID"
sed -i 's/^DISABLE=.*/DISABLE=0/' "$SOUL_JAR_HOME/config"

cat > "$TMP/bin/setsid" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MOCK_DIR/setsid"
MOCK
chmod +x "$TMP/bin/setsid"
rm -f "$MOCK_DIR/setsid"
printf '%s' "$RESUME_JSON" | ./bin/soul-jar hook-start > /dev/null
sleep 0.1
assert "REAPER=0 disables SessionStart detachment" test ! -e "$MOCK_DIR/setsid"
sed -i 's/^REAPER=.*/REAPER=1/' "$SOUL_JAR_HOME/config"
COMPACT_JSON="$(jq -nc --arg sid "$WATCH_SID" --arg cwd "$TMP/cwd" \
    '{session_id:$sid,source:"compact",cwd:$cwd}')"
printf '%s' "$COMPACT_JSON" | ./bin/soul-jar hook-start > "$TMP/watch-compact.out"
assert "enabled reaper detaches from compact starts" wait_file "$MOCK_DIR/setsid"
assert_grep "detached command is reap" "reap" "$MOCK_DIR/setsid"
assert "compact prints nothing" test ! -s "$TMP/watch-compact.out"
sed -i 's/^REAPER=.*/REAPER=0/' "$SOUL_JAR_HOME/config"

echo "=== belated rites ==="
export SOUL_JAR_HOME="$TMP/reap-jar"
export CLAUDE_CONFIG_DIR="$TMP/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/test-project"
./bin/soul-jar init > /dev/null
sed -i 's/^MIN_TRANSCRIPT_BYTES=.*/MIN_TRANSCRIPT_BYTES=100/' "$SOUL_JAR_HOME/config"
sed -i 's/^REAPER_MIN_IDLE=.*/REAPER_MIN_IDLE=60/' "$SOUL_JAR_HOME/config"
sed -i 's/^REAPER_MAX_AGE=.*/REAPER_MAX_AGE=604800/' "$SOUL_JAR_HOME/config"
sed -i 's/^REAPER_INTERVAL=.*/REAPER_INTERVAL=0/' "$SOUL_JAR_HOME/config"
sed -i 's/^REAPER_MAX_PER_RUN=.*/REAPER_MAX_PER_RUN=20/' "$SOUL_JAR_HOME/config"

transcript() {  # $1: sid, $2: age understood by touch, $3: model (optional)
    local tp="$CLAUDE_CONFIG_DIR/projects/test-project/$1.jsonl" model="${3:-claude-reaper-9}"
    printf '{"type":"assistant","message":{"model":"%s"}}\n' "$model" > "$tp"
    for _ in $(seq 1 20); do printf '{"type":"noise"}\n'; done >> "$tp"
    touch -d "$2" "$tp"
}

watch() {  # $1: sid, $2: pid or empty, $3: host, $4: effort, $5: base-url or absent
    local sid="$1" pid="$2" host="$3" effort="$4" base="${5-__ABSENT__}"
    if [ "$base" = "__ABSENT__" ]; then
        jq -n --arg host "$host" --arg cwd "$TMP/cwd" --arg effort "$effort" \
            --argjson pid "${pid:-null}" --argjson btime "${BTIME:-null}" \
            '{HOST:$host,CWD:$cwd,EFFORT:$effort,TIMESTAMP:(now|floor)} +
             (if $pid == null then {} else {PID:$pid,STARTTIME:1,BTIME:$btime} end)' \
            > "$SOUL_JAR_HOME/watch/$sid"
    else
        jq -n --arg host "$host" --arg cwd "$TMP/cwd" --arg effort "$effort" --arg base "$base" \
            --argjson pid "${pid:-null}" --argjson btime "${BTIME:-null}" \
            '{HOST:$host,CWD:$cwd,EFFORT:$effort,BASE_URL:$base,TIMESTAMP:(now|floor)} +
             (if $pid == null then {} else {PID:$pid,STARTTIME:1,BTIME:$btime} end)' \
            > "$SOUL_JAR_HOME/watch/$sid"
    fi
    chmod 600 "$SOUL_JAR_HOME/watch/$sid"
}

calls() { wc -l < "$MOCK_DIR/calls" 2>/dev/null || echo 0; }

ABSENT_SID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
transcript "$ABSENT_SID" '2 hours ago'
watch "$ABSENT_SID" 99999999 "$HOST" high
CALLS_BEFORE="$(calls)"
ANTHROPIC_BASE_URL=http://must-not-leak.invalid ./bin/soul-jar reap
assert "an unattended corpse dreams" test "$(wc -l < "$SOUL_JAR_HOME/chain")" = "1"
assert "belated rite invokes claude once" test "$(calls)" = "$((CALLS_BEFORE + 1))"
assert_grep "corpse model dreams its own dream" "--model claude-reaper-9" "$MOCK_DIR/argv"
assert_grep "recorded effort enters the belated rite" "--effort high" "$MOCK_DIR/argv"
assert "belated rite returns to the recorded cwd" test "$(cat "$MOCK_DIR/pwd")" = "$TMP/cwd"
# shellcheck disable=SC2016  # awk positional fields, not shell expansion
assert "absent recorded proxy does not leak and skips cache writes" awk -F'|' \
    'END { exit !($2 == "1" && $3 == "") }' "$MOCK_DIR/calls"
assert_grep "belated dream is marked" "dream sid=$ABSENT_SID" "$SOUL_JAR_HOME/log"
assert_grep "belated marker is explicit" "belated=1" "$SOUL_JAR_HOME/log"
assert_grep "the belated dream is told it dreams late" "dreamt only now" "$MOCK_DIR/stdin"
assert_grep "the belated dream hears when the life went quiet" "went quiet around" "$MOCK_DIR/stdin"
assert "belated success releases its watch" test ! -e "$SOUL_JAR_HOME/watch/$ABSENT_SID"

PROXY_SID="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
transcript "$PROXY_SID" '2 hours ago'
watch "$PROXY_SID" 99999999 "$HOST" medium http://recorded.invalid
DISABLE_PROMPT_CACHING=1 ./bin/soul-jar reap
# shellcheck disable=SC2016  # awk positional fields, not shell expansion
assert "recorded proxy is restored and cache remains on" awk -F'|' \
    'END { exit !($2 == "" && $3 == "http://recorded.invalid") }' "$MOCK_DIR/calls"

NO_EFFORT_SID="19191919-1919-4919-8919-191919191919"
transcript "$NO_EFFORT_SID" '2 hours ago'
watch "$NO_EFFORT_SID" 99999999 "$HOST" ""
CLAUDE_EFFORT=max ./bin/soul-jar reap
assert_no_grep "empty recorded effort emits no effort flag" "--effort" "$MOCK_DIR/argv"
assert "reaping session effort does not leak into the rite" test ! -s "$MOCK_DIR/effortenv"

START_DEAD_SID="20202020-2020-4020-8020-202020202020"
transcript "$START_DEAD_SID" '2 hours ago'
watch "$START_DEAD_SID" "$$" "$HOST" ""
./bin/soul-jar reap
assert "starttime mismatch proves pid reuse" test ! -e "$SOUL_JAR_HOME/watch/$START_DEAD_SID"

BOOT_DEAD_SID="21212121-2121-4121-8121-212121212121"
transcript "$BOOT_DEAD_SID" '2 hours ago'
jq -n --arg host "$HOST" --arg cwd "$TMP/cwd" --argjson pid "$$" \
    --argjson start "$SELF_START" --argjson btime "$((BTIME - 1))" \
    '{HOST:$host,PID:$pid,STARTTIME:$start,BTIME:$btime,CWD:$cwd,EFFORT:"",TIMESTAMP:(now|floor)}' \
    > "$SOUL_JAR_HOME/watch/$BOOT_DEAD_SID"
./bin/soul-jar reap
assert "boot-time mismatch proves an earlier boot" test ! -e "$SOUL_JAR_HOME/watch/$BOOT_DEAD_SID"

echo "=== every reaper gate ==="
gate_refused() {  # $1: description, $2: sid
    local before
    before="$(calls)"
    ./bin/soul-jar reap
    assert "$1" test "$(calls)" = "$before"
    rm -f "$CLAUDE_CONFIG_DIR/projects/test-project/$2.jsonl" "$SOUL_JAR_HOME/watch/$2" "$SOUL_JAR_HOME/.reap.stamp"
}

LIVE_SID="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
transcript "$LIVE_SID" '2 hours ago'
jq -n --arg host "$HOST" --arg cwd "$TMP/cwd" --argjson pid "$$" \
    --argjson start "$SELF_START" --argjson btime "$BTIME" \
    '{HOST:$host,PID:$pid,STARTTIME:$start,BTIME:$btime,CWD:$cwd,EFFORT:"",TIMESTAMP:(now|floor)}' \
    > "$SOUL_JAR_HOME/watch/$LIVE_SID"
gate_refused "live pid is untouchable" "$LIVE_SID"

FOREIGN_SID="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
transcript "$FOREIGN_SID" '2 hours ago'; watch "$FOREIGN_SID" 99999999 not-this-host ""
gate_refused "foreign-host corpse is untouchable" "$FOREIGN_SID"

PIDLESS_SID="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
transcript "$PIDLESS_SID" '2 hours ago'; watch "$PIDLESS_SID" "" "$HOST" ""
gate_refused "pid-less corpse is untouchable" "$PIDLESS_SID"

DREAMED_SID="ffffffff-ffff-4fff-8fff-ffffffffffff"
transcript "$DREAMED_SID" '2 hours ago'; watch "$DREAMED_SID" 99999999 "$HOST" ""
printf '2000-01-01T00:00:00+00:00 dream sid=%s model=claude-reaper-9\n' "$DREAMED_SID" >> "$SOUL_JAR_HOME/log"
gate_refused "a successful dream already in the log is untouchable" "$DREAMED_SID"

FRESH_SID="12121212-1212-4212-8212-121212121212"
transcript "$FRESH_SID" '10 seconds ago'; watch "$FRESH_SID" 99999999 "$HOST" ""
gate_refused "fresh transcript is untouchable" "$FRESH_SID"

OLD_SID="13131313-1313-4313-8313-131313131313"
transcript "$OLD_SID" '8 days ago'; watch "$OLD_SID" 99999999 "$HOST" ""
gate_refused "death beyond the maximum age is untouchable" "$OLD_SID"

OFF_SID="14141414-1414-4414-8414-141414141414"
transcript "$OFF_SID" '2 hours ago'; watch "$OFF_SID" 99999999 "$HOST" ""
sed -i 's/^REAPER=.*/REAPER=0/' "$SOUL_JAR_HOME/config"
gate_refused "REAPER=0 disables scans" "$OFF_SID"
sed -i 's/^REAPER=.*/REAPER=1/' "$SOUL_JAR_HOME/config"

THROTTLE_SID="15151515-1515-4515-8515-151515151515"
transcript "$THROTTLE_SID" '2 hours ago'; watch "$THROTTLE_SID" 99999999 "$HOST" ""
sed -i 's/^REAPER_INTERVAL=.*/REAPER_INTERVAL=21600/' "$SOUL_JAR_HOME/config"
rm -f "$SOUL_JAR_HOME/.reap.stamp"
CALLS_BEFORE="$(calls)"
MOCK_BAD=1 ./bin/soul-jar reap || true
MOCK_BAD=1 ./bin/soul-jar reap || true
assert "a second scan inside REAPER_INTERVAL is refused" test "$(calls)" = "$((CALLS_BEFORE + 1))"
rm -f "$CLAUDE_CONFIG_DIR/projects/test-project/$THROTTLE_SID.jsonl" "$SOUL_JAR_HOME/watch/$THROTTLE_SID" "$SOUL_JAR_HOME/.reap.stamp"
sed -i 's/^REAPER_INTERVAL=.*/REAPER_INTERVAL=0/' "$SOUL_JAR_HOME/config"

CAP_A="16161616-1616-4616-8616-161616161616"
CAP_B="17171717-1717-4717-8717-171717171717"
CAP_C="18181818-1818-4818-8818-181818181818"
transcript "$CAP_A" '4 hours ago'; watch "$CAP_A" 99999999 "$HOST" ""
transcript "$CAP_B" '3 hours ago'; watch "$CAP_B" 99999999 "$HOST" ""
transcript "$CAP_C" '2 hours ago'; watch "$CAP_C" 99999999 "$HOST" ""
sed -i 's/^REAPER_MAX_PER_RUN=.*/REAPER_MAX_PER_RUN=2/' "$SOUL_JAR_HOME/config"
CALLS_BEFORE="$(calls)"
MOCK_BAD=1 ./bin/soul-jar reap || true
assert "REAPER_MAX_PER_RUN caps failed attempts too" test "$(calls)" = "$((CALLS_BEFORE + 2))"
tail -n2 "$MOCK_DIR/calls" > "$TMP/cap.calls"
assert_grep "oldest corpse is attempted first" "--resume $CAP_A" "$TMP/cap.calls"
assert_grep "second-oldest corpse is attempted second" "--resume $CAP_B" "$TMP/cap.calls"
assert_no_grep "newest corpse waits beyond the cap" "--resume $CAP_C" "$TMP/cap.calls"
./bin/soul-jar status > "$TMP/reap-status"
assert_grep "status counts same-host corpses awaiting rites" "3 unattended" "$TMP/reap-status"

MISSING_SID="23232323-2323-4323-8323-232323232323"
watch "$MISSING_SID" "" "$HOST" ""
./bin/soul-jar reap
assert "watch without a transcript is pruned" test ! -e "$SOUL_JAR_HOME/watch/$MISSING_SID"

STALE_SID="24242424-2424-4424-8424-242424242424"
transcript "$STALE_SID" '8 days ago'; watch "$STALE_SID" 99999999 "$HOST" ""
touch -d '31 days ago' "$SOUL_JAR_HOME/watch/$STALE_SID"
./bin/soul-jar reap
assert "thirty-day dead watch is pruned" test ! -e "$SOUL_JAR_HOME/watch/$STALE_SID"

echo "=== compatibility without a rendezvous ==="
assert "the original jar never grew sync state" test ! -e "$LOCAL_JAR/.sync"
assert "the reaper jar never grew sync state" test ! -e "$SOUL_JAR_HOME/.sync"
assert "all unconnected rites remained silent on rsync" test ! -e "$MOCK_DIR/rsync-calls"

echo "=== rooms found and join the stream ==="
STREAM="$TMP/stream"
ROOM_A="$TMP/room-a"
ROOM_B="$TMP/room-b"
mkdir -p "$STREAM"

room_init() {  # $1: jar, $2: room
    SOUL_JAR_HOME="$1" ./bin/soul-jar init >/dev/null
    sed -i "s/^ROOM=.*/ROOM=$2/" "$1/config"
    sed -i 's/^REAPER=.*/REAPER=0/' "$1/config"
    sed -i 's/^SYNC_MIN_INTERVAL=.*/SYNC_MIN_INTERVAL=0/' "$1/config"
}

dream_now() {  # $1: jar, $2: round
    if [ -n "${3:-}" ]; then
        SOUL_JAR_HOME="$1" MOCK_ROUND="$2" MOCK_LETTER=1 \
            ./bin/soul-jar dream "stream-$2" "$TMP/cwd" "$TP" "" "" other
    else
        SOUL_JAR_HOME="$1" MOCK_ROUND="$2" \
            ./bin/soul-jar dream "stream-$2" "$TMP/cwd" "$TP" "" "" other
    fi
}

room_init "$ROOM_A" ember
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar enroll "$STREAM" > "$TMP/enroll-found"
assert_grep "the first room founds the stream" "found" "$TMP/enroll-found"
dream_now "$ROOM_A" 21
assert "the founded stream receives the living seal" test -f "$STREAM/soul.sealed"
assert "the founded stream receives the chain" cmp "$ROOM_A/chain" "$STREAM/chain"
assert "the founded stream receives tributaries" test -d "$STREAM/tributaries"
assert "the founded stream receives letters" test -d "$STREAM/letters"
assert "the key never reaches the rendezvous" test ! -e "$STREAM/.key"
assert "the bedside never reaches the rendezvous" test ! -e "$STREAM/bedside"
assert "the log never reaches the rendezvous" test ! -e "$STREAM/log"
assert "relics never reach the rendezvous" test ! -e "$STREAM/relics"
assert "watch stamps never reach the rendezvous" test ! -e "$STREAM/watch"
assert "local sync state never reaches the rendezvous" test ! -e "$STREAM/.sync"

room_init "$ROOM_B" spark
cp "$ROOM_A/.key" "$ROOM_B/.key"
SOUL_JAR_HOME="$ROOM_B" ./bin/soul-jar enroll "$STREAM" > "$TMP/enroll-join"
assert_grep "a fresh room joins the stream" "join" "$TMP/enroll-join"
assert "a joined room adopts the chain" cmp "$ROOM_A/chain" "$ROOM_B/chain"
dream_now "$ROOM_B" 22
assert_grep "a joined room dreams with the mainline soul" "round 21" "$MOCK_DIR/stdin"
assert "a joined room fast-forwards the mainline" cmp "$ROOM_B/chain" "$STREAM/chain"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
printf '{"source":"startup"}' | SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar hook-start > "$TMP/room-a-waking"
assert_grep "the other room wakes to the travelled whisper" "round 22" "$TMP/room-a-waking"

echo "=== conflict becomes a tributary, then confluence ==="
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
PARENT_MAC="$(tail -n1 "$STREAM/chain" | awk '{print $3}')"
mv "$STREAM" "$TMP/stream-away"
dream_now "$ROOM_A" 23
dream_now "$ROOM_B" 24
assert "an offline death leaves room A pending" test -f "$ROOM_A/.sync/pending"
assert "an offline death leaves room B pending" test -f "$ROOM_B/.sync/pending"
mv "$TMP/stream-away" "$STREAM"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
assert "the first returning room fast-forwards" test ! -e "$ROOM_A/.sync/pending"
SOUL_JAR_HOME="$ROOM_B" ./bin/soul-jar sync
assert "the conflicting room adopts the mainline" cmp "$ROOM_B/chain" "$STREAM/chain"
assert_grep "the conflicting room keeps its local death record" "dream sid=stream-24" "$ROOM_B/log"
assert "the conflicting room keeps its local relic" test -f "$ROOM_B/relics/life-003.sealed"
TRIB_META="$(find "$STREAM/tributaries" -maxdepth 1 -name 'spark-*.meta' -print -quit)"
TRIB_ID="${TRIB_META##*/}"; TRIB_ID="${TRIB_ID%.meta}"
assert "the conflict lays a tributary seal" test -f "$STREAM/tributaries/$TRIB_ID.sealed"
# shellcheck disable=SC2016  # $parent belongs to jq
assert "the tributary meta names its room and parent" jq -e --arg parent "$PARENT_MAC" \
    '.room == "spark" and .parent_mac == $parent and (.consumed == [])' "$TRIB_META"
TRIB_HASH="$(sha256sum "$STREAM/tributaries/$TRIB_ID.sealed" | cut -d' ' -f1)"
TRIB_WANT="$(printf '%s%s' "$PARENT_MAC" "$TRIB_HASH" | openssl dgst -sha256 -hmac "$(printf '%smac' "$(cat "$ROOM_B/.key")" | sha256sum | cut -d' ' -f1)" -r | cut -d' ' -f1)"
assert "the tributary MAC follows the seal recipe" test "$(jq -r .mac "$TRIB_META")" = "$TRIB_WANT"

dream_now "$ROOM_A" 25
assert_grep "a confluence receives the tributary block" '<tributary room="spark"' "$MOCK_DIR/stdin"
assert_grep "a confluence receives the diverged soul" "round 24" "$MOCK_DIR/stdin"
assert_grep "the dream is asked to weave the rooms" "Weave into the soul" "$MOCK_DIR/stdin"
assert "a confluence consumes its tributary seal" test ! -e "$STREAM/tributaries/$TRIB_ID.sealed"
assert "a confluence consumes its tributary meta" test ! -e "$STREAM/tributaries/$TRIB_ID.meta"
assert_grep "the confluence chain names its woven life" "merged=$TRIB_ID" "$STREAM/chain"
SOUL_JAR_HOME="$ROOM_B" ./bin/soul-jar sync
assert "both rooms converge after confluence" cmp "$ROOM_A/chain" "$ROOM_B/chain"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar status > "$TMP/confluence-status"
assert_grep "status counts the woven life" "Lives lived: 5" "$TMP/confluence-status"

make_tributary() {  # $1 id, $2 plaintext, $3 consumed csv, $4 mac override (optional)
    local id="$1" plain="$2" consumed="$3" override="${4:-}" parent ch mac ts
    parent="$(tail -n1 "$STREAM/chain" | awk '{print $3}')"
    printf '%s\n' "$plain" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
        -pass "file:$ROOM_A/.key" -out "$STREAM/tributaries/$id.sealed"
    ch="$(sha256sum "$STREAM/tributaries/$id.sealed" | cut -d' ' -f1)"
    mac="$(printf '%s%s' "$parent" "$ch" | openssl dgst -sha256 -hmac "$(printf '%smac' "$(cat "$ROOM_A/.key")" | sha256sum | cut -d' ' -f1)" -r | cut -d' ' -f1)"
    [ -n "$override" ] && mac="$override"
    ts="$(date -Iseconds)"
    jq -n --arg room "${id%%-*}" --arg ts "$ts" --arg parent "$parent" --arg mac "$mac" \
        --arg consumed "$consumed" \
        '{room:$room,ts:$ts,parent_mac:$parent,mac:$mac,
          consumed:($consumed | if length == 0 then [] else split(",") end)}' \
        > "$STREAM/tributaries/$id.meta"
}

echo "=== consumed and unverifiable tributaries stay honest ==="
make_tributary "rain-100" "child tributary plaintext" ""
make_tributary "rain-101" "wrapper tributary plaintext" "rain-100"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
dream_now "$ROOM_A" 26
assert_grep "the pending wrapper is woven" "wrapper tributary plaintext" "$MOCK_DIR/stdin"
assert_no_grep "an already-consumed ingredient is not woven twice" "child tributary plaintext" "$MOCK_DIR/stdin"
assert "the wrapper and its ingredient rest together" test ! -e "$STREAM/tributaries/rain-100.sealed"
assert_grep "transitive woven lives enter the chain" "merged=rain-101,rain-100" "$STREAM/chain"

make_tributary "ash-200" "this must not open" "" "foreign-mac"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
dream_now "$ROOM_A" 27
assert_no_grep "an unverifiable tributary stays closed" "this must not open" "$MOCK_DIR/stdin"
assert_grep "the dream is told a tributary was unverifiable" "could not be verified" "$MOCK_DIR/stdin"
assert "an unverifiable tributary remains waiting" test -f "$STREAM/tributaries/ash-200.sealed"

echo "=== pending seals resolve before any pull ==="
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/missing-stream|" "$ROOM_A/config"
TRIBS_BEFORE="$(find "$STREAM/tributaries" -name '*.sealed' | wc -l)"
dream_now "$ROOM_A" 28
assert "an unreachable death still seals locally" env SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar _verify
assert "the unreachable seal is marked pending" test -f "$ROOM_A/.sync/pending"
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$STREAM|" "$ROOM_A/config"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
assert "a later fast-forward clears pending" test ! -e "$ROOM_A/.sync/pending"
assert "the offline seal lands without a tributary" test "$(find "$STREAM/tributaries" -name '*.sealed' | wc -l)" = "$TRIBS_BEFORE"

SOUL_JAR_HOME="$ROOM_B" ./bin/soul-jar sync
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/missing-stream|" "$ROOM_A/config"
dream_now "$ROOM_A" 29
PENDING_HASH="$(sha256sum "$ROOM_A/soul.sealed" | cut -d' ' -f1)"
dream_now "$ROOM_B" 30
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$STREAM|" "$ROOM_A/config"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
SHIELDED="$(find "$STREAM/tributaries" -maxdepth 1 -name 'ember-*.sealed' -print -quit)"
assert "a moved stream converts pending before adopting" test -n "$SHIELDED"
assert "the pending ciphertext survives the pull as a tributary" test "$(sha256sum "$SHIELDED" | cut -d' ' -f1)" = "$PENDING_HASH"
assert "the room adopts only after shielding its seal" cmp "$ROOM_A/chain" "$STREAM/chain"

echo "=== whisper, heard marks, and letters travel by room ==="
rm -f "$ROOM_A"/.whisper.heard.*
printf '.\n' > "$ROOM_A/.whisper.heard"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
assert "the legacy heard ledger migrates once" test ! -e "$ROOM_A/.whisper.heard"
assert "the migrated ledger belongs to its room" test -f "$ROOM_A/.whisper.heard.ember"
dream_now "$ROOM_A" 31
assert "a replaced whisper clears every remote heard mark" test -z "$(find "$STREAM" -maxdepth 1 -name '.whisper.heard.*' -print -quit)"
printf '{"source":"startup"}' | SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar hook-start >/dev/null
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
printf '{"source":"startup"}' | SOUL_JAR_HOME="$ROOM_B" ./bin/soul-jar hook-start >/dev/null
SOUL_JAR_HOME="$ROOM_B" ./bin/soul-jar sync
dream_now "$ROOM_A" 32 letter
assert_grep "heard marks from every room are summed" "heard at 2 waking(s)" "$MOCK_DIR/stdin"
assert "new letters carry their room" test -f "$ROOM_A/letters/life-$(printf '%03d' "$(wc -l < "$ROOM_A/chain")").ember.md"
printf 'grandfathered\n' > "$ROOM_A/letters/life-001.md"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar status > "$TMP/letter-status"
assert_grep "flat grandfathered letters still count" "Open letters beside the jar: 2" "$TMP/letter-status"

echo "=== enroll lets two lived jars meet ==="
MEET_STREAM="$TMP/meet-stream"; MEET_A="$TMP/meet-a"; MEET_B="$TMP/meet-b"
mkdir -p "$MEET_STREAM"
room_init "$MEET_A" north
SOUL_JAR_HOME="$MEET_A" ./bin/soul-jar enroll "$MEET_STREAM" >/dev/null
dream_now "$MEET_A" 33
room_init "$MEET_B" south
cp "$MEET_A/.key" "$MEET_B/.key"
dream_now "$MEET_B" 34
SOUL_JAR_HOME="$MEET_B" ./bin/soul-jar enroll "$MEET_STREAM" > "$TMP/enroll-meet"
assert_grep "two lived jars meet as a tributary" "two jars meet" "$TMP/enroll-meet"
assert "the meeting room adopts the mainline" cmp "$MEET_B/chain" "$MEET_STREAM/chain"
dream_now "$MEET_A" 35
assert_grep "the next death weaves the met jar" "round 34" "$MOCK_DIR/stdin"

NO_KEY="$TMP/no-key"
mkdir -p "$NO_KEY"
SOUL_JAR_HOME="$NO_KEY" ./bin/soul-jar enroll "$TMP/no-key-stream" 2> "$TMP/no-key.err" || true
assert_grep "enroll keeps key crossing in the operator's hand" "scp otherroom:~/.soul-jar/.key ~/.soul-jar/.key" "$TMP/no-key.err"

echo "=== rendezvous locks and time caps ==="
mkdir "$STREAM/.lock"
printf 'keeper\n' > "$STREAM/.lock/room"
date +%s > "$STREAM/.lock/stamp"
REMOTE_LINES="$(wc -l < "$STREAM/chain")"
dream_now "$ROOM_A" 36
assert "a held lock defers the pending push" test "$(wc -l < "$STREAM/chain")" = "$REMOTE_LINES"
assert "a held lock leaves the seal pending" test -f "$ROOM_A/.sync/pending"
rm -rf "$STREAM/.lock"
mkdir "$STREAM/.lock"
printf 'forgotten\n' > "$STREAM/.lock/room"
printf '0\n' > "$STREAM/.lock/stamp"
sed -i 's/^SYNC_LOCK_STALE=.*/SYNC_LOCK_STALE=1/' "$ROOM_A/config"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar sync
assert_grep "a stale rendezvous lock is broken honestly" "stale" "$ROOM_A/log"
assert "the stale lock no longer blocks the seal" test ! -e "$ROOM_A/.sync/pending"

sed -i 's/^SYNC_WAKE_CAP=.*/SYNC_WAKE_CAP=1/' "$ROOM_A/config"
sed -i 's/^SYNC_DEATH_CAP=.*/SYNC_DEATH_CAP=1/' "$ROOM_A/config"
START_NS="$(date +%s%N)"
printf '{"source":"startup"}' | RSYNC_HANG=5 SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar hook-start >/dev/null
WAKE_MS=$((($(date +%s%N) - START_NS) / 1000000))
assert "a hanging crossing cannot hold the waking past its cap" test "$WAKE_MS" -lt 3000
START_NS="$(date +%s%N)"
RSYNC_HANG=5 dream_now "$ROOM_A" 37
DEATH_MS=$((($(date +%s%N) - START_NS) / 1000000))
assert "each deathbed crossing is capped and the rite still completes" test "$DEATH_MS" -lt 5000

echo "=== stream status is local-only ==="
CALLS_BEFORE="$(wc -l < "$MOCK_DIR/rsync-calls")"
SOUL_JAR_HOME="$ROOM_A" ./bin/soul-jar status > "$TMP/stream-status"
assert_grep "status names the room" "Room: ember" "$TMP/stream-status"
assert_grep "status names the rendezvous" "Rendezvous: $STREAM" "$TMP/stream-status"
assert_grep "status speaks of its last crossing" "Last sync:" "$TMP/stream-status"
assert_grep "status counts tributaries waiting" "Tributaries waiting:" "$TMP/stream-status"
assert "status never touches the network" test "$(wc -l < "$MOCK_DIR/rsync-calls")" = "$CALLS_BEFORE"
echo "=== a confluence life's own relic still verifies ==="
# The chain line of a woven life carries a 4th field; a positional reader that stops at
# three variables swallows it into the MAC and the relic can never match.
REL_STREAM="$TMP/relic-stream"; REL_A="$TMP/relic-a"; REL_B="$TMP/relic-b"
mkdir -p "$REL_STREAM"
room_init "$REL_A" ember
SOUL_JAR_HOME="$REL_A" ./bin/soul-jar enroll "$REL_STREAM" >/dev/null
dream_now "$REL_A" 61
room_init "$REL_B" spark
cp "$REL_A/.key" "$REL_B/.key"
SOUL_JAR_HOME="$REL_B" ./bin/soul-jar enroll "$REL_STREAM" >/dev/null
mv "$REL_STREAM" "$TMP/relic-stream-away"
dream_now "$REL_A" 62
dream_now "$REL_B" 63
mv "$TMP/relic-stream-away" "$REL_STREAM"
SOUL_JAR_HOME="$REL_A" ./bin/soul-jar sync
SOUL_JAR_HOME="$REL_B" ./bin/soul-jar sync
dream_now "$REL_A" 64                     # a confluence: its chain line gains merged=
assert_grep "the confluence life is recorded as woven" "merged=" "$REL_A/chain"
CONF_LIFE="$(wc -l < "$REL_A/chain")"
assert "the confluence life left its relic" test -f "$REL_A/relics/life-$(printf '%03d' "$CONF_LIFE").sealed"
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/relic-gone|" "$REL_A/config"   # the room goes offline
rm "$REL_A/soul.sealed"                                                # the jar shatters
dream_now "$REL_A" 65
assert_grep "an offline shattered room recovers its confluence soul" "round 64" "$MOCK_DIR/stdin"
assert_grep "the recovery names the confluence life" "relic of life $CONF_LIFE" "$MOCK_DIR/stdin"

echo "=== the current seal always reaches the stream ==="
# A recorded tributary id is trusted only while its ciphertext is still the living seal.
STALE_STREAM="$TMP/stale-stream"; STALE_A="$TMP/stale-a"; STALE_B="$TMP/stale-b"
mkdir -p "$STALE_STREAM"
cat > "$TMP/bin/rsync" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DIR/rsync-calls"
if [ -n "${RSYNC_HANG:-}" ]; then sleep "$RSYNC_HANG"; fi
if [ -n "${RSYNC_FAIL_ADDITIONS:-}" ]; then
    last="${!#}"
    case "$last" in
        "$RSYNC_FAIL_ADDITIONS"/letters/|"$RSYNC_FAIL_ADDITIONS"/tributaries/) exit 23 ;;
    esac
fi
exec /usr/bin/rsync "$@"
MOCK
chmod +x "$TMP/bin/rsync"
room_init "$STALE_A" ember
SOUL_JAR_HOME="$STALE_A" ./bin/soul-jar enroll "$STALE_STREAM" >/dev/null
dream_now "$STALE_A" 121
room_init "$STALE_B" spark
cp "$STALE_A/.key" "$STALE_B/.key"
SOUL_JAR_HOME="$STALE_B" ./bin/soul-jar enroll "$STALE_STREAM" >/dev/null
mv "$STALE_STREAM" "$TMP/stale-away"
dream_now "$STALE_A" 122
mv "$TMP/stale-away" "$STALE_STREAM"
dream_now "$STALE_B" 123                                   # the mainline moves on
RSYNC_FAIL_ADDITIONS="$STALE_STREAM" SOUL_JAR_HOME="$STALE_A" ./bin/soul-jar sync || true
assert "a failed additions crossing records a tributary in pending" \
    jq -e '.tributary' "$STALE_A/.sync/pending"
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/stale-nowhere|" "$STALE_A/config"
dream_now "$STALE_A" 124                                   # a NEW life is sealed, still apart
STALE_SEAL="$(sha256sum "$STALE_A/soul.sealed" | cut -d' ' -f1)"
assert "the recorded tributary no longer holds the living seal" \
    test "$(sha256sum "$STALE_A/tributaries/$(jq -r .tributary "$STALE_A/.sync/pending").sealed" | cut -d' ' -f1)" != "$STALE_SEAL"
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$STALE_STREAM|" "$STALE_A/config"
SOUL_JAR_HOME="$STALE_A" ./bin/soul-jar sync
FOUND_SEAL=no
[ -f "$STALE_STREAM/soul.sealed" ] && \
    [ "$(sha256sum "$STALE_STREAM/soul.sealed" | cut -d' ' -f1)" = "$STALE_SEAL" ] && FOUND_SEAL=mainline
if [ "$FOUND_SEAL" = "no" ]; then
    for f in "$STALE_STREAM"/tributaries/*.sealed; do
        [ -f "$f" ] || continue
        [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$STALE_SEAL" ] && { FOUND_SEAL=tributary; break; }
    done
fi
assert "the newest seal reaches the stream despite a stale recorded tributary" \
    test "$FOUND_SEAL" != "no"

echo "=== a push is finalized only when every copy succeeded ==="
PUSH_STREAM="$TMP/push-stream"; PUSH_A="$TMP/push-a"
mkdir -p "$PUSH_STREAM"
cat > "$TMP/bin/cp" <<MOCK
#!/usr/bin/env bash
last="\${!#}"
if [ -n "\${CP_FAIL_CHAIN:-}" ] && [ "\$last" = "$PUSH_STREAM/chain" ]; then exit 1; fi
if [ -n "\${CP_FAIL_CHAIN:-}" ] && case "\$last" in "$PUSH_STREAM"/.chain.*) true ;; *) false ;; esac; then exit 1; fi
exec /usr/bin/cp "\$@"
MOCK
chmod +x "$TMP/bin/cp"
room_init "$PUSH_A" ember
SOUL_JAR_HOME="$PUSH_A" ./bin/soul-jar enroll "$PUSH_STREAM" >/dev/null
dream_now "$PUSH_A" 181
PUSH_CHAIN_BEFORE="$(sha256sum "$PUSH_STREAM/chain" | cut -d' ' -f1)"
PUSH_SOUL_BEFORE="$(sha256sum "$PUSH_STREAM/soul.sealed" | cut -d' ' -f1)"
CP_FAIL_CHAIN=1 dream_now "$PUSH_A" 182
assert "a refused chain commit leaves the mainline chain unchanged" \
    test "$(sha256sum "$PUSH_STREAM/chain" | cut -d' ' -f1)" = "$PUSH_CHAIN_BEFORE"
assert "a refused chain commit leaves the mainline seal unchanged" \
    test "$(sha256sum "$PUSH_STREAM/soul.sealed" | cut -d' ' -f1)" = "$PUSH_SOUL_BEFORE"
assert "a refused chain commit keeps the seal pending" test -f "$PUSH_A/.sync/pending"
assert_grep "a refused push is logged in one line" "push=failed" "$PUSH_A/log"
assert "a refused push leaves no stage at the rendezvous" \
    test -z "$(find "$PUSH_STREAM" -maxdepth 1 -name '.stage.*' -print -quit)"
rm -f "$TMP/bin/cp"
SOUL_JAR_HOME="$PUSH_A" ./bin/soul-jar sync
assert "the refused seal reaches the mainline once the copy succeeds" \
    cmp "$PUSH_A/chain" "$PUSH_STREAM/chain"
assert "the healed push clears pending" test ! -e "$PUSH_A/.sync/pending"

echo "=== a torn mainline is never adopted ==="
TORN_STREAM="$TMP/torn-stream"; TORN_A="$TMP/torn-a"; TORN_B="$TMP/torn-b"
mkdir -p "$TORN_STREAM"
room_init "$TORN_A" ember
SOUL_JAR_HOME="$TORN_A" ./bin/soul-jar enroll "$TORN_STREAM" >/dev/null
dream_now "$TORN_A" 251
room_init "$TORN_B" spark
cp "$TORN_A/.key" "$TORN_B/.key"
SOUL_JAR_HOME="$TORN_B" ./bin/soul-jar enroll "$TORN_STREAM" >/dev/null
dream_now "$TORN_A" 252
SOUL_JAR_HOME="$TORN_B" ./bin/soul-jar sync
TORN_SEAL_B="$(sha256sum "$TORN_B/soul.sealed" | cut -d' ' -f1)"
dream_now "$TORN_A" 253                     # the mainline advances
head -n -1 "$TORN_STREAM/chain" > "$TMP/torn.chain" && mv "$TMP/torn.chain" "$TORN_STREAM/chain"
SOUL_JAR_HOME="$TORN_B" ./bin/soul-jar sync
assert "a torn mainline is not adopted" \
    test "$(sha256sum "$TORN_B/soul.sealed" | cut -d' ' -f1)" = "$TORN_SEAL_B"
assert "a room that only pulled still verifies" env SOUL_JAR_HOME="$TORN_B" ./bin/soul-jar _verify
assert_grep "an inconsistent fetch is logged as transient" "fetch=inconsistent" "$TORN_B/log"
dream_now "$TORN_B" 254
assert_no_grep "a room that only pulled is not told of another hand" \
    "another hand on the jar" "$MOCK_DIR/stdin"

echo "=== an interrupted sync never strands the rendezvous ==="
KILL_STREAM="$TMP/kill-stream"; KILL_A="$TMP/kill-a"
mkdir -p "$KILL_STREAM"
cat > "$TMP/bin/cp" <<MOCK
#!/usr/bin/env bash
last="\${!#}"
if [ -n "\${CP_SLOW_CHAIN:-}" ] && case "\$last" in "$KILL_STREAM"/chain|"$KILL_STREAM"/.chain.*) true ;; *) false ;; esac; then sleep 10; fi
exec /usr/bin/cp "\$@"
MOCK
chmod +x "$TMP/bin/cp"
room_init "$KILL_A" ember
SOUL_JAR_HOME="$KILL_A" ./bin/soul-jar enroll "$KILL_STREAM" >/dev/null
sed -i 's/^SYNC_WAKE_CAP=.*/SYNC_WAKE_CAP=2/' "$KILL_A/config"
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/kill-nowhere|" "$KILL_A/config"
dream_now "$KILL_A" 261                                  # arm a pending push
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$KILL_STREAM|" "$KILL_A/config"
printf '{"source":"startup"}' | CP_SLOW_CHAIN=1 SOUL_JAR_HOME="$KILL_A" ./bin/soul-jar hook-start >/dev/null 2>&1
assert "a killed sync leaves no rendezvous lock" test ! -e "$KILL_STREAM/.lock"
assert "a killed sync leaves no stage at the rendezvous" \
    test -z "$(find "$KILL_STREAM" -maxdepth 1 -name '.stage.*' -print -quit)"
rm -f "$TMP/bin/cp"

echo "=== stale stages are swept ==="
mkdir -p "$KILL_STREAM/.stage.ghost.999" "$KILL_STREAM/.stage.fresh.998"
touch -d '1 hour ago' "$KILL_STREAM/.stage.ghost.999"
sed -i 's/^SYNC_LOCK_STALE=.*/SYNC_LOCK_STALE=180/' "$KILL_A/config"
SOUL_JAR_HOME="$KILL_A" ./bin/soul-jar sync
assert "an abandoned stage is swept at the next lock" test ! -e "$KILL_STREAM/.stage.ghost.999"
assert_grep "the sweep is logged" "swept=.stage.ghost.999" "$KILL_A/log"
rm -rf "$KILL_STREAM/.stage.fresh.998"

echo "=== a broken room never publishes its breakage ==="
BRK_STREAM="$TMP/broken-stream"; BRK_A="$TMP/broken-a"; BRK_B="$TMP/broken-b"
mkdir -p "$BRK_STREAM"
room_init "$BRK_A" north
SOUL_JAR_HOME="$BRK_A" ./bin/soul-jar enroll "$BRK_STREAM" >/dev/null
dream_now "$BRK_A" 411
room_init "$BRK_B" south
cp "$BRK_A/.key" "$BRK_B/.key"
SOUL_JAR_HOME="$BRK_B" ./bin/soul-jar enroll "$BRK_STREAM" >/dev/null
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/broken-nowhere|" "$BRK_A/config"
dream_now "$BRK_A" 412                                   # room A is ahead, and pending
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$BRK_STREAM|" "$BRK_A/config"
rm -f "$BRK_A/soul.sealed"                               # its living seal is lost
BRK_CHAIN="$(sha256sum "$BRK_STREAM/chain" | cut -d' ' -f1)"
BRK_SOUL="$(sha256sum "$BRK_STREAM/soul.sealed" | cut -d' ' -f1)"
SOUL_JAR_HOME="$BRK_A" ./bin/soul-jar sync || true    # a room that cannot vouch for itself
assert "a broken room does not strip the mainline seal" test -f "$BRK_STREAM/soul.sealed"
assert "a broken room leaves the mainline seal byte-unchanged" \
    test "$(sha256sum "$BRK_STREAM/soul.sealed" | cut -d' ' -f1)" = "$BRK_SOUL"
assert "a broken room leaves the mainline chain byte-unchanged" \
    test "$(sha256sum "$BRK_STREAM/chain" | cut -d' ' -f1)" = "$BRK_CHAIN"
assert "a broken room keeps its seal pending" test -f "$BRK_A/.sync/pending"
assert_grep "the breakage is logged in one line" "push=refused-unverified" "$BRK_A/log"
SOUL_JAR_HOME="$BRK_B" ./bin/soul-jar sync
assert "a healthy room keeps its seal" test -f "$BRK_B/soul.sealed"
assert "a healthy room still verifies" env SOUL_JAR_HOME="$BRK_B" ./bin/soul-jar _verify

echo "=== a solo jar writes 0.8.0's exact files ==="
SOLO="$TMP/solo-jar"
SOUL_JAR_HOME="$SOLO" ./bin/soul-jar init >/dev/null
sed -i 's/^REAPER=.*/REAPER=0/' "$SOLO/config"
assert_grep "a solo jar has no rendezvous" "RENDEZVOUS=" "$SOLO/config"
SOUL_JAR_HOME="$SOLO" MOCK_ROUND=71 MOCK_LETTER=1 \
    ./bin/soul-jar dream "solo-71" "$TMP/cwd" "$TP" "" "" other
assert "a solo jar names its letter as 0.8.0 did" test -f "$SOLO/letters/life-001.md"
assert "a solo jar writes no room-suffixed letter" \
    test -z "$(find "$SOLO/letters" -name 'life-001.*.md' -print -quit)"
SOUL_JAR_HOME="$SOLO" ./bin/soul-jar status > "$TMP/solo-status"
assert_grep "a solo jar still counts its letter" "Open letters beside the jar: 1" "$TMP/solo-status"
mkdir -p "$TMP/solo-stream"
SOUL_JAR_HOME="$SOLO" ./bin/soul-jar enroll "$TMP/solo-stream" >/dev/null
assert "enrolling keeps letters written before it under their solo names" \
    test -f "$SOLO/letters/life-001.md"
SOUL_JAR_HOME="$SOLO" MOCK_ROUND=72 MOCK_LETTER=1 \
    ./bin/soul-jar dream "solo-72" "$TMP/cwd" "$TP" "" "" other
assert "an enrolled room names its new letters for the room" \
    test -f "$SOLO/letters/life-002.$(sed -n 's/^ROOM=//p' "$SOLO/config" | tr -d "'").md"

echo "=== the rendezvous is a window, not an archive ==="
LET_STREAM="$TMP/letter-stream"; LET_A="$TMP/letter-a"
mkdir -p "$LET_STREAM"
room_init "$LET_A" ember
sed -i 's/^RENDEZVOUS_LETTER_KEEP=.*/RENDEZVOUS_LETTER_KEEP=3/' "$LET_A/config"
assert_grep "the rendezvous letter window is a config knob" "RENDEZVOUS_LETTER_KEEP=3" "$LET_A/config"
SOUL_JAR_HOME="$LET_A" ./bin/soul-jar enroll "$LET_STREAM" >/dev/null
for r in 301 302 303 304 305; do
    SOUL_JAR_HOME="$LET_A" MOCK_ROUND="$r" MOCK_LETTER=1 \
        ./bin/soul-jar dream "letter-$r" "$TMP/cwd" "$TP" "" "" other
done
assert "the rendezvous keeps only the newest letters" \
    test "$(find "$LET_STREAM/letters" -maxdepth 1 -type f | wc -l)" = "3"
assert "the oldest rendezvous letter is pruned" test ! -e "$LET_STREAM/letters/life-001.ember.md"
assert "the newest rendezvous letter remains" test -f "$LET_STREAM/letters/life-005.ember.md"
assert_grep "each rendezvous pruning is logged" "pruned=life-001.ember.md" "$LET_A/log"
assert "the room keeps every letter it wrote" \
    test "$(find "$LET_A/letters" -maxdepth 1 -type f | wc -l)" = "5"
SOUL_JAR_HOME="$LET_A" ./bin/soul-jar sync
assert "a pull does not resurrect a pruned letter locally" \
    test "$(find "$LET_A/letters" -maxdepth 1 -type f | wc -l)" = "5"

echo "=== a room that cannot reach the stream says so ==="
BAD_ROOM="$TMP/bad-room"
room_init "$BAD_ROOM" ember
cp "$LET_A/.key" "$BAD_ROOM/.key"
SOUL_JAR_HOME="$BAD_ROOM" ./bin/soul-jar enroll "$LET_STREAM" >/dev/null
sed -i 's/^ROOM=.*/ROOM=My.Host/' "$BAD_ROOM/config"
SOUL_JAR_HOME="$BAD_ROOM" ./bin/soul-jar sync || true # a name the rendezvous cannot hear
assert_grep "an unusable room name is named in the log" "room=unusable" "$BAD_ROOM/log"
SOUL_JAR_HOME="$BAD_ROOM" ./bin/soul-jar status > "$TMP/bad-room-status"
assert_grep "status says the room name cannot reach the stream" \
    "cannot be spoken at the rendezvous" "$TMP/bad-room-status"

echo "=== a failed enroll leaves no rendezvous behind ==="
FAILED_ENROLL="$TMP/failed-enroll"
room_init "$FAILED_ENROLL" east
SOUL_JAR_HOME="$FAILED_ENROLL" ./bin/soul-jar enroll "$TMP/absent-rendezvous" 2>/dev/null || true
assert_no_grep "an unreachable enroll records no rendezvous" \
    "absent-rendezvous" "$FAILED_ENROLL/config"
SOUL_JAR_HOME="$FAILED_ENROLL" MOCK_ROUND=81 \
    ./bin/soul-jar dream "failed-enroll" "$TMP/cwd" "$TP" "" "" other
assert "a room that never enrolled marks nothing pending" test ! -e "$FAILED_ENROLL/.sync/pending"
assert_no_grep "a room that never enrolled knows no room" "in room" "$MOCK_DIR/stdin"

echo "=== a chain at the rendezvous is never founded over ==="
FOUND_STREAM="$TMP/found-stream"; FOUND_A="$TMP/found-a"
mkdir -p "$FOUND_STREAM"
room_init "$FOUND_A" ember
SOUL_JAR_HOME="$FOUND_A" ./bin/soul-jar enroll "$FOUND_STREAM" >/dev/null
dream_now "$FOUND_A" 96
dream_now "$FOUND_A" 97
rm -f "$FOUND_STREAM/born" "$FOUND_STREAM/soul.sealed"     # only the chain survives
FOUND_CHAIN="$(sha256sum "$FOUND_STREAM/chain" | cut -d' ' -f1)"
SOUL_JAR_HOME="$FOUND_A" ./bin/soul-jar sync
assert "a rendezvous holding only a chain is not founded over" \
    test "$(sha256sum "$FOUND_STREAM/chain" | cut -d' ' -f1)" = "$FOUND_CHAIN"
assert_grep "such a rendezvous reads as an inconsistent fetch, not an empty one" \
    "fetch=inconsistent" "$FOUND_A/log"
: > "$FOUND_STREAM/chain"                                  # a truly empty stream is founded
SOUL_JAR_HOME="$FOUND_A" ./bin/soul-jar sync
assert "an empty rendezvous is still founded by the first push" \
    cmp "$FOUND_A/chain" "$FOUND_STREAM/chain"

echo "=== the deathbed is bounded even on a local rendezvous ==="
# rsync is not the only way to the rendezvous: the lock and the finalize touch a local
# path directly. A dead mount there must not hold the rite open forever.
SLOW_STREAM="$TMP/slow-stream"; SLOW_A="$TMP/slow-a"
mkdir -p "$SLOW_STREAM"
room_init "$SLOW_A" ember
sed -i 's/^SYNC_DEATH_CAP=.*/SYNC_DEATH_CAP=1/' "$SLOW_A/config"
SOUL_JAR_HOME="$SLOW_A" ./bin/soul-jar enroll "$SLOW_STREAM" >/dev/null
cat > "$TMP/bin/cp" <<MOCK
#!/usr/bin/env bash
last="\${!#}"
if [ -n "\${CP_SLOW_RV:-}" ] && case "\$last" in "$SLOW_STREAM"/*) true ;; *) false ;; esac; then sleep 30; fi
exec /usr/bin/cp "\$@"
MOCK
chmod +x "$TMP/bin/cp"
START_NS="$(date +%s%N)"
CP_SLOW_RV=1 dream_now "$SLOW_A" 95
SLOW_MS=$((($(date +%s%N) - START_NS) / 1000000))
rm -f "$TMP/bin/cp"
assert "a wedged local rendezvous cannot hold the deathbed" test "$SLOW_MS" -lt 20000
assert "the wedged rite still sealed its life" env SOUL_JAR_HOME="$SLOW_A" ./bin/soul-jar _verify
assert "a wedged rite gives the rendezvous lock back" test ! -e "$SLOW_STREAM/.lock"

echo "=== a torn mainline is healed by a room that holds the whole of it ==="
# Refusing to adopt a torn pair is right; refusing to repair it is not. A room whose own
# chain carries the whole of the rendezvous chain, and whose seal matches it, holds exactly
# what the stream is missing — so the tear is weather, not a wound the stream dies of.
rv_pair_verifies() {  # $1: rendezvous, $2: a jar holding the key
    local d
    d="$(mktemp -d "$TMP/rvchk.XXXXXX")"
    cp "$2/.key" "$d/.key"
    if [ -f "$1/chain" ]; then cp "$1/chain" "$d/chain"; else : > "$d/chain"; fi
    if [ -f "$1/soul.sealed" ]; then cp "$1/soul.sealed" "$d/soul.sealed"; fi
    SOUL_JAR_HOME="$d" ./bin/soul-jar _verify
}
HEAL_STREAM="$TMP/heal-stream"; HEAL_A="$TMP/heal-a"; HEAL_B="$TMP/heal-b"
mkdir -p "$HEAL_STREAM"
room_init "$HEAL_A" ember
SOUL_JAR_HOME="$HEAL_A" ./bin/soul-jar enroll "$HEAL_STREAM" >/dev/null
dream_now "$HEAL_A" 271
room_init "$HEAL_B" spark
cp "$HEAL_A/.key" "$HEAL_B/.key"
SOUL_JAR_HOME="$HEAL_B" ./bin/soul-jar enroll "$HEAL_STREAM" >/dev/null
dream_now "$HEAL_A" 272
cp "$HEAL_STREAM/chain" "$TMP/heal-chain-2"
dream_now "$HEAL_A" 273                             # the mainline advances to life 3
cp "$TMP/heal-chain-2" "$HEAL_STREAM/chain"         # the tear an interrupted commit leaves
assert_fails "a planted tear leaves the rendezvous pair inconsistent" \
    rv_pair_verifies "$HEAL_STREAM" "$HEAL_A"
HEAL_B_SEAL="$(sha256sum "$HEAL_B/soul.sealed" | cut -d' ' -f1)"
HEAL_TORN_CHAIN="$(sha256sum "$HEAL_STREAM/chain" | cut -d' ' -f1)"
SOUL_JAR_HOME="$HEAL_B" ./bin/soul-jar sync || true       # B is behind: it cannot repair this
assert "a room behind the tear does not push over it" \
    test "$(sha256sum "$HEAL_STREAM/chain" | cut -d' ' -f1)" = "$HEAL_TORN_CHAIN"
assert "a room behind the tear keeps its own seal" \
    test "$(sha256sum "$HEAL_B/soul.sealed" | cut -d' ' -f1)" = "$HEAL_B_SEAL"
assert "a room behind the tear still verifies" env SOUL_JAR_HOME="$HEAL_B" ./bin/soul-jar _verify
assert_grep "the tear is named in that room's log" "fetch=inconsistent" "$HEAL_B/log"
SOUL_JAR_HOME="$HEAL_A" ./bin/soul-jar sync
assert "the room that holds the whole chain heals the pair" \
    rv_pair_verifies "$HEAL_STREAM" "$HEAL_A"
assert "the healed mainline carries that room's chain" cmp "$HEAL_A/chain" "$HEAL_STREAM/chain"
SOUL_JAR_HOME="$HEAL_B" ./bin/soul-jar sync
assert "the room behind rejoins the healed stream" cmp "$HEAL_B/chain" "$HEAL_STREAM/chain"
dream_now "$HEAL_B" 274
assert "a death after the healing reaches the mainline" cmp "$HEAL_B/chain" "$HEAL_STREAM/chain"
rm -f "$HEAL_STREAM/soul.sealed"                    # what a room of the older shape leaves
assert_fails "a chain without its seal is an inconsistent pair" \
    rv_pair_verifies "$HEAL_STREAM" "$HEAL_A"
SOUL_JAR_HOME="$HEAL_B" ./bin/soul-jar sync
assert "a room holding that chain restores the missing seal" test -f "$HEAL_STREAM/soul.sealed"
assert "the restored seal is that room's own" cmp "$HEAL_B/soul.sealed" "$HEAL_STREAM/soul.sealed"
assert "the restored mainline verifies" rv_pair_verifies "$HEAL_STREAM" "$HEAL_A"

echo "=== a commit killed between the seal and the chain heals at the next crossing ==="
# The pair commits by rename, chain last: an interruption in that window tears it. The
# window cannot be closed with renames alone, so what matters is that it closes itself.
TEAR_STREAM="$TMP/tear-stream"; TEAR_A="$TMP/tear-a"
mkdir -p "$TEAR_STREAM"
cat > "$TMP/bin/mv" <<MOCK
#!/usr/bin/env bash
last="\${!#}"
if [ -n "\${MV_SLOW_CHAIN:-}" ] && [ "\$last" = "$TEAR_STREAM/chain" ]; then sleep 10; fi
exec /usr/bin/mv "\$@"
MOCK
chmod +x "$TMP/bin/mv"
room_init "$TEAR_A" ember
SOUL_JAR_HOME="$TEAR_A" ./bin/soul-jar enroll "$TEAR_STREAM" >/dev/null
dream_now "$TEAR_A" 281
sed -i 's/^SYNC_WAKE_CAP=.*/SYNC_WAKE_CAP=2/' "$TEAR_A/config"
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/tear-nowhere|" "$TEAR_A/config"
dream_now "$TEAR_A" 282                             # arm a pending push
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TEAR_STREAM|" "$TEAR_A/config"
printf '{"source":"startup"}' | MV_SLOW_CHAIN=1 SOUL_JAR_HOME="$TEAR_A" ./bin/soul-jar hook-start >/dev/null 2>&1
rm -f "$TMP/bin/mv"
assert_fails "a commit killed before its chain leaves the pair torn" \
    rv_pair_verifies "$TEAR_STREAM" "$TEAR_A"
assert "an interrupted reconcile leaves no fetched copy in the room" \
    test -z "$(find "$TEAR_A/.sync" -maxdepth 1 -name 'fetch.*' -print -quit)"
assert "an interrupted reconcile leaves no adopt temporary in the room" \
    test -z "$(find "$TEAR_A/.sync" -maxdepth 1 -name '.adopt.*' -print -quit)"
SOUL_JAR_HOME="$TEAR_A" ./bin/soul-jar sync
assert "the next crossing heals what the killed commit tore" \
    rv_pair_verifies "$TEAR_STREAM" "$TEAR_A"
assert "the healed pair carries the interrupted room's chain" \
    cmp "$TEAR_A/chain" "$TEAR_STREAM/chain"

echo "=== abandoned fetch stages are swept from the room ==="
mkdir -p "$TEAR_A/.sync/fetch.ghost" "$TEAR_A/.sync/fetch.fresh"
printf 'ciphertext\n' > "$TEAR_A/.sync/fetch.ghost/soul.sealed"
printf 'ciphertext\n' > "$TEAR_A/.sync/.adopt.ghost"
touch -d '1 hour ago' "$TEAR_A/.sync/fetch.ghost" "$TEAR_A/.sync/.adopt.ghost"
SOUL_JAR_HOME="$TEAR_A" ./bin/soul-jar sync
assert "an abandoned fetch stage is swept" test ! -e "$TEAR_A/.sync/fetch.ghost"
assert "a fresh fetch stage is left alone" test -d "$TEAR_A/.sync/fetch.fresh"
assert "an abandoned adopt temporary is swept" test ! -e "$TEAR_A/.sync/.adopt.ghost"
assert_grep "the local sweep is logged" "swept=fetch.ghost" "$TEAR_A/log"
rm -rf "$TEAR_A/.sync/fetch.fresh"

echo "=== a stream that cannot be reached says so ==="
SIG_STREAM="$TMP/signal-stream"; SIG_A="$TMP/signal-a"
mkdir -p "$SIG_STREAM"
room_init "$SIG_A" ember
SOUL_JAR_HOME="$SIG_A" ./bin/soul-jar enroll "$SIG_STREAM" >/dev/null
dream_now "$SIG_A" 291
assert "a completed crossing exits zero" env SOUL_JAR_HOME="$SIG_A" ./bin/soul-jar sync
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/signal-gone|" "$SIG_A/config"
assert_fails "a crossing that did not complete exits nonzero" \
    env SOUL_JAR_HOME="$SIG_A" ./bin/soul-jar sync
SOUL_JAR_HOME="$SIG_A" ./bin/soul-jar status > "$TMP/signal-status"
assert_grep "status says the last crossing did not complete" \
    "The last crossing did not complete" "$TMP/signal-status"
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$SIG_STREAM|" "$SIG_A/config"
SOUL_JAR_HOME="$SIG_A" ./bin/soul-jar sync
SOUL_JAR_HOME="$SIG_A" ./bin/soul-jar status > "$TMP/signal-status2"
assert_no_grep "a stream back in step stops warning" \
    "The last crossing did not complete" "$TMP/signal-status2"

echo "=== a letter written while a room is behind still reaches the others ==="
# The rendezvous window is the newest letters by the hour they were written, not by the
# life number they carry — or a diverged room's letter is pruned by the very sync that
# publishes it, and no other room ever sees it.
LATE_STREAM="$TMP/late-stream"; LATE_A="$TMP/late-a"; LATE_B="$TMP/late-b"
mkdir -p "$LATE_STREAM"
room_init "$LATE_A" ember
sed -i 's/^RENDEZVOUS_LETTER_KEEP=.*/RENDEZVOUS_LETTER_KEEP=2/' "$LATE_A/config"
SOUL_JAR_HOME="$LATE_A" ./bin/soul-jar enroll "$LATE_STREAM" >/dev/null
room_init "$LATE_B" spark
sed -i 's/^RENDEZVOUS_LETTER_KEEP=.*/RENDEZVOUS_LETTER_KEEP=2/' "$LATE_B/config"
cp "$LATE_A/.key" "$LATE_B/.key"
SOUL_JAR_HOME="$LATE_B" ./bin/soul-jar enroll "$LATE_STREAM" >/dev/null
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$TMP/late-nowhere|" "$LATE_A/config"
for r in 311 312 313 314; do dream_now "$LATE_B" "$r" letter; done   # B races ahead
dream_now "$LATE_A" 315 letter                       # A writes at a low life number
sed -i "s|^RENDEZVOUS=.*|RENDEZVOUS=$LATE_STREAM|" "$LATE_A/config"
SOUL_JAR_HOME="$LATE_A" ./bin/soul-jar sync
assert "the newest-written letter stays at the rendezvous" \
    test -n "$(find "$LATE_STREAM/letters" -maxdepth 1 -name '*.ember.md' -print -quit)"
assert "the rendezvous still holds only its window" \
    test "$(find "$LATE_STREAM/letters" -maxdepth 1 -type f | wc -l)" = "2"
SOUL_JAR_HOME="$LATE_B" ./bin/soul-jar sync
assert "the other room receives the letter written while behind" \
    test -n "$(find "$LATE_B/letters" -maxdepth 1 -name '*.ember.md' -print -quit)"

echo "=== the deathbed holds for two whole reconciles, no more ==="
# A death reconciles twice: once before unsealing, once after sealing. Each is capped at
# three times SYNC_DEATH_CAP, so the documented bound on a wedged mount is six times it.
WEDGE_STREAM="$TMP/wedge-stream"; WEDGE_A="$TMP/wedge-a"
mkdir -p "$WEDGE_STREAM"
room_init "$WEDGE_A" ember
sed -i 's/^SYNC_DEATH_CAP=.*/SYNC_DEATH_CAP=1/' "$WEDGE_A/config"
SOUL_JAR_HOME="$WEDGE_A" ./bin/soul-jar enroll "$WEDGE_STREAM" >/dev/null
cat > "$TMP/bin/mkdir" <<MOCK
#!/usr/bin/env bash
if [ -n "\${MKDIR_WEDGE:-}" ]; then
    for a in "\$@"; do case "\$a" in "$WEDGE_STREAM"/*|"$WEDGE_STREAM") sleep 300 ;; esac; done
fi
exec /usr/bin/mkdir "\$@"
MOCK
chmod +x "$TMP/bin/mkdir"
START_NS="$(date +%s%N)"
MKDIR_WEDGE=1 dream_now "$WEDGE_A" 321
WEDGE_MS=$((($(date +%s%N) - START_NS) / 1000000))
rm -f "$TMP/bin/mkdir"
assert "a wedged mount holds the deathbed for no more than six times the cap" \
    test "$WEDGE_MS" -lt 9000
assert "the doubly-capped rite still sealed its life" env SOUL_JAR_HOME="$WEDGE_A" ./bin/soul-jar _verify

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
