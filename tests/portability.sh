#!/usr/bin/env bash
# macOS/BSD portability probes. Linux PATH shims stand in for the unavailable mac host.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d "$PWD/.portability-tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SCRIPT="$PWD/bin/soul-jar"
PASS=0; FAIL=0

# The suite itself must run on GNU and BSD alike (see run.sh for the same shims).
sedi() { sed -i.sedi-bak "$@" && rm -f "${@: -1}.sedi-bak"; }
command -v sha256sum >/dev/null 2>&1 || sha256sum() { shasum -a 256 "$@"; }

ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
assert() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

# A complete path for the exercised runtime, except for GNU timeout and sha256sum.
# shasum is deliberately present so the macOS checksum branch is real, not mocked.
MASK_BIN="$TMP/no-gnu-bin"
mkdir -p "$MASK_BIN"
for cmd in awk basename bash cat chmod cmp cp cut date dirname env find flock grep head jq \
           ln mkdir mktemp mv nohup openssl perl readlink rm rmdir rsync sed setsid sh shasum \
           sleep sort ssh stat tail touch tr uname wc; do
    src="$(type -P "$cmd" 2>/dev/null || true)"
    [ -n "$src" ] && ln -s "$src" "$MASK_BIN/$cmd"
done
MASKED_PATH="$MASK_BIN"

run_helper() {
    local path="$1"; shift
    PATH="$path" /bin/bash -c \
        'SOUL_JAR_SOURCE_ONLY=1 . "$1"; shift; "$@"' portability "$SCRIPT" "$@"
}

echo "=== P1: sync without timeout(1) ==="
ROOM="$TMP/room"
STREAM="$TMP/stream"
mkdir -p "$STREAM"
PATH="$MASKED_PATH" SOUL_JAR_HOME="$ROOM" /bin/bash "$SCRIPT" init >/dev/null
sedi 's/^ROOM=.*/ROOM=portability/' "$ROOM/config"
sedi "s|^RENDEZVOUS=.*|RENDEZVOUS=$STREAM|" "$ROOM/config"
sedi 's/^SYNC_DEATH_CAP=.*/SYNC_DEATH_CAP=1/' "$ROOM/config"
set +e
PATH="$MASKED_PATH" SOUL_JAR_HOME="$ROOM" /bin/bash "$SCRIPT" sync \
    >"$TMP/local.out" 2>"$TMP/local.err"
LOCAL_RC=$?
set -e
assert "a local rendezvous sync completes with timeout absent" test "$LOCAL_RC" -eq 0
assert "the local sync publishes its chain" test -f "$STREAM/chain"

HANG_BIN="$TMP/hanging-ssh"
mkdir -p "$HANG_BIN"
cat > "$HANG_BIN/ssh" <<'SH'
#!/usr/bin/env bash
sleep 10
SH
chmod +x "$HANG_BIN/ssh"
sedi 's|^RENDEZVOUS=.*|RENDEZVOUS=portability.invalid:/stream|' "$ROOM/config"
SECONDS=0
set +e
PATH="$HANG_BIN:$MASKED_PATH" SOUL_JAR_HOME="$ROOM" /bin/bash "$SCRIPT" sync \
    >"$TMP/remote.out" 2>"$TMP/remote.err"
REMOTE_RC=$?
set -e
REMOTE_ELAPSED=$SECONDS
assert "an unreachable remote returns nonzero" test "$REMOTE_RC" -ne 0
assert "the remote deadline returns within cap+2s" test "$REMOTE_ELAPSED" -lt 5
assert "the failed crossing leaves its explicit unreached marker" test -f "$ROOM/.sync/unreached"
assert "missing timeout cannot cascade into an unbound variable" \
    bash -c '! grep -qi "unbound variable" "$@"' _ "$TMP/remote.err" "$ROOM/log"

NO_RSYNC_BIN="$TMP/no-rsync-bin"
mkdir -p "$NO_RSYNC_BIN"
for src in "$MASK_BIN"/*; do
    [ "${src##*/}" = rsync ] && continue
    ln -s "$(readlink "$src")" "$NO_RSYNC_BIN/${src##*/}"
done
set +e
PATH="$NO_RSYNC_BIN" SOUL_JAR_HOME="$TMP/missing-jar" /bin/bash "$SCRIPT" init \
    >"$TMP/missing.out" 2>"$TMP/missing.err"
MISSING_RC=$?
set -e
assert "a missing required external fails before shaping the jar" test "$MISSING_RC" -ne 0
assert "the required-external error is one actionable line" \
    bash -c '[ "$(wc -l < "$1")" -eq 1 ] && grep -q "missing required command(s): rsync.*Homebrew" "$1"' \
    _ "$TMP/missing.err"

echo "=== P2: pure-bash deadline ==="
SECONDS=0
set +e
run_helper "$MASKED_PATH" _with_deadline 2 sleep 10 >"$TMP/deadline.out" 2>"$TMP/deadline.err"
DEADLINE_RC=$?
set -e
DEADLINE_ELAPSED=$SECONDS
assert "the fallback deadline reports GNU-compatible 124" test "$DEADLINE_RC" -eq 124
assert "the fallback kills a ten-second command in under five seconds" test "$DEADLINE_ELAPSED" -lt 5
HEREDOC_OUT="$(run_helper "$MASKED_PATH" _with_deadline 2 sh -c cat <<'EOF'
heredoc survives
EOF
)"
assert "the fallback passes heredoc stdin untouched" test "$HEREDOC_OUT" = "heredoc survives"
set +e
run_helper "$MASKED_PATH" _with_deadline 2 command-that-is-not-installed \
    >"$TMP/missing-command.out" 2>"$TMP/missing-command.err"
MISSING_COMMAND_RC=$?
set -e
assert "a missing deadline command reports 127" test "$MISSING_COMMAND_RC" -eq 127
assert "a missing deadline command fails loudly once" \
    bash -c '[ "$(wc -l < "$1")" -eq 1 ] && grep -q "command-that-is-not-installed: command not found" "$1"' \
    _ "$TMP/missing-command.err"

echo "=== BSD lock/detach helpers ==="
NO_UTIL_BIN="$TMP/no-util-bin"
mkdir -p "$NO_UTIL_BIN"
for src in "$MASK_BIN"/*; do
    case "${src##*/}" in flock|setsid) continue ;; esac
    ln -s "$(readlink "$src")" "$NO_UTIL_BIN/${src##*/}"
done
DETACHED_OUT="$(run_helper "$NO_UTIL_BIN" _run_detached sh -c 'printf detached')"
assert "the Perl setsid branch launches the command" test "$DETACHED_OUT" = detached

LOCK_FILE="$TMP/perl.lock"
LOCK_READY="$TMP/perl.locked"
PATH="$NO_UTIL_BIN" /bin/bash -c '
    SOUL_JAR_SOURCE_ONLY=1 . "$1"
    exec 7>"$2"
    _flock -n 7 || exit 1
    : > "$3"
    sleep 10
' portability "$SCRIPT" "$LOCK_FILE" "$LOCK_READY" &
LOCKER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$LOCK_READY" ] && break; sleep 0.1; done
assert "the Perl flock branch acquires the inherited fd lock" test -f "$LOCK_READY"
set +e
PATH="$NO_UTIL_BIN" /bin/bash -c '
    SOUL_JAR_SOURCE_ONLY=1 . "$1"
    exec 7>"$2"
    _flock -n 7
' portability "$SCRIPT" "$LOCK_FILE"
CONTENDER_RC=$?
set -e
assert "the Perl flock branch excludes a contender" test "$CONTENDER_RC" -ne 0
kill "$LOCKER_PID" 2>/dev/null || true
wait "$LOCKER_PID" 2>/dev/null || true
assert "the Perl flock lock releases with its holder" \
    env PATH="$NO_UTIL_BIN" /bin/bash -c '
        SOUL_JAR_SOURCE_ONLY=1 . "$1"
        exec 7>"$2"
        _flock -n 7
    ' portability "$SCRIPT" "$LOCK_FILE"

echo "=== P3: portable sha256 ==="
printf 'same bytes everywhere\n' > "$TMP/input"
EXPECTED="$(sha256sum "$TMP/input" | cut -d' ' -f1)"
GNU_HASH="$(run_helper "$PATH" _sha256 "$TMP/input")"
BSD_HASH="$(run_helper "$MASKED_PATH" _sha256 "$TMP/input")"
assert "the GNU checksum branch emits hex only" test "$GNU_HASH" = "$EXPECTED"
assert "the shasum branch is byte-identical" test "$BSD_HASH" = "$EXPECTED"

echo "=== P4: BSD stat/date proxy ==="
if stat -c%s "$SCRIPT" >/dev/null 2>&1; then
    # GNU host: shim stat/date into their BSD spellings so the BSD branches run.
    BSD_BIN="$TMP/bsd-bin"
    mkdir -p "$BSD_BIN"
    REAL_STAT="$(type -P stat)"
    REAL_DATE="$(type -P date)"
    export REAL_STAT REAL_DATE
    cat > "$BSD_BIN/stat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    -c*) exit 1 ;;
    -f%z) exec "$REAL_STAT" -c%s "$2" ;;
    -f%m) exec "$REAL_STAT" -c%Y "$2" ;;
    *) exit 1 ;;
esac
SH
    cat > "$BSD_BIN/date" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    -d) exit 1 ;;
    -r)
        epoch="$2"; shift 2
        exec "$REAL_DATE" -d "@$epoch" "$@"
        ;;
    -j)
        [ "${2:-}" = "-f" ] || exit 1
        value="$4"; output="$5"
        exec "$REAL_DATE" -d "$value" "$output"
        ;;
    *) exec "$REAL_DATE" "$@" ;;
esac
SH
    chmod +x "$BSD_BIN/stat" "$BSD_BIN/date"
    BSD_PATH="$BSD_BIN:$MASKED_PATH"
else
    # Real BSD userland: no proxy needed — the branches under test are the native ones,
    # and the "GNU" comparisons below degrade to self-consistency checks, which is the point.
    BSD_PATH="$MASKED_PATH"
fi

GNU_SIZE="$(run_helper "$PATH" _fsize "$TMP/input")"
BSD_SIZE="$(run_helper "$BSD_PATH" _fsize "$TMP/input")"
assert "BSD stat reports the same file size" test "$BSD_SIZE" = "$GNU_SIZE"
GNU_MTIME="$(run_helper "$PATH" _fmtime "$TMP/input")"
BSD_MTIME="$(run_helper "$BSD_PATH" _fmtime "$TMP/input")"
assert "BSD stat reports the same mtime epoch" test "$BSD_MTIME" = "$GNU_MTIME"
BSD_MTIME_KEY="$(run_helper "$BSD_PATH" _fmtime_key "$TMP/input")"
assert "BSD stat supplies a stable zero-nanosecond sort key" \
    test "$BSD_MTIME_KEY" = "$(printf '%012d000000000' "$BSD_MTIME")"
EPOCH=1700000000
GNU_ISO="$(run_helper "$PATH" _epoch_to_iso "$EPOCH")"
BSD_ISO="$(run_helper "$BSD_PATH" _epoch_to_iso "$EPOCH")"
assert "BSD date renders the same epoch" test "$BSD_ISO" = "$GNU_ISO"
assert "BSD date parses the portable ISO timestamp" \
    test "$(run_helper "$BSD_PATH" _iso_to_epoch "$GNU_ISO")" = "$EPOCH"
COLON_ISO="$(printf '%s\n' "$GNU_ISO" | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
assert "BSD date parses pre-0.10.1 timestamps with a colon zone" \
    test "$(run_helper "$BSD_PATH" _iso_to_epoch "$COLON_ISO")" = "$EPOCH"
BSD_NOW="$(run_helper "$BSD_PATH" _iso_now)"
assert "the portable current timestamp has an explicit numeric zone" \
    bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]]' _ "$BSD_NOW"

echo "=== P6: static choke points ==="
VIOLATIONS="$TMP/violations"
awk '
    /^_[[:alnum:]_]+\(\)[[:space:]]*[({]/ {
        fn = $1; sub(/\(\).*/, "", fn)
    }
    /timeout -k|sha256sum|stat -c|date -I|date -d|readlink -f/ {
        if (fn !~ /^_(with_deadline|sha256|sha256_mode|stat_mode|fsize|fmtime|fmtime_key|date_mode|epoch_to_iso|iso_to_epoch|self_path|require_runtime)$/)
            print FNR ":" $0
    }
    /^}/ { fn = "" }
' "$SCRIPT" > "$VIOLATIONS"
assert "GNU-only spellings occur only in portability helpers" test ! -s "$VIOLATIONS"
assert "the plugin version is 0.10.1" \
    test "$(jq -r .version .claude-plugin/plugin.json)" = "0.10.1"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
