# WebSocket review fixes

Follow-up to the `websocket` branch (commit `bde8dc4`). A review found
bugs and two accepted-risk limitations that real clients break on. This
plan fixes all of them. Supersedes two "open risks" decisions from
`plans/websocket/plan.md`: "no max-message-size knob" and "subprotocols
are parsed but not negotiated" are now in scope.

## Goal

Make `src/http/websocket.zig` correct against RFC 6455 on the paths the
review found broken: fragment reassembly state, handshake validation and
rejection framing, close-handshake strictness, bounded payload
allocation, and subprotocol negotiation. All changes stay in
`websocket.zig` plus its tests, and update the two docs that describe
the old (wrong or limited) behavior.

## Findings (from the review; evidence in notes.md)

- **F1 — data corruption:** a completed fragmented message never resets
  `frag_len`; the next fragmented message is appended after the stale
  payload and returned with the old prefix ("Hello" + "World" →
  "HelloWorld"). Reproduced.
- **F2 — rejected handshake framing:** `reject()` inherits the
  request's `Connection: Upgrade` into the 400, sends no
  `Content-Length`, and the loop's keep-alive decision keeps the
  connection; measured close after the full 1.00 s idle window (hangs
  forever with `idle_timeout_in_millis = 0`).
- **F3 — body-bearing GETs accepted:** `upgrade()` checks only the
  method, not the body, contradicting its own comment. Reproduced:
  101 sent, then leftover body bytes desync the frame stream → 1002 on
  the client's first real frame.
- **F4 — check order:** a non-GET request *without* an `Upgrade` header
  gets 400 (`HandshakeRejected`) instead of `error.NotWebSocket`,
  contradicting the documented contract; any handler that calls
  `upgrade()` unconditionally 400s all non-GET traffic.
- **F5 — unbounded payload allocation:** `readAlloc` allocates the full
  (attacker-supplied, up to `usize` max) length before reading; fragment
  reassembly grows without bound. `CloseCode.message_too_big = 1009`
  is dead code.
- **F6 — no subprotocol negotiation:** `sec_websocket_protocol` is
  parsed but never echoed; RFC 6455 §4.1 makes the echo mandatory when
  the client sent the header, and clients that requested subprotocols
  and got none fail the handshake (browsers fire `onerror`; Node `ws`
  errors).
- **F7 — Close not surfaced "exactly once":** a second Close frame from
  the peer returns another `.close` Message (the `next()` doc promises
  once).
- **F8 — close code 0 on the wire accepted:** a 2-byte `0x0000` payload
  is treated as "no status" instead of failing 1002 (RFC 6455 §7.4:
  values 0–999 MUST NOT be used as status codes).
- **F9 — raw transport error escapes `next()`:** a failed pong (or
  close-echo) write propagates the raw writer error instead of the
  documented `ReadFailed` after latching `failed`.
- **F10 — misleading test comment:** "an invalid upgrade request gets a
  400" blames the malformed key, but the 400 actually fires on the
  `Connection: close` mismatch.

## Design decisions

- **F1:** after a complete fragmented message, zero `frag_len` but keep
  the buffer (the returned slice points into it). `appendFrag` starts
  fresh when `frag_len == 0` (reusing retained capacity) instead of
  `frag.len == 0`.
- **F2:** `reject()` forces `res.headers.connection = .close`. A 400
  with no body is then unambiguously framed by the close, and
  `onRequest` (loop.zig:216-222) returns `.close`.
- **F3:** reject (400) when `req.headers.content_length > 0` or
  `req.headers.transfer_encoding != null`. RFC 6455 §4.1 handshakes are
  body-less GETs; the alternative (draining) is rejected because the
  body is not ours to consume silently.
- **F4:** check `upgrade.len == 0 → error.NotWebSocket` *before* the
  method check. No-`Upgrade` requests are "not an upgrade attempt" by
  the function's own contract, regardless of method.
- **F5:** new private field `max_payload: usize` defaulting to
  `max_payload_default = 16 * 1024 * 1024`. Enforced twice: per frame
  in `readFrame` (before `readAlloc` — bounds the allocation) and
  cumulatively in `appendFrag` (bounds reassembly). Violation fails the
  protocol with `message_too_big` (1009), which gives the code a live
  use. The field stays private (same-file tests can set it); a public
  knob is a follow-up if ever needed.
- **F6:** when `sec_websocket_protocol` is present, echo exactly one
  selected subprotocol — the first non-empty comma-separated token
  (trimmed of OWS) — as `Sec-WebSocket-Protocol` in the 101, carried in
  `res.headers.extra` alongside `Sec-WebSocket-Accept`. No token
  (malformed list) → no header, session proceeds (a client that sent
  garbage cannot be told which subprotocol to use; failing is stricter
  but adds no safety here). Helper `selectSubprotocol` is a top-level
  private function so it unit-tests without a handshake.
- **F7:** new private flag `close_surfaced`. A Close arriving after one
  was already surfaced → `failProtocol(.protocol_error)` (the peer MUST
  NOT send frames after its Close). A peer Close answering our own
  server-initiated `close()` still surfaces once, as today.
- **F8:** the close-payload check becomes
  `len == 1 or (len >= 2 and (code < 1000 or code > 4999 or
  code == 1005 or code == 1006))` — the `code != 0` carve-out goes
  (a 2-byte `0x0000` now fails), but a 0-byte payload stays legal
  ("no status present", RFC 6455 §5.5.1): without the `len >= 2`
  guard, the empty case would hit `code < 1000` (code defaults to 0)
  and regress.
- **F9:** in `next()`, a failed pong or close-echo write latches
  `failed` (via `writeFrame`) and returns `error.ReadFailed`. `next()`
  doc gains the transport-failure line.
- **F10:** fold into the S2 test update.

## Work items

- [x] S1 — F1 fragment reassembly state:
  - [x] `next()`: reset `frag_len` after a complete fragmented message
  - [x] `appendFrag`: fresh start on `frag_len == 0`
  - [x] tests: two consecutive fragmented messages; fragmented then
        single-frame then fragmented (the review reproducer)
  - [x] verify: `zig build test`
- [x] S2 — F2/F3/F4/F10 handshake validation and rejection framing:
  - [x] `upgrade()`: `upgrade.len == 0` check first (F4)
  - [x] `upgrade()`: reject on `content_length > 0` or
        `transfer_encoding != null` (F3)
  - [x] `reject()`: force `Connection: close` (F2)
  - [x] unit tests for all `upgrade()` reject paths (first direct unit
        tests of `upgrade`): non-GET without Upgrade → NotWebSocket +
        nothing written; body-bearing GET → 400 + `Connection: close`;
        chunked GET → 400; bad key → 400
  - [x] integration test: realistic rejected request (`Connection:
        Upgrade` + bad key) → 400 + `Connection: close`, comment fixed
        (F10)
  - [x] verify: `zig build test`, `zig build`, demo probe (400 closes
        promptly; body-bearing GET → 400; non-GET without Upgrade →
        routes through)
- [x] S3 — F7/F8/F9 close-handshake strictness:
  - [x] `close_surfaced` flag; second Close → `ProtocolError` (F7)
  - [x] close-code range: 0–999 rejected incl. `0x0000` (F8)
  - [x] failed pong/close-echo write → latch + `ReadFailed` (F9)
  - [x] `next()` doc: transport-failure line
  - [x] tests: second Close frame → ProtocolError; `0x0000` close →
        close 1002; ping with failing writer → ReadFailed + latch
  - [x] verify: `zig build test`
- [x] S4 — F5 max payload:
  - [x] `max_payload` field + `max_payload_default` (16 MiB)
  - [x] `readFrame`: enforce before `readAlloc` → 1009
  - [x] `appendFrag`: cumulative check → 1009
  - [x] tests: single frame over cap → ProtocolError + close 1009
        (0x03e9); fragments summing over cap → ProtocolError
  - [x] docs: architecture.md size-limit line
  - [x] verify: `zig build test`, `zig build`
- [ ] S5 — F6 subprotocol negotiation:
  - [ ] `selectSubprotocol(value) ?[]const u8` helper
  - [ ] `upgrade()`: echo the selected subprotocol in the 101 when the
        request carried the header
  - [ ] unit tests for `selectSubprotocol` (first token, OWS trim,
        empty list → null)
  - [ ] integration test: handshake with `Sec-WebSocket-Protocol:
        chat, superchat` → 101 carries `Sec-WebSocket-Protocol: chat`
  - [ ] docs: architecture.md subprotocol line, usage.md note
  - [ ] verify: `zig build test`, `zig build`, demo probe
- [ ] S6 — wrap-up:
  - [ ] full re-verify: `zig build test`, `zig build`, complete demo
        probe (handshake/echo/ping/close + every new behavior: 400
        framing, body-bearing GET, subprotocol echo, POST-without-Upgrade
        routing)
  - [ ] docs consistency pass (usage.md error list, architecture.md
        WebSocket section)
  - [ ] verify: everything green, plan items all crossed, final
        progress entry

## Task cards

### T1. S1 fragment reassembly — no stale prefix on the second fragmented message

- **Plan (read):** `src/http/websocket.zig` lines 217-260 (`next()`
  data-frame branch) and 385-396 (`appendFrag`); the F1 reproducer in
  notes.md ("Verified facts").
- **Do:** reset `frag_len` to 0 in the final-fragment branch of
  `next()` after validation, before returning (keep the `frag` buffer —
  the returned slice points into it). Change `appendFrag`'s fresh-start
  test from `self.frag.len == 0` to `self.frag_len == 0`. Add the three
  tests above.
- **Verify:** `zig build test` green. The new two-fragmented-messages
  test prints no diff (it failed with "HelloWorld" before the fix).
- **Stop-when:** verify green; commit "ws-fixes: fragment reassembly
  state reset (plan T1)" with plan.md S1 crossed, progress.md entry,
  handover.md rewritten.

### T2. S2 handshake validation — NotWebSocket ordering, body-less rule, clean 400 framing

- **Plan (read):** `src/http/websocket.zig` `upgrade()` (89-171) and
  `reject()` (446-450); `src/http/response.zig` `fromRequest`/
  `sendHeaders` (157-192, 257-293); `src/loop/loop.zig` `onRequest`
  (182-223); notes.md sections "Test pitfalls" and "Measured behavior".
- **Do:** reorder `upgrade()` (F4); add the body-less check after the
  key validation (F3); `reject()` sets
  `res.headers.connection = .close` (F2). Unit tests build a
  hand-constructed `Request` + `Response` against a fixed writer buffer
  (helper; never call `req.deinit()` — see notes). Update the
  integration test to the realistic request (F10).
- **Verify:** `zig build test` and `zig build` green; demo2 probe:
  rejected upgrade → 400 carrying `Connection: close` and the socket
  closes without waiting for the idle window; body-bearing GET → 400;
  `POST /ws` without Upgrade header → routed (404 in demo2).
- **Stop-when:** verify green; commit "ws-fixes: handshake validation
  and rejection framing (plan T2)" with S2 crossed, progress, handover.

### T3. S3 close-handshake strictness — exactly-once Close, code range, transport error

- **Plan (read):** `src/http/websocket.zig` `next()` close branch
  (191-216), ping branch (186-189), `failProtocol` (364-370),
  `next()` doc (173-180).
- **Do:** add `close_surfaced` (F7); replace the close-payload check
  (F8); catch pong/close-echo write failures → `error.ReadFailed`
  (F9); update the `next()` doc. Tests as listed.
- **Verify:** `zig build test` green, including the new
  second-Close → ProtocolError test (the existing "close frame ...
  echoes it back" test must still pass — the first Close is unaffected).
- **Stop-when:** verify green; commit "ws-fixes: close-handshake
  strictness (plan T3)" with S3 crossed, progress, handover.

### T4. S4 max payload — bounded allocation, live 1009

- **Plan (read):** `src/http/websocket.zig` `readFrame` (318-360),
  `appendFrag`, `CloseCode` (29-38); notes.md "Stdlib" (readAlloc
  allocates first).
- **Do:** add `max_payload` (private, default 16 MiB) +
  `max_payload_default`; enforce in `readFrame` after the length is
  known (before the mask/payload read) and cumulatively in `appendFrag`;
  both via `failProtocol(.message_too_big, "")`. Tests with a tiny
  cap (set the private field in same-file tests). Update the
  architecture.md size line.
- **Verify:** `zig build test` green (new 1009 tests assert close
  bytes 0x03 0xf1); `zig build` green.
- **Stop-when:** verify green; commit "ws-fixes: max payload cap with
  close 1009 (plan T4)" with S4 crossed, progress, handover.

### T5. S5 subprotocols — echo one selected subprotocol

- **Plan (read):** `src/http/websocket.zig` `upgrade()` header-building
  tail (140-156); `src/http/response.zig` `ExtraHeader` (100-103) and
  `sendHeaders` extra loop (287-291); notes.md "RFC" (subprotocol
  MUSTs).
- **Do:** `selectSubprotocol` helper; `upgrade()` grows `res.headers.
  extra` to a 2-entry array when the request carried
  `sec_websocket_protocol`. Unit + integration tests. Docs updates
  (architecture.md, usage.md).
- **Verify:** `zig build test` and `zig build` green; demo2 probe:
  handshake with `Sec-WebSocket-Protocol: chat, superchat` → 101
  carries `Sec-WebSocket-Protocol: chat`.
- **Stop-when:** verify green; commit "ws-fixes: subprotocol
  negotiation (plan T5)" with S5 crossed, progress, handover.

### T6. S6 wrap-up — full re-verify, docs pass, close the plan

- **Plan (read):** notes.md "Measured behavior" (the probe list).
- **Do:** run the complete probe against a fresh demo2 (handshake/
  echo/ping/close plus every new behavior); sweep usage.md and
  architecture.md for stale claims (error list, "no size limit",
  "no subprotocol"); cross S6; final progress entry; handover marks
  the task complete.
- **Verify:** `zig build test`, `zig build`, full probe green; all plan
  boxes checked.
- **Stop-when:** verify green; final commit "ws-fixes: full re-verify,
  docs pass, close plan (plan T6)".

## Opening prompt (copy into a new session)

> Continue the ws-fixes plan. Read `plans/ws-fixes/handover.md` and
> start at the first unchecked item of the next task in
> `plans/ws-fixes/plan.md`. Baseline: `zig build test` && `zig build`.

## Open risks

- **Default cap of 16 MiB is a judgment call.** A client sending a
  legit 20 MiB message now gets 1009 where it got through before.
  Check: none automated (behavioral); sanctioned response: the field is
  private and trivially raised, or the default re-decided — record the
  decision in progress.md if changed.
- **`appendFrag` realloc under the plain (test) allocator frees the
  previous fragment buffer on growth**, so a reassembled message's
  slice dangles once the *next* reassembled message grows the buffer.
  Pre-existing lifetime rule ("valid until the next `next()` call"),
  unchanged by the fix; tests use arenas. Check: debug allocator in
  `zig build test`.
- **First-token subprotocol selection is not a full negotiation**
  (the server cannot reject a subprotocol). Check: none needed; it
  matches "accept what the client offered first" and is what the
  minimal fix requires.
- **F4 changes `upgrade()` behavior for non-GET + Upgrade-header
  requests?** No — those still 400. Only the no-Upgrade case moves to
  NotWebSocket. Check: the S2 unit test pins both sides.
- The S2 unit tests hand-construct `Request`s with comptime strings:
  `req.deinit()` must never be called on them (freeing a literal
  panics under the debug allocator). Check: any new "Invalid free"
  panic in `zig build test` points straight here.
