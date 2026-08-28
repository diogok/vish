# Handover — WebSocket review fixes

**State: T1 (S1, F1) landed.** Fragment reassembly no longer carries
the previous message's payload into the next fragmented message.
Next session starts at **T2**.

Last commit this card describes: the T1 commit
"ws-fixes: fragment reassembly state reset (plan T1)".

## Next: T2 — S2 handshake validation (F2/F3/F4/F10)

- **Plan (read):** `plans/ws-fixes/plan.md` card T2;
  `src/http/websocket.zig` `upgrade()` and `reject()`;
  `src/http/response.zig` `fromRequest`/`sendHeaders`;
  `src/loop/loop.zig` `onRequest`; notes.md "Test pitfalls" +
  "Measured behavior".
- **Do:** in `upgrade()` move `upgrade.len == 0 → error.NotWebSocket`
  before the method check (F4); after the key validation, reject when
  `req.headers.content_length > 0` or
  `req.headers.transfer_encoding != null` (F3); `reject()` sets
  `res.headers.connection = .close` (F2). Add unit tests for
  `upgrade()` (first direct ones): build a hand-constructed
  `Request` + `Response` against a fixed writer buffer, assert the
  error and the wire bytes; **never call `req.deinit()`** on them
  (notes). Update the "an invalid upgrade request gets a 400"
  integration test to a realistic request (`Connection: Upgrade` +
  bad key) asserting `Connection: close`, and fix its comment (F10).
- **Verify:** `zig build test` and `zig build` green; demo2 probe:
  rejected upgrade → 400 with `Connection: close`, socket closes
  promptly (no 1 s idle wait); body-bearing GET → 400; `POST /ws`
  without Upgrade header → routed (404 in demo2).
- **Stop-when:** commit "ws-fixes: handshake validation and rejection
  framing (plan T2)" with plan.md S2 crossed, progress.md entry, this
  file rewritten.

## Baseline

```sh
zig build test   # 106 tests after T1
zig build        # adds the demos
```

Live check: background-task `./zig-out/bin/demo2`, rebuild first
(`zig build`), then `python3 /tmp/ws_probe.py` (regenerate if gone:
handshake with RFC key, echo, ping, close; plus the S2 checks listed
above).

## Facts this task needs

- `Response.fromRequest` copies the request's `Connection` into the
  response — that is why the 400 today carries `Connection: Upgrade`;
  `reject()` must override it.
- The loop's keep decision closes only on `.close` on either side
  (loop.zig:216-222); forcing `.close` in `reject()` is what makes the
  connection drop.
- `upgrade()` allocates nothing through the request's allocator, so
  hand-constructed test `Request`s with comptime literal header
  strings are safe to drop without `deinit()`.

## Open risks / out of scope

- 16 MiB default cap (T4) is a judgment call; revisit only if a real
  workload needs more.
- The `error reading body: EndOfStream` warning from demo2's
  `POST /hello` formdata path is pre-existing — out of scope.
- Subprotocol *selection policy* beyond "first offered token" is out
  of scope (T5).
