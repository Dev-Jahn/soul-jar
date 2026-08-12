# 0.10.3 bash 3.2 heredoc removal

## Scan

The pre-change P7 scan found exactly three heredoc opens inside multiline command
substitutions in `bin/soul-jar`:

```text
434: "$RV_HOST" sh -s -- "$RV_PATH" "$mins" <<'SH' 2>/dev/null || true
470: "$RV_HOST" sh -s -- "$RV_PATH" "$ROOM" "$now" "$SYNC_LOCK_STALE" "$$" <<'SH'
872: "$RV_HOST" sh -s -- "$RV_PATH" "$keep" <<'SH' 2>/dev/null || true
```

They belonged to `_rv_sweep_stages`, `_rv_lock`, and
`_prune_rendezvous_letters`, respectively. A separate scan of every `$(` and
heredoc open found no additional instance. The remaining heredocs are top-level
variable loads, configuration/help text, or plain `ssh ... <<'SH'` calls outside
command substitution.

The post-change P7 scan produced no findings.

## Transformation

| Function | Extracted variable | New stdin path | Body SHA-256 |
|---|---|---|---|
| `_rv_sweep_stages` | `_rv_sweep_stages_script` | `printf` → `_with_deadline` → `ssh ... sh -s` | `6cf8b60687f1631d9006f3fafdaba0719959883582d92bca694e23a8ccacce99` |
| `_rv_lock` | `_rv_lock_script` | `printf` → `_with_deadline` → `ssh ... sh -s` | `3636c755e2b95663335236b79a477ddfee068e8e3b8069c4a314f27982c029cc` |
| `_prune_rendezvous_letters` | `_prune_rendezvous_letters_script` | `printf` → `_with_deadline` → `ssh ... sh -s` | `8dd85f59703fd21a08642a2e45862ef5fe2b7c2717c5950770b9c50f134aeaf6` |

Each body was compared with its pre-change body from `HEAD`, including a final
newline, and matched exactly. The existing `_with_deadline` P2 assertion still
verifies that its fd 5 path preserves stdin.

The plugin version and both suite version assertions are now `0.10.3`.
`tests/run.sh` still expected `0.10.1` before this change; that stale assertion
was updated after it caused the first P10 run's sole failure.

## P7 and P8

RED before the implementation:

```text
=== P7: no heredoc inside command substitution ===
FAIL no heredoc opens inside a nearby unclosed command substitution
=== P8: extracted remote scripts ===
FAIL the stage-sweep script is loaded with its remote find
FAIL the lock script is loaded with its remote mkdir
FAIL the letter-prune script is loaded with its remote removal

28 passed, 4 failed
```

GREEN after the implementation:

```text
=== P7: no heredoc inside command substitution ===
ok   no heredoc opens inside a nearby unclosed command substitution
=== P8: extracted remote scripts ===
ok   the stage-sweep script is loaded with its remote find
ok   the lock script is loaded with its remote mkdir
ok   the letter-prune script is loaded with its remote removal

32 passed, 0 failed
```

P7 documents its approximation: it follows a multiline `$(` for up to eight
lines and treats the first later `)` as the close. It catches all three original
call shapes.

## P9: stock macOS bash 3.2

The run used two jars under `/tmp/soul-jar-bash32.MvBI0H` on mini and only
`b200:/NHNHOME/jahn/.soul-jar-stream-scratch` as the rendezvous.

```text
P9 platform: GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
P9 timeout: absent
P9 founder rc: 0
P9 founder lock after enroll: absent
P9 founder stdout BEGIN
🏺 Room bash32-founder found the stream.
P9 founder stdout END
P9 founder stderr BEGIN
P9 founder stderr END
P9 joiner rc: 0
P9 joiner lock after enroll: absent
P9 joiner stdout BEGIN
🏺 Room bash32-joiner joins the stream.
P9 joiner stdout END
P9 joiner stderr BEGIN
P9 joiner stderr END
P9 adoption bytes: chain=92 soul=64
P9 result: PASS
```

Both stderr streams above are reproduced in full and are empty. The joiner's
chain and `soul.sealed` compared byte-for-byte with the founder's copies.

Cleanup evidence after the run:

```text
mini scratch: absent
b200 rendezvous: absent
```

## P10: Linux regression suites

```text
$ bash tests/run.sh
505 passed, 0 failed

$ bash tests/portability.sh
32 passed, 0 failed
```

Additional checks:

```text
bash -n bin/soul-jar tests/run.sh tests/portability.sh  # rc 0
git diff --check                                       # rc 0
```

RESULT: PASS — P7–P10 passed, including real bash 3.2 founder/adopter enrollment and complete scratch cleanup.
