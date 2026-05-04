# Comment Conventions

Two kinds of comments live in this codebase. They have different audiences, different content rules, and different failure modes.

| Kind                | Syntax | Audience                                | Lives                          |
|---------------------|--------|-----------------------------------------|--------------------------------|
| Module-level doc    | `//!`  | API consumer reading generated docs     | top of file                    |
| Item-level doc      | `///`  | API consumer reading generated docs     | above `pub fn` / type / const  |
| Inline              | `//`   | future maintainer reading the code      | next to or above the line      |

The split matters because doc comments rot fast when they describe a moving target ("we recently changed X to Y"), and inline comments rot fast when they restate code that already says what it does. Each kind has a different bar.

The git log is for history. Comments are for understanding the code as it is right now.

## Doc comments (`///` and `//!`)

Doc comments are the contract a caller signs against. They must read fresh to someone who has never seen this file before — no knowledge of prior versions, recent refactors, or the rest of the workspace.

### Lead with a summary sentence

The first sentence (or fragment) is the single most important line. If a reader stops after it, they should still know roughly what the item does.

```zig
// Bad — buries the lede in flavor text
/// We've reworked this to operate over std.Io rather than the old
/// std.net.Stream-based API, which was the v1 way of doing things.
pub fn listen(self: *@This()) !void

// Good — first line is what it does, today
/// Bind the listening socket and start accepting connections. Must be
/// called once before `Loop.start`.
pub fn listen(self: *@This()) !void
```

Conventions:
- **Present tense, declarative.** "Returns the…", "Writes the body…", "Holds…".
- **Third person.** Describe what the code does, not what *we* do.
- A noun phrase ("A streaming body reader…") or verb phrase ("Returns…") both work; pick whichever reads naturally.

### Describe what it is, not how it does it

A doc comment is a contract about *what* the function produces, not *how* it gets there. The how is the implementer's prerogative to change later.

```zig
// Bad — leaks the algorithm; callers will start depending on it
/// Allocates a temporary buffer, gzip-compresses the body in one shot,
/// then writes status + headers + compressed bytes to the socket.
pub fn send(self: *@This()) !void

// Good — what callers can rely on
/// Send a one-shot response: status line, headers, and `body`. When
/// `headers.content_encoding` is set, the body is compressed and
/// `Content-Length` is updated to the compressed size.
pub fn send(self: *@This()) !void
```

If callers know how the current implementation works, they'll grow to depend on it.

### Document the contract

Things callers actually need to know to use the code correctly:

- **Ownership and lifetime** — who owns returned memory, what `deinit` is paired with what `init`, what's borrowed.
- **Concurrency** — is this safe to call concurrently? from a different task?
- **Special values and edge cases** — what happens on empty input, missing header, oversized body.
- **Error semantics** — what each returned error means, when it fires.
- **Side effects** — headers written, socket state changed, arena reset.

Pulled from this codebase:

```zig
/// Look up an arbitrary request header by name (case-insensitive).
/// Returns `null` if the header is absent or if extras parsing was
/// not enabled. Pre-parsed fields (Host, Content-Type, etc.) are
/// NOT mirrored here — read them via the typed field instead.
```
> `src/http/request.zig` — names the contract and pre-empts an easy-to-make caller bug.

```zig
/// A streaming body reader that handles both Content-Length and chunked
/// Transfer-Encoding. When the request carries `Content-Encoding:
/// gzip|deflate`, `interface()` lazily wraps the inner stream in a
/// `flate.Decompress` so handlers always see plaintext.
```
> `src/http/request.zig` — describes the surface and the transparent decompress behaviour the caller relies on.

### What does NOT belong in doc comments

- **Refactor narrative.** "Ported to operate on `std.Io` rather than `std.net.Stream`" → just describe what it does now.
- **Phase / milestone tags.** "Phase 2 stub" → these are project-internal milestones; they belong in commits, not contracts.
- **Cross-version compatibility narration.** "In Zig 0.16 `std.Thread.Pool` was removed and we now…" → describe what the wrapper provides; the upstream version delta is irrelevant to a caller.
- **"Previously" / "no longer" / "moved from".** Same — that's `git log`.
- **Tag blocks that restate signatures.** Javadoc-style `@param x The x parameter`, `@return The result` are out of scope. Use prose where there's actual content; otherwise omit.
- **`@since` and version metadata.** Versions live in git tags and CHANGELOGs. Code is always "the current version" by definition.

### History-adjacent metadata that IS allowed

Two tagged forms carry useful information without rotting:

```zig
/// Deprecated: use `Response.send` instead — this entry point can't
/// pass through compression options.
pub fn write(self: *@This()) !void

// TODO(diogok): support trailers once we expose chunked-write streaming.
```

Rules:
- `Deprecated:` MUST include what to use instead and (briefly) why.
- `TODO(name):` MUST name an owner. A bare `TODO` with no owner is dead noise and gets deleted on sight.

## Inline comments (`//`)

Inline comments are looser — they're for maintainers, not API consumers — but they have a tougher bar to clear: they must be worth having at all. The default is no comment.

### Earn your keep

A useful inline comment answers: *what would I get wrong if this comment weren't here?* If the answer is "nothing, the code is plain", delete it.

Things that earn their keep:

- **Hidden invariants.** "`Connection: close` from either side terminates the keep-alive loop; do not loop on it."
- **Protocol subtleties.** "Chunk size is hex without `0x` prefix per RFC 7230 §4.1; do not use `{x}` format with width."
- **Allocator quirks.** "`free` here is a no-op under the arena; only matters when the test allocator is in play."
- **Deliberate algorithmic tradeoffs.** "Linear scan over `extras` — typical request has <8 entries, hash-map setup wouldn't pay back."
- **Surprising orderings.** "Cancel the babysitter before reading the first byte; otherwise the wakeup races the deadline."
- **Workarounds for specific upstream bugs** (cite the version when known).

### What doesn't earn its keep

```zig
// Bad — restates the obvious
// Open the listening socket
try self.listener.listen(...);

// Bad — narrates the structure
// Parse headers
try headers.read(allocator, &reader, .{});

// Bad — phase residue
// (was sendRaw in v1 — unchanged behavior)
fn send(...) void { ... }

// Bad — bare FIXME with no context
// FIXME: this is wrong sometimes
```

If the variable name says it (`listener.listen()`), the comment is duplication. If you'd write the same comment for *every* line in the file ("create the X", "load the Y"), the comments are noise. Delete and let the code speak.

### Inline is where history can anchor an invariant

The one place a small history reference is legitimate is when it anchors an invariant a maintainer would otherwise undo:

```zig
// Reverted to inline backpressure after measuring 12% throughput
// regression with a bounded queue under burst load. Don't reintroduce
// the queue without re-running the burst benchmark.
```

This is acceptable because it tells a future maintainer *why the code is the way it is and what to verify before reverting*.

## Module-level headers (`//!`)

Two to four lines that orient a fresh reader. State:

- What this module IS in one phrase ("the HTTP request parser", "TCP socket option setters", "Common Log Format middleware").
- Any non-obvious ownership or lifecycle ("borrowed connection writer; caller owns flushing").
- Where to look next if the reader needs more ("see `loop.zig`").

Skip:
- "Ported from v1."
- "This file is a wrapper around …" (just say what it is).
- Restating the file name.

```zig
// Good
//! HTTP server and connection management. `Server.accept` produces a
//! `Connection` per socket; the connection owns its arena, read/write
//! buffers, and per-request lifetime. `Loop` (in `loop/loop.zig`) drives
//! the accept/worker pair on top of `std.Io`.
```

## When in doubt

Imagine a contributor opening this file six months from now. They have no Slack history, no PR context, no memory of last quarter's refactor. Does the comment help them understand the code's current contract or invariants?

- **Yes** → keep.
- **It's narrating something only meaningful to people who were here for the change** → delete.

## See also

- [coding-conventions.md](coding-conventions.md) — Zig style for the code itself; this doc expands its `## Comments` section.
