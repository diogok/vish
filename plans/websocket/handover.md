# Handover — WebSocket support

**State: complete.** All four stages (S1 handshake, S2 frame codec + API,
S3 tests, S4 demo + docs) are landed, verified, and committed.
`plan.md` is fully checked. There is no in-flight work.

## Baseline

```sh
zig build test   # 104/104 pass (22 websocket unit + 2 integration + rest)
zig build        # default build, demos included
```

Live check (optional): `zig-out/bin/demo2` + the curl 101 probe from
AGENTS.md, or the python3 masked-frame round-trip used in S4
(stdlib only: socket/base64/hashlib/os).

## Where things live

- `src/http/websocket.zig` — `WebSocket` (file-as-struct): `upgrade`,
  `next() !Message`, `sendText/sendBinary/ping/pong/close/flush/deinit`,
  frame codec, protocol enforcement, plus the unit and integration test
  blocks.
- `src/http/request.zig` / `response.zig` — the S1 header fields,
  `Status.Switching_Protocols`, `Connection.upgrade` both sides,
  `Response.upgraded`.
- `src/loop/loop.zig` — upgraded connections close after the handler.
- `src/demo2.zig` — `/ws` echo route (`WsEchoHandler`, prepended to the
  CombinedRouter).
- Docs: README feature list, `docs/usage.md` (WebSocket section),
  `docs/architecture.md` (module line + WebSocket lifecycle section).

## If this is reopened

Likely follow-ups (none currently planned): a WebSocket *client*,
subprotocol negotiation, a max-message-size knob, ping keep-alive
initiation, and batching flushes instead of per-frame flush. Session
history and the stdlib gotchas are in `progress.md`.
