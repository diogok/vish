# Handover — WebSocket review fixes

**State: planned, nothing executed yet.** The review found ten issues
(F1–F10 in `plan.md`); the plan is written with six session-sized task
cards T1–T6. First execution session starts at **T1**.

Last commit this card describes: `bde8dc4` (the reviewed websocket
commit) — plus the uncommitted plan folder created by the planning
session.

## Next: T1 — S1 fragment reassembly (F1)

- **Plan (read):** `plans/ws-fixes/plan.md` card T1;
  `src/http/websocket.zig` lines 217-260 and 385-396; the F1
  reproducer in `plans/ws-fixes/notes.md`.
- **Do:** reset `frag_len` in `next()`'s final-fragment branch after
  validation (keep the buffer); `appendFrag` fresh-starts on
  `frag_len == 0`; add the two/three fragment tests from the plan.
- **Verify:** `zig build test` green; the new test that produced
  "HelloWorld" pre-fix now passes.
- **Stop-when:** commit "ws-fixes: fragment reassembly state reset
  (plan T1)" with plan.md S1 crossed, progress.md entry, this file
  rewritten.

## Baseline

```sh
zig build test   # library unit + integration tests
zig build        # adds the demos (test step alone misses entry points)
```

Live check when needed: background-task `./zig-out/bin/demo2` +
`python3 /tmp/ws_probe.py` (probes may need a rebuild first).

## Facts this task needs

- F1 root cause and the exact fix shape: notes.md "F1 reproducer".
- `Allocator.realloc` here is two-arg; arena realloc keeps the old
  block (that's why the stale prefix is the previous *content*).
- The reassembled slice points into `self.frag` — the buffer must
  survive the reset; only `frag_len` goes to zero.

## Open risks / out of scope

- 16 MiB default cap (T4) is a judgment call; revisit only if a real
  workload needs more.
- The `error reading body: EndOfStream` warning from demo2's
  `POST /hello` formdata path is pre-existing (not on this branch) —
  out of scope, do not chase.
- Full subprotocol *negotiation* (server-side selection policy) is out
  of scope; T5 echoes the first offered subprotocol.
