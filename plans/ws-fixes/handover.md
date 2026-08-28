# Handover — WebSocket review fixes

**State: T5 (S5, F6) landed. All code fixes (F1–F10) are in.**
Subprotocols are negotiated: the 101 echoes the first non-empty
offered subprotocol. Only **T6 — the wrap-up (S6)** remains: full
re-verify, docs consistency pass, close the plan.

Last commit this card describes: the T5 commit "ws-fixes: subprotocol
negotiation (plan T5)".

## Next: T6 — S6 wrap-up — full re-verify, docs pass, close the plan

- **Plan (read):** `plans/ws-fixes/plan.md` card T6 and "Open risks";
  notes.md "Measured behavior (post-S2)" + "Environment recipes"
  (probe recipe); the WebSocket sections of docs/usage.md (304-330)
  and docs/architecture.md (81-90).
- **Do:**
  - `zig build test` (122 tests) and `zig build` green.
  - Fresh demo2 (background task) + full probe:
    `python3 /tmp/ws_t2_probe.py` — 6 cases: 400 framing + prompt
    close, body-bearing GET → 400, POST-without-Upgrade → 404, valid
    101/accept/text-echo, subprotocol echo, binary echo. If the script
    is gone, regenerate from the notes.md recipes. Optionally extend
    with a ping→pong and a close-handshake case (the live-loop
    integration test in websocket.zig already covers both in
    `zig build test`).
  - Docs sweep (pre-checked this session — nothing stale remains;
    confirm, don't hunt): usage.md error list (328) matches
    `NotWebSocket`/`HandshakeRejected`/`UpgradeFailed`; architecture.md
    (85-90) covers subprotocol echo + the 1009 cap. One judgment call
    to make: add a sentence to usage.md's WebSocket section that
    inbound payloads over `max_payload` (default 16 MiB) fail with
    close 1009 — it is user-visible behavior. If added, record it in
    the progress entry.
  - Cross S6 in plan.md; final progress entry ("S6 done; plan closed;
    branch state: T1–T6 committed"); rewrite this file to mark the
    task complete (no next task).
- **Verify:** `zig build test`, `zig build`, full probe green; all
  plan boxes (S1–S6) checked; working tree clean after the final
  commit.
- **Stop-when:** commit "ws-fixes: full re-verify, docs pass, close
  plan (plan T6)". That is the last commit of the plan.

## Baseline

```sh
zig build test   # 122 tests after T5
zig build        # adds the demos
```

Live check: background-task `./zig-out/bin/demo2` (rebuild first with
`zig build`), then `python3 /tmp/ws_t2_probe.py` (6 cases, all
expected to pass).

## Facts this task needs

- The probe cases and their expected wire behavior are recorded in
  notes.md "Measured behavior (post-S2)"; the 6-case probe layout
  (A bad-key 400/close, B body-GET 400, C POST 404, D valid
  handshake + text echo, E subprotocol echo, F binary echo) is in
  progress.md's Session 3 entry.
- The two live-loop integration tests (websocket.zig ~1360s:
  handshake/echo/ping/close, invalid-400; ~1470: subprotocol) already
  exercise ping/pong and the close handshake end-to-end inside
  `zig build test` — the probe extension for those is optional, not
  required.
- Close-code bytes if any new assertion is written: 1000 = `0x03
  0xe8`, 1002 = `0x03 0xea`, 1009 = `0x03 0xf1`.
- `git log --oneline` on the branch should end with one commit per
  stage: planning, T1, T2, T3, T4, T5, T6. The working tree must be
  clean when T6 finishes.

## Open risks / out of scope (final)

- The 16 MiB default cap and first-token subprotocol selection are
  sanctioned judgment calls (plan.md "Open risks") — no action in T6.
- The `error reading body: EndOfStream` warning from demo2's
  `POST /hello` formdata path is pre-existing — out of scope, stays.
- Merging the branch back to main is a user decision, not part of the
  plan.
