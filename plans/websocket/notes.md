# WebSocket — verified facts

## Toolchain: Zig 0.16.0, custom stdlib at ~/workspace/zig (built from source)

### std.Io.Reader (lib/std/Io/Reader.zig)

- `take(r, n) Error![]u8` — reads exactly n bytes; pointer into the
  internal buffer.
- `peek(r, n)`, `toss(r, n)`, `fill(r, n) Error!void`.
- `readSliceAll(r, buffer) Error!void` — fills the whole buffer.
- `readAlloc(r, allocator, len) ReadAllocError![]u8`.
- `allocRemaining`, `stream`, `bufferedLen()`.
- `Error = error{ ReadFailed, EndOfStream }` (line 112).

### std.Io.Writer (lib/std/Io/Writer.zig)

- `write`, `writeAll`, `print`, `writeVec`, `flush` (all `Error!`).

### std.base64 (lib/std/base64.zig) — `Codecs` shape, not the classic API

- `std.base64.standard` is `Codecs{ .Encoder, .Decoder, ... }`.
- `Encoder.encode(dest: []u8, source: []const u8) []const u8` — dest must
  be `calcSize(source.len)` = `@divTrunc(source_len + 2, 3) * 4` (with pad).
- `Decoder.decode(dest: []u8, source: []const u8) Error!void` — dest sized
  via `Decoder.calcSizeForSlice(source) Error!usize`.
- `Error = error{ InvalidCharacter, InvalidPadding, NoSpaceLeft }`.

### std.crypto.Sha1 (lib/std/crypto/Sha1.zig) — one-shot hash

- `pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void`
  with `digest_length = 20`, `Options = struct {}`.

### std.mem.Allocator

- `realloc(self, old_mem, new_n) Error!@TypeOf(old_mem)` — two-arg form.

## RFC 6455 — vectors and rules used

- §1.3 handshake vector (verified with python3 hashlib, 2026-08-28):
  - key `dGhlIHNhbXBsZSBub25jZQ==` (decodes to 16 bytes)
  - magic `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`
  - accept `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`
- §4.1/4.2: request needs `Upgrade: websocket`, `Connection` with the
  `Upgrade` token, `Sec-WebSocket-Key` (base64 of exactly 16 bytes),
  `Sec-WebSocket-Version: 13`. Version != 13 → 400 that MUST include
  `Sec-WebSocket-Version: 13`. Unusable handshake → 400.
- §5.2: frame = FIN|RSV1-3|opcode(4) | MASK|len7(7); len 126 → 16-bit
  BE, 127 → 64-bit BE; 4-byte masking key when MASK set.
- §5.1: client MUST mask; server MUST NOT mask; "A server MUST close the
  connection upon receiving a frame that does not have the MASK bit set".
- §5.5: opcodes 0 continuation, 1 text, 2 binary, 8 close, 9 ping,
  10 pong; 3-7/11-15 reserved → protocol error. Control frames: FIN must
  be set, payload ≤ 125, may interrupt a fragmented message. RSV bits:
  with no negotiated extensions, a set RSV → fail the connection.
- §7.1.5: Close payload: 0 bytes, or ≥ 2 (u16 BE code + UTF-8 reason);
  exactly 1 byte → protocol error. 1005/1006 MUST NOT appear on the wire.
  On receiving Close: send Close back, then close the TCP connection.
  Server-initiated: closing TCP immediately after sending Close is
  permitted (no wait for peer Close).
- §5.5.2.1: Ping MUST be answered with Pong, payload mirrored.
- §6.1: Text message that is not valid UTF-8 → fail the connection
  (customary code 1007).
- §7.4 close codes: 1000 normal, 1001 going away, 1002 protocol error,
  1003 unsupported data, 1007 invalid data, 1008 policy, 1009 too big,
  1011 internal error.
- Appendix A.1 vectors: `81 05 48 65 6c 6c 6f` = unfragmented text
  "Hello"; `01 04 48 65` + `80 01 6f` = fragmented text "Hello";
  `82 0b ...` binary "Hello World". Masked text "Hello":
  `81 85 37 fa 21 3d 7f 9f 4d 51 58`.

## Observed behavior

- Public echo servers (echo.websocket.org, ws.postman-echo.com) were
  301/404 on 2026-08-28 — unusable as observation targets. The RFC text
  is the authority; the §1.3 vector was reproduced independently.

## Codebase integration facts

- `Response.send()` does NOT flush; the loop flushes `req.writer` after
  `handle` returns. SSE relies on an explicit `res.flush()`. → WebSocket
  sends must flush per frame (echo latency), and `upgrade()` must flush
  after the 101 (the client waits for it before speaking WS).
- `Response.failed` sticky-latch pattern: infallible public methods +
  `markFailed` (debug log) + every method no-ops while latched.
- `Response.fromRequest` copies `Connection` by tag-value cast; the two
  `Connection` enums are documented lockstep — new tags must land in both
  at the same index.
- `Response.sendHeaders` emits any non-empty `[]const u8` field as a
  header (`capitalize` of the field name) and then `headers.extra`
  verbatim → `Sec-WebSocket-Accept` goes in `extra`; a new `upgrade`
  field yields `Upgrade: websocket`.
- `Request` `Connection.parse` is whole-value, case-insensitive,
  `_`→`-`. `Connection: Upgrade` alone parses to a new `.upgrade` tag.
- `Connection.next()` resets the arena per request; a WS session is one
  request (the upgrade request), so the arena is stable for the session.
- Loop `onRequest`: `if (!res.sent_status) res.send();` then flush,
  `res.failed` → close, then `Connection`-header close/keep decision
  (`req.headers.connection orelse .close`). A new `res.upgraded` check
  returns `.close` before the keep-alive decision.
- demo2 routing: `CombinedRouter.init(&.{ struct_handler, static_handler })`
  wrapped in `logging.Common` — a WS echo handler prepended to the
  CombinedRouter gets first look and falls through with `error.Skipped`
  for non-upgrade requests.

## Session 2 — stdlib facts discovered while making the tests pass

- `std.mem.readInt(T, buf, endian)` / `writeInt` take
  `*const [N]u8` / `*[N]u8` (a pointer to a fixed-size array), **not a
  slice**. Reading a big-endian value out of a dynamic slice has to be
  done by hand: `(@as(u16, b[0]) << 8) | @as(u16, b[1])`.
- `std.unicode.utf8ValidateSlice(input) bool` — returns a bool, no
  error union.
- `std.Io.Writer.Allocating.init(allocator)` is infallible.
- `std.Io.Reader.fixed(buffer)` is read-only (the `ending*` vtable fns
  all no-op / return EndOfStream); `take`/`peek` never write into the
  source buffer.
- `stream.reader(io, &buf)` returns an `Io.net.Stream.Reader` wrapper;
  the `std.Io.Reader` API (take/peek/readAlloc/…) is reached through
  its `.interface` field.
- The test `DebugAllocator` checks canaries against the **slice length**
  at free time: allocate exactly what you free (a helper returning a
  sub-slice of a larger allocation panics "Invalid free").
- `@enumFromInt` on a raw opcode byte panics at runtime for reserved
  opcodes (3-7, 11-15) — validate the integer before converting.
- `zig build test` runs its binary from `.zig-cache/o/<hash>/test`; the
  hash changes per build, so a stale copy reports stale failures.
