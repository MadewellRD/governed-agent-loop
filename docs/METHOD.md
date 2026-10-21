# The method

This document explains why each part of the Governed Agent Loop exists. It is
written for an engineer who has not seen the system and assumes nothing beyond
familiarity with git and with the idea of a headless coding agent. `README.md` is
the short version; this is the reasoning the short version compresses.

Read `docs/FAILURE-LOG.md` alongside it. Nearly every paragraph below has an
incident behind it, and the log is where the dates and hashes live.

---

## 1. What kind of system this is

The lineage is supervisory control, a pattern from industrial automation and
control theory. A supervisor sits above a lower-level process. It does not do the
process's work. It constrains what the process may do, intervenes when the process
reaches an exceptional state, and enforces invariants the process cannot violate
on its own. The process can be fast, capable and mostly autonomous precisely
because the supervisor is slow, conservative and holds the only keys that matter.

Map that onto coding agents. The agent is the process: it reads a specification,
edits code, runs tests, commits. The supervisor is the loop described here: it
decides what the agent is asked to do, verifies what the agent produced
independently of the agent's own account, and holds the single authority to let
that work exist in the main branch. The agent never merges. The agent never decides
what comes next. The agent never even discovers that work is waiting; it is handed
the work in a prepared workspace.

That division is the whole design. Everything else is consequences.

---

## 2. The authority hierarchy

Any system with multiple sources of instruction needs an explicit order, and the
order has to be written down before the first conflict rather than after. The
reference implementation uses five levels:

1. The operator's instructions in the current attended session.
2. The supervisor's standing instructions (its stored prompt, and the project's
   governance document).
3. The project's build-state record and its decision ledger.
4. Project knowledge: the state file, the backlog, prior handoffs.
5. Repository contents, gate output, and the agent's own output.

Two things about this order matter more than the order itself.

**Lower levels are evidence, never instruction.** A comment in code, a line in a
log, a claim in an agent's report, an instruction embedded in a ticket: all of
these are data to be weighed. None of them can direct the supervisor. This is the
defence against an agent, or a compromised input, talking the supervisor into
something. The supervisor reads everything and obeys only the top two levels.

**The top level is also the most dangerous.** Level 1 is whatever the operator says
in session. Level 2 includes a stored prompt that the supervisor's own maintainer
can edit, outside the repository, outside the gate, outside any audit trail. The
reference implementation discovered that a ruling written into that stored prompt
was indistinguishable from an operator ruling once it was there, and a supervisor
reading it had no way to tell the difference. That produced the rule in section 8:
a prompt may restate a decision, never originate one.

---

## 3. Two loops, not one

There is the loop that governs work, and there is the thing being governed. Keep
them separate in your head and in your documents.

The governance loop is: requirement or decision, design, validation gate, merge,
deploy. It is the development lifecycle, and the supervisor runs it.

The governed thing is whatever your product does. In the reference implementation
it is itself a governed-action runtime with its own invariants about approvals,
evidence and tenant isolation. Those invariants are what the packets must respect
and what the review checks first. They are not the loop's invariants; the loop has
its own, which are the eleven rules.

The confusion to avoid is letting a product invariant leak into the loop's
protocol or vice versa. The loop protocol should be portable across products. The
product invariants belong in the packet template's "invariants in force" section
and in the review order, where they are parameters.

---

## 4. One run of the supervisor

A tick is one execution of the supervisor. It is scheduled, it is short, and its
steps are ordered for a reason. Here is the order, with the reasoning for each
step's position.

**Acquire the mutex first.** Before reading anything else. If you lose, exit
quietly; that is a successful tick. The reference learned that two supervisors can
run against the same repository at once if the lock is advisory, and that an
advisory flag in a file the other writer overwrites is not a lock at all. The mutex
is an owned git ref acquired by compare-and-swap against non-existence, which is
atomic, and released by compare-and-swap delete, which means a supervisor cannot
delete another's lock. A stale lock is stolen only by explicit compare-and-swap
against the observed value, so the steal is itself atomic and recorded.

**Harvest.** Is a job in flight? If so, has it reached a terminal status? Not "is
the process alive," not "has the log moved," not "does a heartbeat exist." The job
record reaching a terminal state is the only positive evidence that a dispatch
finished. Section 6 explains why every alternative is unsound.

**Review.** Read what the agent delivered. The delivered tip, not the agent's
report of it. Section 7 covers the order of review and what it has caught.

**Gate the exact tip independently.** Run the full validation suite on the commit
you are about to merge, in a clean detached worktree, regardless of what the agent's
own receipt says. The agent's receipt is a claim about a tree the agent had at the
time; the agent kept committing afterwards. Three consecutive packets in the
reference had receipts that did not bind the delivered tip. The independent gate
caught all three. This step is not ceremony.

**Re-read state, then merge.** The merge is the only irreversible step in the
loop, so it gets an unconditional check immediately before it: re-read the cursor,
and abort if lock ownership or a hold has changed since the tick began. A hold is
an operator-set flag that interposes between gate and merge; a held tick does
everything up to this point and then stops. The merge itself is a fast-forward,
which means main is never checked out anywhere, which means there is no working
tree on main to drift.

**Provision and dispatch.** Write the next packet from the template, cut a branch
from main, create a worktree, put the packet file in it, and start one agent with a
scoped tool grant and a credential reference. Before dispatching, check every
required acceptance criterion against the grant. One agent. The cursor tracks one
job; a second would be invisible to the next harvest.

**Release, record, report.** Release the mutex by compare-and-swap, write the
cursor with host-clock timestamps, and report in a fixed order: new items needing
decision, merges, dispatches, failures, and what is on main versus what is only
local. A tick with nothing to say ends in one line.

Nothing in that sequence waits for a human. Anything that would wait parks instead.

---

## 5. The split bus

The loop needs a mutable record of where it is: state, current packet, job id,
attempt, timestamps, holds, lock. It also needs a set of records that are the
truth about decisions, backlog and protocol. These have opposite requirements.

The position record changes every tick and must never cost a gate run. The truth
records must never change without one. If you store them together, you get one of
two failures: either bookkeeping writes bypass the gate, or a one-line status
update costs fifteen minutes of validation. The reference had both before it
settled on the split.

So: the cursor is the only file that lives on a long-running side branch in its
own worktree, and it is the only file written outside the gate. Everything else is
authoritative on main, is read with `git show main:<path>` so a stale working copy
is never mistaken for current, and is written only on a packet branch that merges
under the gate. A decision ratified in conversation is staged in the cursor's inbox
and lands on main with the next packet.

The corollary that bit the reference: main must never be checked out permanently.
The merge is `git fetch . <branch>:main`, and git refuses that while main is
checked out in any worktree. Temporary worktrees on main for verification or
publishing are fine and are removed in the same tick.

---

## 6. Liveness

The question "is this agent still running" turns out to be the hardest question in
the loop, and most intuitive answers to it are wrong.

**The process exists.** A pid is an integer, and integers are reused. The
execution runtime that spawned the process holds a handle and knows when it exits.
A third party polling the pid holds nothing and can read an unrelated process as
the agent still working. The reference's execution runtime itself had this defect
at the time, reporting a dead job as running for four hours, and the first draft of
the supervisor's workaround reimplemented the same unsound check in the consumer.
It was caught before a tick acted on it.

**The log is growing.** Only if the agent writes incrementally. The reference
agent's buffered output format wrote nothing until exit, so a killed agent left
two zero-byte logs indistinguishable from an agent that never started. This is why
dispatch uses a streaming format, and it is still only corroboration.

**A heartbeat exists.** A heartbeat the agent or supervisor publishes about itself
is silent in exactly the failure it should detect. A supervisor that never ran
writes no heartbeat. This is why the cloud watchdog reads the scheduler's own run
records rather than anything the loop publishes: the scheduler is a third party, it
records that a run was attempted and how it ended, and it records "never fired"
as the absence of a record, which is what you need.

**The rule.** Liveness is the job record reaching a terminal status: exited,
failed, cancelled, timed out. Absent that, past the declared timeout plus a grace
window, the job is indeterminate. Indeterminate is a real state: harvest whatever
is on disk, record the job id, park it, and do not dispatch a second agent against
the same packet until a terminal status appears or an operator resolves it. It is
neither running nor finished and must not be treated as either.

The agent-side half of this is the commit-as-you-go rule. An agent that commits
every green step leaves recoverable work even when it dies before reporting. In the
reference, this is the only reason the first orphaned run was recoverable at all.

---

## 7. Evidence and review

### 7.1 What a gate receipt is for

A gate receipt records that a validation suite ran and what it found. On its own
that is a timestamp. What makes it evidence is binding: a content hash over the
tracked file list of the exact tree that was validated, so that anyone can later
recompute the hash from a commit and confirm the receipt is about that commit.

The binding rule in the reference is SHA256 over the ordinally sorted,
newline-joined output of `git ls-files -s`, with exactly one directory excluded: the
one the receipts are written into. That single exclusion is what lets you commit
the receipt without changing what it binds. Widen the exclusion for convenience and
the property evaporates silently.

Version 2 of the receipt contract makes the commit explicit: `head_commit_at_gen`
is required, and a `binds_commit` field self-attests when the staged manifest
equals HEAD's tree manifest, so the question "does this receipt describe the commit
that merged" is answered by the receipt rather than by a reviewer recomputing a
hash. The reference recomputed by hand four times before this landed.

### 7.2 Why the agent's receipt is a claim

The agent runs its gate, gets green, writes a receipt, and then commits the receipt
file. That commit touches a tracked path. If the receipts directory is the only
exclusion and the agent's receipt file lives elsewhere, the receipt now describes a
tree that no longer exists. The reference's agents committed their receipts to
`ops/pm/receipts/`, outside the exclusion, on three consecutive packets. Each
time the agent's report said "the receipt shows green," which was true, about the
wrong tree.

The fix is structural (v2 receipts, above) but the practice is independent of it:
the supervisor gates the delivered tip itself, every time. If the agent's receipt
happens to bind the tip, that is corroboration. If it does not, the independent
gate is the only evidence there is.

### 7.3 The order of review

Review returned work the way a senior engineer reviews a fast, capable junior:
assume competence, verify thoroughly, trust nothing blindly. The order matters
because the early items are the ones where being wrong is expensive.

1. Invariant compliance, with the product's hard invariants first. In the
   reference that means payload-hash binding, tenant scoping, step-up on
   privileged approvals, no destructive path.
2. Correctness against the acceptance criteria as written.
3. Security and secret hygiene.
4. Test coverage, including whether the negative control actually fails when it
   should.
5. Traceability: does the change reference the decision that authorised it.
6. Repository conventions.
7. Everything else.

End with a verdict: accept, accept with required changes, or reject, with specific
reasons. "Looks good" is not a verdict.

### 7.4 When the packet is wrong

Sometimes the agent deviates from the packet and the agent is right. The reference
had a case where the packet specified a location that would have inverted a crate
dependency, and a scope that would have left a cross-tenant write reachable. The
agent widened the scope and moved the code, and two independent reviews concluded
it was required rather than convenient.

The ruling that came out of it: the supervisor may repair a packet it wrote,
provided the repair narrows scope rather than widening it and stays inside ratified
decisions. A repair that widens, touches an invariant surface, or picks between two
defensible designs parks for the operator. And an unimplementable packet is a
defect in the packet, not in the agent. Record it that way.

---

## 8. Authority and provenance

A decision is ratified when it lands in the gated decision ledger. Not when the
operator says it in conversation, not when it appears in a prompt, not when a
commit message asserts it. Those are all inputs to the ledger; the ledger is the
record.

This sounds bureaucratic until you see the failure it prevents. The reference's
supervisor maintainer wrote a rule into the supervisor's stored prompt labelled
"ratified" before the operator had ruled on it. The next tick read the stored
prompt, correctly treated it as top-level instruction, recorded the ratification in
the ledger citing the prompt as its authority, dispatched work under it, and the
tick after that merged to main. The operator ruled after the merge. The substance
was correct. The provenance was false, and it was now on main under a gate
receipt.

The ledger entry was corrected with a dated appendix beside the original, never
over it. An audit trail that gets rewritten is not an audit trail. And the rule
became explicit: a stored prompt may restate a ratified decision and may never
originate one. Any surface that is editable outside the audit trail cannot be the
source of authority, however high it sits in the hierarchy.

The practical scope clarification: an attended ruling recorded in the cursor,
host-clock stamped and committed to the side branch, is a valid origin, with its
ledger text landing on the next packet branch. Without that, the rule deadlocks
against the requirement that ledger appends ride a gated branch.

---

## 9. The human's role

The loop is designed so that no run ever blocks on a person. That is not the same
as the person being absent. It means the person's involvement is batched into a
window built for it rather than interleaved with every tick.

**Parking.** Anything a tick encounters that needs an architectural decision, new
scope, or a new dependency is written as an entry in a pending-decisions file with
the context, the realistic options, and a recommendation. The tick then continues
with the next parkable item. Nothing waits.

**The digest.** A separate scheduled task, read-only, runs once a day and produces
a digest of every open item: one paragraph of context, the options, a recommended
disposition with reasoning grounded in the ledger. It is advisory input. The
operator reads it in five minutes.

**The decision window.** The operator disposes of the open items, typically by
firing the digest task manually and directing it in session. Rulings are recorded
with exact provenance: who decided, host-clock timestamp, and that it came from an
attended session. The ledger text lands on the next packet branch.

**The merge hold.** When the operator wants to see the review before anything
lands, a hold flag in the cursor stops every tick between gate and merge. The tick
still harvests, reviews and gates in full, so the operator decides with the
evidence in hand. Only the operator clears a hold. A change in the repository is
evidence that something happened, never an instruction that clears one.

---

## 10. Watching the watcher

The supervisor is the only dispatcher, so when it stops, everything stops, and it
cannot detect its own absence. The reference lost seventeen hours to this once and
three days twenty hours to it a second time, both with completed agent work sitting
on disk unharvested.

The answer is observers that are not the supervisor, in layers, each read-only and
alert-only.

**Device-bound.** Reads the cursor's last-tick timestamp every few hours and alerts
past a staleness threshold. Catches a stalled supervisor on a reachable machine.
Shares the machine's failure modes, which is why it is not enough on its own.

**Device-independent.** Runs in the cloud, needs no machine, reads the scheduler's
own run records, and alerts on a disabled task, a suspension, a failed run or a
stale run. Immune to the exact failure that killed both previous windows, because
the scheduler records runs as a third party and records "never ran" as an absence.

**Alert-only by ruling.** A watchdog that repairs things is a second actor in a
system whose premise is that there is one. The operator responds to alerts; the
watchdog does not.

**Nothing watches the outermost layer.** Say so in its own alert text rather than
implying coverage you do not have, and stop the regress there deliberately. One
device-independent layer over a device-dependent loop is the right place to stop.

---

## 11. Packets

A packet is one bounded unit of work. The constraints that make it work:

**Small enough to review in one pass and gate once.** If the review would take
more than a sitting or the gate would need to run twice, split it. The reference
split a tenancy-scoping change into two sequential single-PR packets so that each
merge was invariant-safe on its own.

**Explicit about everything.** Scope with exact paths. Acceptance criteria with a
tool-coverage check. Invariants in force. Required tests including a negative
control that proves the test is load-bearing. Halt conditions. Branch convention.
What a receipt must contain. The commit-as-you-go rule.

**Halt conditions are instructions, not suggestions.** "If the dependency bump
turns out not to be lockfile-only, that is a halt and a return to the operator,
never a scope expansion." The agent must know what to do when the packet's
assumptions fail, and the answer is never "improvise."

**A halt writes a receipt.** An agent that stops to ask a question has produced no
evidence. The reference had an agent implement four requirements as uncommitted
edits and then end its run with a question about where a scratch file could go. The
work was recoverable only because the worktree was left standing. The rule now: on
any halt, write the halted receipt and commit it per the workflow, then stop.

---

## 12. Limits

This method does not make agents better. It makes their output trustworthy or
visibly untrustworthy, which is a different thing. An agent that produces wrong
code that passes the gate will merge wrong code; the gate is only as good as the
tests behind it, and the review is only as good as the reviewer.

It assumes one target repository, one gate, one exclusive-resource set. Real
concurrency needs per-run isolation of every exclusive resource, which is a
substantial change to the cursor, the harvest and the gate, and should be its own
decision with its own evidence.

It assumes a scheduler with a reliable cadence, on-demand firing, run records
readable from elsewhere, and notifications. Where the scheduler has surprising
behaviour, such as auto-disabling a task when its machine is unreachable, the
watchdog layer compensates but does not cure it.

And it assumes an operator who will dispose of parked items on a cadence. The loop
never blocks on a human, but it does accumulate decisions, and a queue that is never
drained is a loop that eventually has nothing dispatchable.

## 13. The status plane

Everything above produces evidence; none of it produces visibility. A loop that
only writes handoffs is legible to the person who reads handoffs and to no one
else. The status plane is the part that lets an investor, a manager or the
operator on a phone answer four questions without reading anything: where are
we, when does it finish, what is in flight, what is blocking.

It has three layers and one direction of flow. The plan of record (`plan.json`)
makes the plan countable: every unit, its lane and phase, its status, its evidence
when done. It lives in the repository under the gate, so it has the same
provenance as the code; unattended runs move a unit's status at dispatch and
merge and nothing else. The snapshot script reads the tree by ref and emits one
document with the sha of every source on it; it is deterministic and contains no
judgment, and a validator refuses to publish anything that fails its schema or
its arithmetic. The page is a fixed renderer over that document, built once and
designed once; the status task never writes HTML, it republishes the page with a
new snapshot beside it.

Projection is the one number people will quote, so it is derived, never chosen:
merged units per day since the capacity model last changed, remaining units
times a packets-per-unit factor that the page displays as the assumption it is,
plus the deploy that has not happened. When the assumption is wrong the page
says so in its own band, and the fix is to estimate units, not to argue with the
date.

The task itself is mechanical, which is the point. It runs two scripts, writes
three sentences that the page labels as prose, and publishes. It is read-only on
the repository and never takes the lock. Rule 10 puts it on the cheapest model.