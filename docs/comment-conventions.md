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

Doc comments are the contract a caller signs against. They must read fresh to someone who has never seen this file before — no knowledge of prior versions, recent refactors, or the rest of the codebase.

### Skip what the name and conventions already say

A doc comment is not mandatory on every `pub` item. When the signature plus project conventions already carry the whole contract, a doc restating them is noise:

```zig
// Bad — the name and the init/deinit convention say all of this
/// Frees the resources allocated by `init`.
pub fn deinit(self: *@This()) void

// Fine — no doc at all
pub fn deinit(self: *@This()) void
```

Write the doc when there is contract *beyond* the conventions — ownership that deviates, edge cases, error meanings. And keep it concise: the shortest true statement of the contract. Two lines that a caller can hold in their head beat a paragraph.

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

### If it states a contract, it must be `///`

The syntax decides where a comment surfaces. A `//` comment stating ownership, lifetime, or usage rules on a `pub` item is a doc comment wearing the wrong syntax — generated docs will never show it.

```zig
// Bad — caller contract invisible to generated docs
// Reads the whole body into an arena-owned slice. Do not free.
pub fn readAll(self: *@This(), max_bytes: usize) ![]const u8

// Good
/// Read the whole body into an arena-owned slice, valid until the handler
/// returns; do not free. Fails with `error.StreamTooLong` past `max_bytes`.
pub fn readAll(self: *@This(), max_bytes: usize) ![]const u8
```

The reverse holds too: implementer-facing rationale (why the linear scan over `extras`, why the decompress window is lazily allocated) is maintainer material — keep it in a `//` near the code it protects, not in the `///` contract.

### This library describes itself

This library is its own repo and reads as a standalone package. Its doc comments must not assume anything outside this repo exists.

**Don't:**
- Reference downstream apps by role ("the router used by the blog server").
- Mention which consumers use this code.
- Position the package against its dependencies ("a thin layer over `std.Io.net`"). That's `build.zig.zon`'s job.

**Do:**
- Describe this package's own surface.
- Reference its own internal types by short name.
- Show usage examples that exercise its own API.

The test: read the repo on its own with no other context — does the doc still make sense?

### Copying a file copies its comments — rewrite them

Most wrong comments arrive by copy: a new module seeded from a sibling keeps the donor's prose while the code is adapted — a `deflate` branch still claiming gzip, a router grown from `PrefixRouter` still describing prefix-stripping, a header still naming the donor module.

When you seed a file from a sibling, rewriting the header and every comment is part of the copy — not a cleanup pass for later. A header that names the wrong module or encoding is a bug of the same severity as wrong code: it is the first line a fresh reader trusts.

### State the invariant, not the provenance

"Copied from X so the values match" ties correctness to something outside the package — a sibling project, an unnamed "production" — that a standalone reader cannot see and that may itself change. Name the constraint the values must satisfy instead.

```zig
// Bad — anchors correctness to an external golden source
// Buffer sizes and timeouts copied from the nginx defaults so behavior matches.

// Good — the constraint itself, checkable in place
// Wire names derive from the field name at comptime (`_` → `-`, capitalize
// each segment); parser and serializer share the derivation — change one
// side and header lookups silently miss.
```

The same rule kills define-by-diff headers: "Mirrors the gzip path but reads deflate" documents this file as a delta of a sibling that will drift. Say what this file does; mention the sibling only for genuinely shared helpers.

### What does NOT belong in doc comments

- **Refactor narrative.** "Ported to operate on `std.Io` rather than `std.net.Stream`" → just describe what it does now.
- **Phase / milestone tags.** "Phase 2 stub" → these are project-internal milestones; they belong in commits, not contracts. (Stage labels inside an algorithm — `// Phase 1: parse the request line` — are fine; the ban is on project milestones.)
- **Roadmap narrative.** "For now", "today", "a follow-up", "arrives in a later phase" — future-tense history. It rots into a lie the moment the follow-up lands. State current behavior as plain fact, with no timestamp.
- **Speculative consumers.** "So a future WebSocket upgrade path can reuse it" documents a caller that doesn't exist. Write that doc when the caller does.
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

Two to four lines that orient a fresh reader — clean and minimal, never a table of contents. Every file with a public surface gets one, and no file gets a member listing.

Mechanics: `//!` lines at the very top of the file. `///!` is not a syntax, and a detached `///` paragraph above the first declaration attaches to that declaration (or to nothing) — neither produces a module doc.

State:

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

### Document the module, not its members

The header describes the whole. It never enumerates the module's functions, fields, or methods — a sentence that documents one member (its type, its contract, its ownership) belongs in a `///` on that item, where generated docs attach it and one source of truth lives. The header carries only what's true across members: what the module is, and cross-cutting invariants ("all fields are arena-allocated", "this is a view, not an owner").

Three smells that mean the header has absorbed item-level content:

- It runs past ~4 lines, or starts a per-field / per-method bullet list.
- It embeds an algorithm or schema walkthrough (route-matching pseudocode, a header-by-header field list) that belongs on the function or fields implementing it.
- A fact in it also appears on the item (or should). State it once, on the item, and let the header point — duplicated facts rot twice.

The fix is always the same: push the sentence down onto the member it describes and let the header shrink back to orientation.

## Comments rot — maintain them like code

A comment that states a checkable fact must stay true, and it fails review when it isn't:

- **Name only symbols that exist.** After a rename, grep the comments too — a doc still citing `sendRaw` after it became `send` points readers at nothing.
- **Cite symbols, never line numbers.** "Matches the parser in `request.zig` lines 80–120" rots on the next edit; name the function.
- **Claims must match the code.** "No allocation on this path" above a `try allocator.alloc` is worse than no comment.
- **No commented-out code.** `//try res.flush();` is dead code in disguise; version control has it. Delete.
- **No filler.** A doc line that carries no fact ("//! Handle the requests.") is deleted on sight, like a bare TODO.

## When in doubt

Imagine a contributor opening this file six months from now. They have no Slack history, no PR context, no memory of last quarter's refactor. Does the comment help them understand the code's current contract or invariants?

- **Yes** → keep.
- **It's narrating something only meaningful to people who were here for the change** → delete.

## See also

- [coding-conventions.md](coding-conventions.md) — Zig style for the code itself; this doc expands its `## Comments` section.
