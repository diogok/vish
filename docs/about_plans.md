# Plans: plan, execute, verify, hand over

How this repository runs work that is too big for one session. A
multi-session task is not tracked in a person's or an agent's head; it is
tracked in a folder of markdown files under version control. Those files
are the memory of the work. A session that starts cold can pick up
exactly where the last one stopped, without re-deriving anything.

The first task to use this method sets the pattern in this repository;
after that, its folder stays as the reference for how this kind of work
is done here.

## When to use this

Use this for work likely to outlast a single session or context window:
a new subsystem, a large algorithmic or protocol effort, a feature that
touches many files and will be resumed after a gap. Small tasks — a fix,
a bounded refactor — do not need the apparatus. Do them directly:
change, verify, commit.

The threshold is not the size of the change but its memory. If the next
session would need to remember how the work is decomposed, why a decision
was made, and where exactly the work stopped, it goes in a plan folder.

## The root principle

**Context is disposable; the repository is the memory.**

A session's context is lost on compaction, at session end, and whenever
a different agent picks up the work. Nothing a later session needs may
live only in context. The goal, the verified facts, the decomposition,
the current position, the baseline state — all of it lives in
`plans/<task>/`, committed to git.

From that principle the rest follows:

- **Verify is woven in, not batched.** Every work item names the command
  that proves it, and the check runs before the next item starts. A
  mistake is caught near the work that made it.
- **The working tree is the intent signal.** Each completed stage
  commits, plan files included. A clean tree means the work stopped on
  purpose; a dirty tree means it stopped mid-stage. The open checklist
  plus the last commit mark exactly where.
- **One task per session, sized to finish in one sitting.** A task is a
  self-contained plan → do → verify → stop loop, so no session has to
  hold more than one task in its head.
- **Facts are recorded once.** Discovery is the expensive part of a
  session. It is written down in the notes with a "must not
  rediscover" framing, so the next session performs a read instead of a
  re-derivation.
- **The plan is a living document.** When understanding improves, the
  plan is re-scoped, and the re-scoping is itself recorded as a session —
  a no-code session that re-cuts the remaining work into session-sized
  cards is a normal and useful kind.

## The artifacts

One folder per task: `plans/<task>/`.

| File | Role | Updated |
|---|---|---|
| `plan.md` | the goal, verified facts, work items as checkboxes, session-sized task cards, open risks, how to resume | re-scoped as understanding grows; items crossed off as they land in git |
| `handover.md` | the resume card: current state, the next task's plan/do/verify, the baseline command, the facts that task needs | **rewritten** (never appended) at the end of every session, in the same commit as the `progress.md` entry |
| `progress.md` | append-only session log, newest entry on top: what landed, what was discovered, what is next | appended at the end of every session |
| `step_<n>_progress.md` | a sub-item checklist for one work item that outlasts a single step; every item carries a `*verify:*` line naming the command that proves it | crossed off as sub-items land; created from the task card when the task starts |
| `notes*.md` | the verified fact set: protocol behavior, API shapes, format quirks, file locations, environment recipes. One file, or one file per topic when a topic grows | appended and corrected in place as facts are discovered |
| `references.md` | external pointers: RFCs, docs, reference implementations, fetched recipes | mostly once, at research time |
| other files | artifacts produced while planning — expected outputs, captured requests/responses, reference captures — named for what they are | during research |

Two files carry the state, with different disciplines. `progress.md` is
append-only history: why things are the way they are. `handover.md` is
the current position: what to do next. Mixing the two — appending state
updates to the log, or rewriting history — breaks the resume.

## Plan

### Research first

The plan opens with research, before any code. Read the sources the task
depends on and record the verified facts in the notes, so the work items
are written against what the task actually is, not what it is assumed to
be.

Weigh sources in this order when they disagree: the reference
implementations and the real artifacts (the behavior of live servers,
captured requests and responses, the loaded module) win over
documentation; official docs win over specs read in isolation; specs win
over assumptions. A fact the research cannot settle becomes an open
item in the plan, not a guess in the code.

Research also produces the verification target before the code exists:
the reference outputs the finished work must reproduce. The exact
artifacts depend on the task — captured expected responses, golden
request/response pairs, templates — all captured in the recon session,
all used later as golden tests.

### Work items

The plan's body is work items as checkboxes, in order of dependency:
recon, scaffold, the core of the feature, the verification, wrap-up.
Each item says what lands and what proves it. Items are crossed off as
they land **in git** — not when the code is written, not when it works
locally.

### Task cards

Remaining work is written as task cards, one per session. Each card is a
self-contained loop:

```
### T2. <name> — <the deliverable in one line>

- **Plan (read):** the exact files the task needs — a reference file, a
  sibling implementation, a contract. Only these.
- **Do:** what gets written, concretely.
- **Verify:** the commands that must be green, and what green means.
- **Stop-when:** the condition for ending the session (verify green,
  committed, handover rewritten).
```

Sizing rule: a card must be finishable in one sitting. If a card will
not, split it — splitting is free, a session that ends mid-card with
verify red is not. Cards that depend on a prior card say so; cards that
must not depend on a later card say so deliberately — isolating one card
on purpose, so a failure in a later task can never be shaped like a
failure in it, is a feature, not an accident.

A card also pre-writes the failure handling for its verify: the
bisection order when it is red, and the escape hatch — the sanctioned
path for a known failure class, so the session follows the plan instead
of improvising. Where a card's verify compares against a captured
reference, name the sanctioned response explicitly: if the mismatch is
shaped like a difference in the capture itself, re-capture the reference;
do not suspect the implementation.

### Open risks

The plan ends with the risks that are known and accepted: the expected
wrinkles, the budget limits, the things deliberately left out of scope.
A risk is a prediction with a check attached — which pin or command will
catch it, and what the sanctioned response is.

## Execute

### Session start

A resuming session does four things, in order:

1. `git status`. A clean tree means the last session committed a
   completed task; a dirty tree means it stopped mid-task — open the
   checklist the resume card names first.
2. Read `handover.md`. It is the resume card: state, the last commit it
   describes, the next task's plan/do/verify, the baseline command, the
   facts that task needs.
3. Run the baseline command. If it is red, that is this session's first
   task: fix, commit, then continue.
4. Start at the first unchecked item of the next task. Read only the
   files its Plan line names. The notes hold the full fact set — open
   the section a card points at, not the whole file.

The plan should contain the exact opening prompt for this ritual, so
"continue the work" costs one copy-paste.

### Working the card

Work only the task the card names. Do not reach for the next task's
items, do not fix adjacent things (record them instead — see
"Out of scope" below).

A task that spans several commits keeps a checklist file,
`step_<n>_progress.md`, created from its card when the task starts. Its
sub-items are checkboxes, each with a `*verify:*` line naming the command
that proves it. The resuming session of a multi-commit task starts at
the first unchecked sub-item; `progress.md` names which checklist is
open.

### The verification loop

Verification happens at three granularities:

- **Per sub-item** — the `*verify:*` line. The item is crossed off only
  when its command is green.
- **Per task** — the card's Verify. The task is done only when its
  verify is green **and committed**.
- **Per stage close** — the parity check that matches the project's
  checks: in this repo, `zig build test` plus the default `zig build`
  (which keeps the demos compiling), because the library's test step
  alone does not cover the entry points.

The baseline command from the handover is run before new work in every
session. A green baseline is the precondition that a later red is
caused by this session's change and not by inherited rot.

## Verify: when it is red

A red verify is handled by the card, not by guessing. Three instruments:

- **Bisection order.** The card lists the stages of the pipeline in the
  order to check, cheapest suspect first — for a request-handling change,
  typically (1) the parsed request against the captured input, (2) the
  routing decision against the expected match, (3) the response bytes
  against the golden output. Each stage has a named oracle (the captured
  request, the expected route, the golden response).
- **Escape hatches.** A known failure class gets a pre-approved
  response. The response changes the *target*, not the *code*, unless
  the bisection says otherwise (a mismatch shaped like a capture
  difference: re-capture the reference, do not touch the
  implementation).
- **Out-of-scope list.** Failures that are pre-existing, in another
  subsystem, or a separate known issue are recorded — in the progress
  entry and in the handover — with the evidence that they are not this
  task's fault (identical at the baseline). The next session must not
  chase them.

What a red verify teaches is written down. The progress entry records
the bug the check surfaced — what was compared against what, why it was
subtle, and the test that now guards it. That entry is worth more than
the fix; it is the "must not rediscover" section.

## Hand over

### Session end

Every session ends with the same ritual, in one commit:

1. Rewrite `handover.md` for the next session. Never append to it.
2. Append the `progress.md` entry: what landed, what was discovered
   (must not rediscover), what is next.
3. Commit the work plus both files, plus any step checklist.

The commit message names the task ("<task>: <stage> (plan T<n>)"), so
the git log reads as the project history of the work.

### What the card carries

- **State + provenance.** What is true now, and the name of the last
  commit the card describes. A card whose commit is older than
  `git log -1` is stale by definition — no judgment, just comparison.
- **Next.** The next task's plan/do/verify, copied or tightened from the
  card in `plan.md` — including which checklist to create or resume.
- **Baseline commands.** What "healthy" is, per granularity.
- **Facts this task needs.** The subset of the notes the next task
  will use, lifted up so the session does not have to go looking.
- **Open risks** relevant to the next task, and the **out-of-scope
  list**.

### Why the two-file discipline

`progress.md` answers "why is it this way" — append-only, so the
reasons for decisions survive. `handover.md` answers "what now" —
rewritten, so it is never stale within itself. The stale-detection rule
(the commit name) plus the clean-tree rule (stages commit) mean that at
any moment the repository alone answers: where is the work, is it
healthy, and what happens next.

## Completing the task

The last card's Stop-when is the finish line: the parity check green,
the plan's items all crossed off, a final `progress.md` entry, and one
more commit. After that the folder is a record, not a working state.
Leave it: it is the reference for how this kind of work is done in this
repository, and the next similar task copies its shape.

## Applying this to another project

The invariants — keep all of them:

1. The plan folder is under version control in the same repository as
   the code it plans.
2. Every work item names the command that proves it.
3. One task per session; a task ends with verify green, committed, and
   the handover rewritten — in one commit.
4. The handover is rewritten, the log is append-only, and the handover
   names its commit.
5. Discovered facts go in the notes with a "must not rediscover"
   framing, as soon as discovered.
6. Research precedes code; reference outputs are captured during
   research.

The adjustable parts:

- **Threshold.** How much work justifies the apparatus. Keep it high
  enough that small tasks never pay the overhead.
- **Baselines and parity.** The session-start baseline and the
  stage-close parity check should be the cheapest commands that catch
  real regressions, and the parity check should match what the project
  runs.
- **Granularity of notes.** One `notes.md` until a topic grows, then one
  file per topic.
- **Checklist numbering.** `step_<n>_progress.md` tracks by work-item
  number; a task that continues an earlier item reuses its checklist
  when it closes that stage.
- **The opening prompt.** Write it into `plan.md` — the exact message a
  new session starts with.

What the technique is not: it is not documentation for humans to read
later. It is an operating system for resuming — the files exist so that
a session can start cold, in four steps, and be productive in its first
hour. If a file would not be read by the next session, it does not
belong in the folder.
