# Handover — WebSocket review fixes

**Status: complete.** All ten findings (F1–F10) are fixed (S1–S5),
and T6 closed the plan with a full re-verify and a docs pass. No
next task.

## Final state

- Branch `websocket`, working tree clean. Commits, newest last:
  `6be8e24` (plan) → `7f0909e` (T1) → `c05d22f` (T2) → `20f986b`
  (T3 **and** T4 — the S3 code landed inside the T4 commit) →
  `405fe78` (T5) → this commit (T6). There is no commit labeled
  "plan T3"; see the Session 4 progress entry for the record.
- `src/http/websocket.zig`: fragment-reassembly reset, handshake
  validation + 400 close framing, close-handshake strictness
  (exactly-once Close, RFC 6455 §7.4 code range, `ReadFailed` on
  transport failure), `max_payload` cap (16 MiB default) with close
  1009, subprotocol negotiation (first non-empty offered token
  echoed in the 101). 122 tests, all passing; demos compile.
- Docs: architecture.md and usage.md WebSocket sections reflect the
  post-fix behavior (error list, subprotocol echo, 1009 cap).
- Final live probe: 8/8 against a fresh demo2 (400 framing + prompt
  close, body-bearing GET 400, POST-without-Upgrade 404,
  101/accept/text echo, subprotocol echo, binary echo, ping→pong,
  close handshake + EOF). Probe script: /tmp/ws_t2_probe.py
  (regeneratable from notes.md "Environment recipes").

## Out of scope / sanctioned (no action)

- 16 MiB default cap and first-token subprotocol selection:
  sanctioned judgment calls (plan.md "Open risks"); both trivially
  revisited later (private field; one-helper change).
- Pre-existing `error reading body: EndOfStream` warning from
  demo2's `POST /hello` formdata path — unrelated, left alone.
- Merging the branch into main is a user decision.
