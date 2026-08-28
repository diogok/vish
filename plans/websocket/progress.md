# Progress — WebSocket support

## Session 2 — 2026-08-28 (all stages landed)

- **S1 handshake**: request/response header fields (`upgrade`,
  `sec_websocket_key`, `sec_websocket_version`, `sec_websocket_protocol`,
  `Connection.upgrade` both sides), `Status.Switching_Protocols = 101`,
  `WebSocket.upgrade()` validation + 101/400 paths, `Response.upgraded`
  flag, loop closes upgraded connections after the handler returns.
- **S2 frame codec + API**: `next() !Message` with fragmentation
  reassembly, masking/unmasking, 7/16/64-bit lengths, full protocol
  enforcement (unmasked client frame, RSV, reserved opcodes, control
  frame FIN/len, close payload shape → 1002; UTF-8 → 1007), auto-pong,
  close echo; `sendText/sendBinary/ping/pong/close/flush/deinit` with a
  sticky `failed` latch.
- **S3 tests**: ~22 unit tests (RFC A.1 vectors, every protocol-error
  path, extended lengths, failed latch) + 2 integration tests with a
  live `Loop` over real TCP and a hand-assembled masked client:
  handshake→101 + accept value, text/binary echo (16-bit length path),
  ping→pong, close handshake + clean TCP close, 400 on an invalid
  upgrade. **104/104 tests pass**; default `zig build` green.
- **S4 demo + docs**: `demo2` `/ws` echo route (WS handler prepended to
  the CombinedRouter), README feature bullet, `docs/usage.md` WebSocket
  section, `docs/architecture.md` module line + lifecycle section.
  Manual probes against running demo2: curl 101 with the RFC §1.3 key,
  python3 stdlib masked-frame round-trip (all probes passed).

Gotchas discovered this session (do not rediscover):

- The custom stdlib's `std.mem.readInt`/`writeInt` take a
  `*const [N]u8` array pointer, **not a slice** — read big-endian values
  from slices by hand or copy into an array.
- `std.unicode.utf8ValidateSlice` returns `bool`, not an error union.
- `std.Io.Writer.Allocating.init(allocator)` is infallible (no `try`).
- The test `DebugAllocator` validates frees against the **slice length**:
  a helper that allocates 14+N bytes but returns a shorter sub-slice
  panics with "Invalid free" on free. Allocate exact wire sizes.
- `std.Io.net` stream readers/writers are wrapper types
  (`Io.net.Stream.Reader`); the `std.Io.Reader` API is reached via
  `.interface`.
- `@enumFromInt` on a raw opcode byte panics on reserved opcodes —
  validate the integer first.
- `zig build test`'s test binary lives in `.zig-cache/o/<hash>/test`;
  the hash changes between builds — a stale copy shows old failures.
- A demo started with `&` inside a `bash` tool call dies with the shell;
  use `background: true` for probes.

Task complete: plan.md fully checked. No open items.

## Session 1 — 2026-08-28

- Explored the codebase (server/connection, request, response, loop,
  handler, demo2). Settled the design in notes.md: upgrade + session
  lives inside the handler (SSE pattern), `res.upgraded` closes the
  connection after the session, per-frame flush, arena-owned payloads.
- Research: verified stdlib APIs in the custom Zig 0.16 build
  (`std.Io.Reader.take/readSliceAll`, `std.base64.standard` Codecs
  shape, `std.crypto.hash.Sha1.hash` one-shot, two-arg `realloc`);
  reproduced the RFC 6455 §1.3 handshake vector with python3; public
  echo servers unusable (301/404) — RFC is the authority.
- Wrote plan.md + notes.md + handover.md.

Next: S1 handshake (see handover.md).
