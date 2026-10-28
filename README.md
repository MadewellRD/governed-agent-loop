# Governed Agent Loop (GAL)

A supervisory control pattern for directing headless coding agents against a real
codebase, where nothing merges without evidence bound to the exact commit that
merged, and no human has to be awake for the loop to keep its promises.

GAL is not an agent framework. It assumes you already have a capable coding agent
and a build that can tell you pass from fail. What it adds is the governance layer
around them: who dispatched this, what exactly was asked, did it actually pass,
is "passed" provably about the thing that landed, who decided, and what happens
when the laptop goes to sleep at two in the morning.

---

## The problem it solves

A headless coding agent is fast, capable, and will hand you work that looks
finished. The gap is never capability. The gap is that the evidence chain is
missing in ways that are invisible until you look:

- The agent runs its own tests and reports green. Its receipt describes a tree it
  no longer has, because it committed twice more after the run.
- The job record says the process is running. The process died four hours ago.
- Two supervisors run at once because the lock is a field in a file they both
  overwrite.
- A ratification appears in the record citing an authority that was never
  consulted.
- The scheduler quietly disables the dispatcher because a laptop was asleep at the
  wrong minute, and nobody notices for four days.

Every one of those is a real incident from the reference implementation, not a
hypothetical. They are documented with dates and commit hashes in
[`docs/FAILURE-LOG.md`](docs/FAILURE-LOG.md). The eleven rules below exist because
each of them cost something.

---

## The shape

The lineage is supervisory control: a supervisor constrains a lower-level process,
intervenes on exceptions, and enforces invariants the process cannot violate on its
own. The agent does the work. The supervisor decides whether the work is allowed to
exist.

```
  scheduler
      │  fires on a fixed cadence
      ▼
  ┌─────────────────────────────────────────────────────────┐
  │ TICK (the supervisor)                                   │
  │                                                         │
  │  1. acquire mutex ──────── lose? exit quietly           │
  │  2. harvest: is a job in flight? terminal status only    │
  │  3. review the delivered tip against the packet          │
  │  4. gate: independent run on that exact commit           │
  │  5. re-read state, then merge (the only irreversible step)│
  │  6. provision the next packet                            │
  │  7. dispatch one agent                                   │
  │  8. release mutex, write the cursor, report              │
  └─────────────────────────────────────────────────────────┘
      │                                   ▲
      │ hands over a bounded packet       │ commits as it goes
      ▼                                   │
  ┌─────────────────────┐                 │
  │ AGENT (headless)    │─────────────────┘
  │ scoped tools only   │
  └─────────────────────┘

  watchdogs observe the tick and never do its work
  decisions park in a queue; the operator disposes on their own cadence
```

Three properties make this different from a cron job that runs an agent:

**The supervisor is the only dispatcher.** Agents never poll, never discover work,
never decide what to do next. Work is handed to them in a worktree with the packet
file already in it. This is what makes the system auditable: there is exactly one
place where work begins.

**Evidence binds to a commit.** A gate receipt carries a content hash over the
tracked file list of the exact tree it validated, and self-attests the commit when
the staged tree matches HEAD. A receipt that cannot name its commit is a timestamp,
not evidence.

**Authority has one origin.** Decisions are ratified in a gated ledger. Not in a
prompt, not in a config field, not in a commit message. Anything editable outside
the audit trail cannot be the source of a ruling.

---

## The eleven rules

These are the whole method. Everything in `protocol/` is an implementation of
them.

**1. One dispatcher.** Exactly one process starts agent work and exactly one
harvests it. Agents never poll. The corollary is unavoidable: when the supervisor
stops, everything stops, so the supervisor needs a watchdog that is not itself.

**2. Green must name its commit.** Bind the receipt by content hash over the
tracked file list, excluding only the receipts directory so that committing the
receipt does not change what it binds. Have the receipt self-attest the commit when
it can.

**3. Review the delivered tip, never the agent's claim.** The agent's own receipt
will drift from what it delivered, because it keeps committing after its gate run.
In the reference implementation it drifted on three consecutive packets. Re-gate
the exact tip every time. This is not ceremony; it caught every one of them.

**4. One unit of work in flight.** Concurrency needs isolation you probably do not
have. A single cursor cannot track two jobs, so the second is invisible to the next
harvest. A shared test database makes two simultaneous greens untrustworthy, and an
untrustworthy green is the failure the whole apparatus exists to prevent.

**5. Terminal status only.** Liveness is the job record reaching a terminal state.
Never a pid, because pids are reused and the poller holds no handle. Never a
self-published heartbeat, because it is silent in exactly the failure it should
detect. Absent a terminal status past the deadline, the job is *indeterminate*,
which is neither running nor finished and must not be treated as either.

**6. A lock must be a lock.** An advisory flag in a file the other writer rewrites
is not a mutex. Use compare-and-swap against non-existence. Separately, re-read the
shared state as the last operation before any mutating step and abort if ownership
or a hold changed. The irreversible step gets this check unconditionally. Write the
holder into the shared state the moment the lock is taken, not when it is released:
a record that only exists after release cannot show who holds the lock now.

**7. Rulings originate in the ledger.** A decision is ratified when it lands in the
gated decision record. A prompt may restate a ruling; it may never originate one.
The reference implementation recorded a ratification citing a prompt that had been
edited before the decision was made, and had to issue a correction.

**8. Acceptance criteria must be covered by granted capability.** If a required
criterion needs a tool the dispatch does not grant, you have written a packet
defect that will surface as an environment limitation and get absorbed by a
fallback clause. Check the criteria against the grant before dispatching.

**9. Nothing waits on a human inside a run.** Anything needing a decision parks as
a queued item and the run continues with the next parkable thing. Humans dispose on
their own cadence, in a window built for it.

**10. Match the model to the blast radius.** The supervisor reviews and merges, so
give it judgment. The watchdog compares a timestamp, so give it the floor. Run
count is the wrong axis; consequence is the right one.

**11. Instruction files are attended-only write surface.** The protocol file, the
agent ground-rules file and the harness settings govern every later unattended
run. An unattended run never edits them. Amendments are made by the supervisor in
a session with the operator present, on a branch that merges under the gate. The
reference substrate's permission classifier refuses such edits unattended; that
refusal is the guard working, and the rule exists so that nothing is built on the
assumption it will not. The rule is about content, not paths: a disposition or a
"next run does X" paragraph is an instruction wherever it lands, so the decision
queue is append-only intake and closure lives only in the ledger.

---

## What is in the box

| Path | What it is |
|---|---|
| `SWAP-POINTS.md` | Everything that changes per stack, OS and execution substrate. Read this second. |
| `docs/METHOD.md` | Why each piece exists, in full. The reasoning the rest assumes. |
| `docs/FAILURE-LOG.md` | The incidents that produced each rule, with dates and hashes. |
| `docs/DECISIONS.md` | The portable decisions, generalized from the reference implementation. |
| `protocol/pm-tick.md` | The supervisor protocol, step by step. The protocol of record. |
| `protocol/packet-TEMPLATE.md` | The unit of work: scope, criteria, invariants, tests, branch. |
| `protocol/loop-state.schema.json` | The cursor. One mutable record of where the loop is. |
| `protocol/gate-receipt.schema.json` | The evidence contract, v2 self-attesting. |
| `prompts/` | The six stored prompts: gatekeeper, supervisor, decision session, both watchdogs, status. |
| `scripts/gate.template.ps1` | The gate skeleton. The binding rule is the load-bearing part. |
| `scripts/setup-loop.template.ps1` | Arming: tool paths, credentials, execution profile, policy. |
| `scripts/status-snapshot.template.ps1` | The status plane: a deterministic, read-only rendering of the tree into one JSON document, with provenance shas on every section. |
| `scripts/status-validate.template.ps1` | Gates publication of a snapshot: schema plus semantic checks; the status task refuses to publish on failure. |
| `protocol/plan.schema.json` | The plan of record: every unit of work, its lane and phase, its status, its evidence, its conflicts. Countable, under the gate. |
| `protocol/status-snapshot.schema.json` | The snapshot contract the page renders and the validator enforces. |
| `status/build-status.template.html` | The build-status page: fixed renderer over the snapshot, investor first. The status task republishes it with a new snapshot beside it; it never writes HTML. |
| `prompts/status.prompt.md` | The status task: republishes the build-status page from a fresh validated snapshot. |
| `prompts/gatekeeper.prompt.md` | The hourly cheap check: reads the cursor and the lock, skips only on the supervisor's own determination that nothing is dispatchable, never on a state name, fails open. |
| `skill/governed-agent-loop-setup/SKILL.md` | The setup skill: asks the ten swap-point questions, parameterizes this kit into a target repo, runs setup-loop, creates the six scheduled tasks, verifies. |

---

## Quickstart

1. Read `SWAP-POINTS.md` and fill in the ten project-specific values.
2. Copy `protocol/` and `scripts/` into your target repo under `ops/pm/`.
3. Run the setup script to arm the execution substrate: resolve the agent binary,
   bind the credential, set the execution profile, verify the gate can run
   unattended.
4. Create the six scheduled tasks from `prompts/`, in the order the setup skill
   gives. No trigger of the supervisor is bound to the computer (GAL-D33). The
   supervisor runs hourly until the gatekeeper has demonstrated its skip path,
   runs with automatic approval and carries no device binding, all three read
   back from the scheduler (GAL-D35); only then does it move to its backstop.
5. Write your first packet from the template and let the supervisor dispatch it.

Step 3 is where every first-time setup actually stalls, and `SWAP-POINTS.md` is
written around that fact.

If you would rather not do this by hand, the companion skill
`governed-agent-loop-setup` runs the whole sequence against a named project,
asks only the questions that genuinely differ, and verifies the result.

---

## What this cost to learn

The reference implementation is a Rust workspace of roughly thirty crates with a
fourteen-step validation gate, running on Windows, dispatching Claude Code through
a governed MCP execution runtime. Over its first week of operation it produced nine
numbered loop defects and four numbered implementation defects, and went dark twice
for seventeen hours and for three days and twenty hours respectively.

None of that was agent incompetence. Every one was a governance gap: an unbound
receipt, an advisory lock, a pid check, a heartbeat that could not report its own
absence, a prompt that outranked the ledger. The agents did good work throughout.
The supervisor is what needed hardening, and this repo is what came out of
hardening it.

---

## Vocabulary

**Packet**: one bounded unit of work: scope, acceptance criteria, invariants in
force, required tests, branch convention. Small enough to review in one pass and to
gate once.

**Tick**: one run of the supervisor.

**Cursor**: the single mutable record of loop position: state, current packet, job
id, attempt, last tick, holds, lock.

**Gate**: the validation suite that decides whether work may merge. Hard by
definition; there is no override path.

**Receipt**: the gate's output, bound by content hash to the exact tree it
validated.

**Binding**: the hash that ties a receipt to a tree, computed over the tracked file
list with the receipts directory excluded.

**Hold**: an operator-set flag that interposes between the gate and the merge. A
held tick still harvests, reviews and gates, then stops.

**Park**: to record something needing a decision and continue, so no run ever
blocks on a human.

---

Licensed under Apache-2.0. See `LICENSE`.
