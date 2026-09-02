# AGENTS.md

Working knowledge for agents (and humans) developing vish. For the
architecture, start with [docs/architecture.md](docs/architecture.md); for
code style, [docs/coding-conventions.md](docs/coding-conventions.md) is
authoritative, and for comment style
[docs/comment-conventions.md](docs/comment-conventions.md).

## What this is

An HTTP server library for Zig (VISH: **V**table **I**O **S**erver for
**H**TTP), with zero dependencies. Built on the `std.Io` rework: a
concurrent accept + worker loop with backpressure and idle reaping, a
vtable `Handler` interface, declarative routing (`StructRouter`,
`PrefixRouter`, `CombinedRouter`, `StaticRouter`), chunked and SSE
streaming, and transparent `gzip`/`deflate` in both directions.

## Environment

- Zig 0.16.0 is the toolchain the repo builds with. Use the `std.Io` API
  ("Juicy Main": `pub fn main(init: std.process.Init)`), not the old
  stdlib.
- No external dependencies (`build.zig.zon`); nothing to fetch or pin.

## Build and test

Everything is a `zig build` step, run from the repository root.

```sh
zig build test   # unit tests (the library's modules, via src/root.zig)
zig build run    # demo (src/demo.zig): minimal server
zig build run2   # demo2 (src/demo2.zig): routing + static assets + logging
zig build ws-echo  # WebSocket client probe (src/ws_echo.zig): connects to
                   # demo2's /ws (or a ws:// URL argument), echoes "hello"
zig build        # default install step; compiles the demos and ws-echo too
```

Tests live in the modules: each `src/` file carries its own `test` block,
and `src/utils/root.zig` registers the utils submodule tests. Note that
`zig build test` builds only the library — a compile break in a demo is
caught by the default `zig build` (or the run steps), not by the test
step.

### Benchmark

`benchmark/` is a baseline against unmodified nginx (wrk + nginx scripts),
not a performance suite — it exists to notice regressions, not to measure
absolute throughput. For performance runs, use `SmpAllocator` and disable
logging; see `benchmark/README.md`.

## How to read the code

Entry point for a question:

- "How do I use the library?" → the README usage example, then
  `docs/usage.md`, then `src/demo.zig` (minimal) and `src/demo2.zig`
  (routing + assets + logging).
- "What is the contract a handler implements?" → `src/loop/handler.zig`
  (`Handler`, `wrap(T)`, `error.Skipped`, `Outcome`).
- "How does a request flow?" → `docs/architecture.md`, then
  `src/loop/loop.zig` (accept/worker dispatch) → `src/http/server.zig`
  (`Connection`, per-request parsing) → the router in
  `src/utils/router.zig`.
- "How is a response written?" → `src/http/response.zig` (status, headers,
  chunked, SSE, compression).
- "How does graceful shutdown work?" → `src/loop/signal.zig`
  (SIGINT/SIGTERM/SIGHUP → `std.Io.Event`).
- "Where do the utilities live?" → `src/utils/` (router, formdata,
  multipart, mime, logging, timestamp, uriencode).

File-as-struct convention (`docs/coding-conventions.md`): when a file
defines a single primary type, the file *is* that type — bare fields at
the top, methods below, imported directly. Files that export several
types or only free functions use named `pub const` declarations instead.

## Conventions (summary)

Full rules live in `docs/`; the parts that bite most often:

- Naming: `PascalCase` types, `camelCase` functions, `snake_case` fields
  and enum tags. Exception: `Method` and `Status` tags mirror the HTTP
  wire format (`GET`, `Not_Found`) — the status reason phrase is derived
  from the tag at send time. No cryptic abbreviations; loop variables name
  what they iterate.
- Comments: `//!` and `///` are contracts for generated docs and must read
  fresh with no prior context; inline `//` is for the maintainer. Never
  restate what the code already says; the git log is for history.
- Handler contract: a handler returns an `Outcome` (`.handled` or
  `.skipped`), never an error — failures are converted into proper error
  responses (400/401/413/500) at the wrap/router boundary, so no request
  error can take the server down. Return `error.Skipped` to not match.
- `std.Io` and allocator discipline: per-connection arena, reset between
  requests; `init`/`deinit` pairs for anything that owns resources.

## Adding things

- **A public symbol**: it belongs in `src/root.zig`, which is the only
  public surface of the library.
- **A utility module**: a file in `src/utils/`, registered (with its test
  block kept compiling) in `src/utils/root.zig`.
- **Static assets**: a directory plus `addStaticAssets` in `build.zig`,
  paired with `StaticRouter`. Debug reads from disk per request; release
  `@embedFile`s.
- **A build step**: follow `build.zig` — one module for the library,
  executables that import it by name.

## Working on complex tasks

For the most complex tasks (a new subsystem, a large algorithmic effort,
anything likely to outlast one context window), run the work as a plan in
the `plans/` folder rather than relying on in-context memory. The full
method — plan, execute, verify, hand over — is in
[docs/about_plans.md](docs/about_plans.md);
this section is the in-repo summary. One folder per task: `plans/<task>/`
with

- `plan.md` — the goal, verified facts, work items as checkboxes, and open
  risks. Update it when the scope changes; cross items off as they land in
  git.
- `handover.md` — the resume card: current state, the next task's
  plan/do/verify, the baseline command. Rewritten (never appended) at the
  end of every session.
- `progress.md` — a session log, newest entry on top: what landed, what
  the next step is, and anything the next session must not rediscover.
  Updated at the end of every session.
- notes — `notes.md`, or one file per topic when a topic grows; the record
  of facts discovered along the way (protocol behavior, API shapes,
  edge cases, file locations). This is what makes the work resumable
  across sessions and context compactions without re-running the discovery.
- `references.md` — URLs and external pointers, when any were used.
- stage checklists — a `step_<n>_progress.md` for each work item of
  `plan.md` that outlasts a single step: its sub-items as checkboxes,
  crossed off as they land. A resuming session picks up mid-stage from the
  first unchecked item; `progress.md` names the open checklist.

Artifacts produced while planning (reference captures, expected outputs)
live in the same folder, named for what they are. A task already in flight
means continuing its plan, not starting a new one: read `handover.md` and
the notes first, and trust the recorded facts over re-deriving them.

Commit as the work lands: each completed stage — its checklist,
`handover.md`, and `progress.md` included — is its own commit. The working
tree is the intent signal. A clean tree means the session stopped on
purpose; uncommitted changes mean it stopped mid-stage, and the open
checklist plus the last commit mark exactly where.

Plans usually open with a research session before any code: read the
sources the task depends on and record the verified facts in the notes, so
the later work items are written against what the task actually is, not
what it is assumed to be. For HTTP work, that is the RFCs for the
semantics in question, observed behavior of real servers (curl, nginx)
when the spec is open to interpretation, and the `std.Io` documentation
for the concurrency and IO APIs. Weigh them in that order; real server
behavior wins. Verification is woven between the work items, not batched
at the end: each item or small group gets its check (compiles, a test
passes) before the next item starts, so a mistake is caught near the work
that made it.

## Checks

There is no CI in this repository. Run the local equivalent before calling
work done: `zig build test`, and the default `zig build` so the demos
still compile. When touching request handling or a router, the real check
is starting a demo and probing it with curl — both bind `127.0.0.1:8080`:

```sh
./zig-out/bin/demo2 &   # demo2: routing + assets; demo: minimal hello world
curl -si http://127.0.0.1:8080/                 # route + static assets
curl -si http://127.0.0.1:8080/hello            # status line, headers, body
curl -si -X POST -d 'a=1' http://127.0.0.1:8080/hello
curl -si http://127.0.0.1:8080/err              # error -> status mapping
kill %1
```

Check the status line and headers, not just the body — response bugs
often live there (content length, encoding, reason phrase).
