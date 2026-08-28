# References

- RFC 6455 — The WebSocket Protocol:
  <https://www.rfc-editor.org/rfc/rfc6455> (§4.1 handshake and
  subprotocol, §5.1 masking, §5.5.1 fragmentation, §7.4 status codes,
  §1.3 handshake vector, Appendix A frame vectors).
- RFC 7230 — HTTP/1.1 Message Syntax: `Connection` header token-list
  semantics, message framing by close when `Content-Length` is absent.
- `lib/std/Io/Reader.zig` (toolchain at `/home/diogo/workspace/zig`) —
  `take`/`peek`/`readAlloc` semantics used by the frame codec.
- `plans/websocket/` — the original task's plan/notes/handover;
  progress.md there carries the stdlib gotchas for this custom build.
