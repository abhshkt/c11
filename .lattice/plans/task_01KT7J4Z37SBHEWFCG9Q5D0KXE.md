# C11-121: new-split surface ref not immediately addressable; default-agent launch fails with 'Surface not found'

## Symptoms (hit live 2026-06-03 during l10n pane orchestration)

1. **Registration race on new-split.** `c11 new-split right` returns `OK surface:N workspace:M`, but an immediate follow-up command targeting `surface:N` (e.g. `c11 default-agent launch --in-surface surface:N`) fails with `Surface not found: surface:N`. Seconds later the surface appears in `c11 tree` and is addressable by `send`/`read-screen`.

2. **default-agent launch resolution stricter/different from send.** Even ~30s after creation, `c11 default-agent launch --in-surface surface:269` kept failing with `Surface not found` while `c11 send --workspace workspace:1 --surface surface:269` and `read-screen` on the same ref succeeded. Surface JSON showed `tty: null` at the time — launch may require a fully-wired PTY, or resolve refs against a different/stale registry than send.

3. Possibly related: an earlier attempt (surface:268) had `default-agent launch` return plain `OK`, yet the agent never booted and the pane was gone from the tree minutes later — no tracks from the prompt it was given.

## Repro sketch
`OUT=$(c11 new-split right); SURF=$(echo $OUT | grep -oE 'surface:[0-9]+'); c11 default-agent launch --in-surface $SURF --cwd /path --prompt-file /tmp/x.md` → Surface not found.

## Workaround
Create split → sleep 3 → verify in tree → `c11 send --workspace W --surface S "claude --dangerously-skip-permissions '<prompt>'"` instead of default-agent launch.

## Suggested fix directions
- Make new-split's reply synchronous with registry insertion (ref addressable when the envelope returns).
- Align default-agent launch's surface resolution with send's; if it needs the PTY, wait/retry internally rather than erroring.
- Audit why launch returned OK on surface:268 without booting anything.
