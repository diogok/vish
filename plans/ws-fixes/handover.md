# Handover — WebSocket review fixes

**State: T2 (S2, F2/F3/F4/F10) landed.** Handshake validation reordered
(`NotWebSocket` before the method check), body-bearing handshakes
rejected, and every `reject()` 400 now carries `Connection: close` so
the connection drops immediately instead of outliving the idle window.
Next session starts at **T3**.

Last commit this card describes: the T2 commit
"ws-fixes: handshake validation and rejection framing (plan T2)".

## Next: T3 — S3 close-handshake strictness (F7/F8/F9)

- **Plan (read):** `plans/ws-fixes/plan.md` card T3 and the F7/F8/F9
  design lines (F8's formula was corrected there this session — the
  `len >= 2` guard is load-bearing); `src/http/websocket.zig`:
  `next()` doc (181-188), ping branch (194-197), close branch
  (199-224), `close()` (298-302), `failProtocol` (377-383),
  `sendClosePayload` (388-396), `writeFrame` (416-451), `CloseCode`
  (29-38).
- **Do:**
  - F7: add a private `close_surfaced: bool`. In the close branch, if
    it is already set → `return self.failProtocol(.protocol_error, "")`;
    set it when surfacing `.close`. Use `close_surfaced`, NOT the
    existing `closed` latch (see facts).
  - F8: replace the payload check (209-213) with the corrected formula
    from plan.md.
  - F9: the ping branch (195) and the close-echo (221) currently
    `try self.writeFrame(...)`, propagating the raw writer error;
    change both to `catch |err| { _ = err; return error.ReadFailed; }`
    (`writeFrame` already latches `failed` — do not double-latch).
  - `next()` doc (181-188): add the transport-failure line (a failed
    auto-pong/close-echo write returns `error.ReadFailed`).
  - Tests: second Close frame → `ProtocolError` (writer must show no
    second Close frame — the echo went out with the first);
    2-byte `0x0000` close → `ProtocolError` + close 1002 on the wire;
    0-byte close payload → still accepted (regression guard for the
    `len >= 2` guard); ping with a failing writer → `ReadFailed` and a
    subsequent `next()` returns `ReadFailed` without reading. Model the
    failing-writer test on the existing failed-latch test at the end of
    the file (`std.Io.Writer.failing`).
- **Verify:** `zig build test` green (111 + new tests), including the
  existing close integration test (first Close + echo is unaffected).
- **Stop-when:** commit "ws-fixes: close-handshake strictness (plan
  T3)" with plan.md S3 crossed, progress.md entry, this file rewritten.

## Baseline

```sh
zig build test   # 111 tests after T2
zig build        # adds the demos
```

Live check: background-task `./zig-out/bin/demo2` (rebuild first with
`zig build`), then `python3 /tmp/ws_t2_probe.py` (S2 behaviors + valid
handshake/echo; regenerate from notes.md "Measured behavior (post-S2)"
if gone).

## Facts this task needs

- **F7 subtlety:** server-initiated `close()` (298-302) sets `closed`
  but never surfaces `.close`. The peer's answering Close must still
  surface exactly once — so the "already surfaced" latch has to be a
  new `close_surfaced` flag set at the surface site (223), not the
  `closed` field. When a second peer Close is rejected via
  `failProtocol`, `closed` is already true, so no extra Close frame
  goes out — correct (RFC 6455 §5.5.1: nothing may follow the
  answered Close).
- **F8:** the close branch defaults `code = 0` for len 0 and len 2
  payloads; the `len >= 2` guard in the corrected formula is what keeps
  the legal empty payload through while killing `0x0000`.
- **F9:** `writeFrame` (437-450) latches `failed` on every write
  failure before returning the raw error; the `catch` arms only need
  to convert the error, `failed` is already set. `next()`'s first line
  (190) then short-circuits to `ReadFailed` on the next call.
- Error values compare fine inside a test that `try`'s `next()`
  directly (one merged error set). The cross-error-set `anyerror`
  trap (notes.md "Zig 0.16 error-value pitfalls") only bites in
  helpers that return `anyerror` — flatten to an enum if one is
  needed.
- The `frame(masked, opcode, fin, payload)` test helper allocates
  exact wire sizes and returns heap bytes — `defer
  testing.allocator.free(...)` every result.

## Open risks / out of scope

- 16 MiB default cap (T4) is a judgment call; revisit only if a real
  workload needs more.
- The `error reading body: EndOfStream` warning from demo2's
  `POST /hello` formdata path is pre-existing — out of scope.
- Subprotocol *selection policy* beyond "first offered token" is out
  of scope (T5).
