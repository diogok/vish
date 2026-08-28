# Handover — WebSocket review fixes

**State: T4 (S4, F5) landed.** Inbound payloads are capped at
`max_payload` (private field, default 16 MiB) — enforced before the
allocation in `readFrame` and cumulatively in `appendFrag` — and
over-size input fails with close 1009. Next session starts at **T5**.

Last commit this card describes: the T4 commit "ws-fixes: max payload
cap with close 1009 (plan T4)".

## Next: T5 — S5 subprotocol negotiation (F6)

- **Plan (read):** `plans/ws-fixes/plan.md` F6 design line and card
  T5; `src/http/websocket.zig` `upgrade()` header tail (156-181 — the
  `accept_b64` + `extra` construction); `src/http/response.zig`
  `ExtraHeader` (100-103) and the extra-header send loop (287);
  `src/http/request.zig:192` (`sec_websocket_protocol`);
  docs/usage.md WebSocket section (304-330); docs/architecture.md
  (81-90); notes.md "RFC 6455" (the §4.1 subprotocol MUSTs).
- **Do:**
  - `selectSubprotocol(value: []const u8) ?[]const u8` top-level
    private helper: split on commas, take the first non-empty token
    (OWS-trimmed); null when every token is empty. Returns a subslice
    of `value` — no allocation.
  - In `upgrade()`, when `req.headers.sec_websocket_protocol.len > 0`
    and a token is selected, grow the `extra` array (currently
    1-entry, stack-local) to 2 entries so the 101 carries
    `Sec-WebSocket-Protocol: <token>` alongside
    `Sec-WebSocket-Accept`. No token selected → no header (plan
    decision: a malformed list proceeds without one).
  - Unit tests for `selectSubprotocol`: first of several tokens, OWS
    around tokens, single token, empty string / all-empty list → null.
    Plus one `upgradeOutcome`-style test: handshake with
    `sec_websocket_protocol = "chat, superchat"` → `.ok` and the wire
    buffer contains `Sec-WebSocket-Protocol: chat`.
  - Integration test (model on the one at ~1306): handshake request
    carrying `Sec-WebSocket-Protocol: chat, superchat` → the 101
    carries `Sec-WebSocket-Protocol: chat`.
  - Docs: architecture.md line 90 ("does not negotiate subprotocols or
    extensions" → subprotocols are echoed, extensions still not);
    usage.md (one sentence in the WebSocket section: the 101 echoes
    the first offered subprotocol).
- **Verify:** `zig build test` and `zig build` green; demo2 probe:
  handshake with `Sec-WebSocket-Protocol: chat, superchat` → 101
  carries `Sec-WebSocket-Protocol: chat` (extend /tmp/ws_t2_probe.py
  or a new case; the probe script recipe is in notes.md).
- **Stop-when:** commit "ws-fixes: subprotocol negotiation (plan T5)"
  with plan.md S5 crossed, progress.md entry, this file rewritten.

## Baseline

```sh
zig build test   # 118 tests after T4
zig build        # adds the demos
```

Live check: background-task `./zig-out/bin/demo2` (rebuild first with
`zig build`), then `python3 /tmp/ws_t2_probe.py` (regenerate from
notes.md "Measured behavior (post-S2)" if gone).

## Facts this task needs

- The `extra` array is a stack-local `[_]response.ExtraHeader`
  assigned to `res.headers.extra` and consumed by `res.send()` inside
  `upgrade()` — a 2-entry local is equally safe; the header values
  point at the request's header strings (alive for the request) and
  the stack `accept_b64`, all valid until `send()` returns.
- `selectSubprotocol` must be a top-level private fn (not a method):
  it is the unit-testable unit per the plan, and it needs no state.
- The RFC §4.1 obligation (notes.md): the server MUST echo the header
  when the client sent it, and clients that requested subprotocols and
  got none treat the handshake as failed — that is why the echo is a
  fix, not a nicety.
- The existing `upgradeOutcome` helper (websocket.zig ~540s) returns
  an enum — a new subprotocol test asserts on `writer.end`'s buffer,
  not on the enum, so no helper change is needed.
- The integration test at ~1377 ("an invalid upgrade request gets a
  400") already sends realistic headers; the new subprotocol
  integration test can copy its setup and add the one header.
- Close-code bytes on the wire: 1002 = `0x03 0xea`, 1009 = `0x03
  0xf1` (a previous plan card got 1009 wrong — compute, don't copy).

## Open risks / out of scope

- The 16 MiB default cap (T4) is a judgment call; revisit only if a
  real workload needs more (plan.md "Open risks").
- First-token selection is not full negotiation (the server cannot
  reject a subprotocol) — sanctioned in plan.md "Open risks".
- The `error reading body: EndOfStream` warning from demo2's
  `POST /hello` formdata path is pre-existing — out of scope.
- T6 (S6) remains after T5: full re-verify, docs consistency pass
  (usage.md error list, architecture.md), close the plan.
