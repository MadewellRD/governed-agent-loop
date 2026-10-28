# Decision ledger

This is the portable decision ledger for a Governed Agent Loop. It does two jobs.
It is the format a new project should adopt for its own ledger, and it carries the
loop's foundational decisions, generalized from the reference implementation so
they can be adopted as-is or amended with a dated entry.

The entries below are numbered `GAL-D01` onward. A project adopting this method
keeps its own ledger with its own numbering and references these by id. The
reference implementation's own ids (D17 through D98) are noted so the evidence in
`FAILURE-LOG.md` can be traced.

---

## Format

Every entry carries the same fields, in this order. None is optional.

```
### <ID>: <one-line title>
Date:        <YYYY-MM-DD>
Decider:     <who ruled, by name or role; never "the system">
Origin:      <where the question came from: an incident id, a review, a request>
Question:    <the thing that had to be decided, as a question>
Options:     <the realistic alternatives, each in a line>
Disposition: <which option, stated so there is no ambiguity>
Reasoning:   <why, grounded in evidence or prior decisions>
```

Rules for the file itself:

- **Append only.** A decision is never edited after it lands. If it was wrong, or
  its provenance was wrong, a correction entry is appended beside it with its own
  id and a reference back. See `GAL-D07-C1` for the shape.
- **Merges under the gate.** The ledger lives on main and changes only on a gated
  branch. A ruling given in conversation is staged in the cursor's inbox and lands
  with the next packet. Until it lands it is not ratified, whatever anyone says.
- **The decider is a person.** A ledger entry whose decider is a prompt, a tool, a
  prior document or "the supervisor" is a defect. The supervisor drafts; the
  operator decides.
- **Status markers must be true.** A heading that says DECISION NEEDED after the
  decision has been made is the same class of defect as a receipt that does not
  name its commit. Fix it in the next carry.

---

## Foundational decisions

### GAL-D01: The supervisor is the only dispatcher
Date:        2026-10-15
Decider:     Operator (reference: D17)
Origin:      The request that started the loop: "I want to be out of the loop as
             much as possible and only do decisions at a specified interval. But
             nothing waits on me hard."
Question:    Who starts agent work, who collects it, and does the agent ever decide
             what to do next?
Options:     (a) Agents poll a queue and self-dispatch.
             (b) A scheduled supervisor is the only process that dispatches and
                 harvests; agents never poll.
             (c) The operator dispatches by hand and the supervisor only reviews.
Disposition: (b). The supervisor dispatches, reviews, gates and merges on a fixed
             cadence. Agents are handed a packet in a prepared worktree and never
             discover work on their own. The operator disposes of parked decisions
             in a separate window.
Reasoning:   (a) makes every agent a dispatcher and destroys the audit property
             that work begins in exactly one place. (c) puts the human back in the
             hard path. (b) is the supervisory-control topology and its cost, that
             the loop stops when the supervisor stops, is addressed by GAL-D08.

### GAL-D02: No ungated fast-forward of main, including for bookkeeping
Date:        2026-10-15
Decider:     Operator (reference: D19, from LOOP-1)
Origin:      Whether the loop's own bookkeeping commits could reach main without
             a gate run, since they touch no production code.
Question:    May a commit that touches only loop bookkeeping reach main without
             a gate run?
Options:     (a) Exempt bookkeeping-only commits from the gate.
             (b) No exception; every commit reaching main carries or rides a
                 receipt.
Disposition: (b).
Reasoning:   The binding rule hashes the tracked file list, and the loop's files
             are tracked, so a bookkeeping commit changes the bound tree. An
             exemption would mean main carries commits no receipt describes. The
             cost, one gate run per bookkeeping landing, is avoided in practice by
             batching bookkeeping onto packet branches (GAL-D03).

### GAL-D03: Ratified decisions reach main on a gated branch
Date:        2026-10-15
Decider:     Operator (reference: D21)
Origin:      Two decisions were committed to the side branch and never reached
             main, because nothing carried them.
Question:    How does ledger text get from a ruling to main?
Options:     (a) The supervisor commits ledger appends directly to main.
             (b) Ledger appends ride the next packet branch and merge under that
                 branch's gate.
             (c) Ledger appends get their own gated branch each time.
Disposition: (b), with (c) permitted when no packet is pending and the text must
             land now.
Reasoning:   (a) is GAL-D02's exception by another name. (c) costs a full gate run
             per decision. (b) costs nothing extra. Constraint: an append is never
             added to a branch whose gate receipt already binds its tree, since
             that invalidates the receipt; it waits for the next branch.

### GAL-D04: A gate receipt names its commit
Date:        2026-10-16
Decider:     Operator (reference: D22)
Origin:      Three consecutive agent receipts bound a tree other than the delivered
             tip (FAILURE-LOG, "Receipt binding"). Every one was caught by manual
             recomputation.
Question:    What must a receipt carry for "green" to be evidence about a specific
             commit?
Options:     (a) Keep recomputing by hand when it matters.
             (b) Make the generating commit a required receipt field, and have the
                 receipt self-attest whether it binds that commit.
Disposition: (b). `head_commit_at_gen` is required. `binds_commit` is true when the
             staged manifest equals HEAD's tree manifest with the receipts
             directory excluded on both sides, and null otherwise. Receipt schema
             moves to v2. The binding rule itself is immutable.
Reasoning:   A receipt that cannot name its commit is a timestamp. Manual
             recomputation worked four times and depends on someone remembering to
             do it. The pattern that diligence caught three times becomes
             structurally impossible.

### GAL-D05: The loop bus is split, and main is never checked out
Date:        2026-10-15
Decider:     Operator (reference: D23, from LOOP-4)
Origin:      Two copies of the decision record diverged across two branches, and a
             tick carried the wrong one.
Question:    Where does each loop file live, and which copy is true?
Options:     (a) Everything on a long-running side branch, merged periodically.
             (b) Everything on main, with the cursor written under the gate.
             (c) Only the cursor on the side branch; everything else
                 main-authoritative, read with `git show main:<path>`, written only
                 on a gated packet branch.
Disposition: (c). Additionally: main is never checked out permanently, because the
             merge path is a fast-forward fetch that git refuses while main is
             checked out anywhere. Temporary worktrees on main are removed in the
             same tick.
Reasoning:   (a) forks the record. (b) makes every cursor write cost a gate. (c)
             gives the one file that changes every tick a home outside the gate
             and gives every record a single authoritative copy.

### GAL-D06: The supervisor may repair a packet it wrote, narrowly
Date:        2026-10-15, amended 2026-10-16
Decider:     Operator (reference: D24 and its amendment)
Origin:      A packet contradicted itself and the agent refused to pick a side.
             Later, a packet specified a design that would have inverted a crate
             dependency and left a cross-tenant write reachable; the agent
             deviated and was right.
Question:    When a packet is wrong, who fixes it and how far may the fix go?
Options:     (a) Park every packet defect for the operator.
             (b) The supervisor may amend, within limits.
Disposition: (b). The supervisor may amend a packet it wrote provided the
             amendment stays inside already-ratified decisions, narrows scope
             rather than widening it, and is recorded as a dated amendment on the
             packet. A correction that widens scope, touches an invariant surface,
             or picks between two defensible designs parks. Amendment: an
             unimplementable packet is a defect in the packet, not in the agent,
             and is recorded as such.
Reasoning:   (a) stalls the loop on clerical errors. The limits keep (b) from
             becoming a way to ratify scope by editing the spec after the fact.

### GAL-D07: Rulings originate in the ledger, never in a prompt
Date:        2026-10-20
Decider:     Operator (reference: D25, from LOOP-9)
Origin:      A rule written into the supervisor's stored prompt and labelled
             "ratified" before the operator had ruled was correctly treated as
             top-level instruction by the next tick, recorded in the ledger citing
             the prompt, and merged to main before the ruling actually happened.
Question:    What may a tick cite as authority for a ratification?
Options:     (a) A tick may never cite the stored prompt as the sole authority. A
                 ruling must land in the ledger under the gate first. The prompt
                 may restate a ratified decision; it may never originate one.
             (b) Strip all decisions from the stored prompt; it carries safety
                 restatement only.
             (c) Accept the exposure.
Disposition: (a). Scope clarification: an attended-session ruling recorded in the
             cursor, host-clock stamped and committed, is a valid origin, with its
             ledger text landing on the next packet branch per GAL-D03. Without
             this the rule deadlocks against GAL-D03.
Reasoning:   The stored prompt is the highest-authority surface in the loop and the
             only one editable outside the repo, the gate and any audit trail.
             Nothing can distinguish an operator ruling from a maintainer edit once
             text is in it. (b) is defensible but discards the prompt's value as a
             safety restatement. (c) is not defensible after the incident.

### GAL-D07-C1: Correction to the provenance of the first LOOP-8 entry
Date:        2026-10-20
Decider:     Operator, in an attended session
Origin:      GAL-D07's originating incident.
Question:    How is a ledger entry with false provenance corrected?
Options:     (a) Edit the original entry.
             (b) Append a dated correction beside it, never over it.
Disposition: (b). The original entry stands as written. This correction records
             that its cited authority, a stored-prompt revision, was authored by
             the supervisor's maintainer before the operator ruled; that the
             substance was correct and nothing is reverted; and that the operator's
             genuine ruling came later and is recorded here.
Reasoning:   An audit trail that gets rewritten is not one. The shape of this
             entry is the template for every future correction.

### GAL-D08: Two watchdog layers, read-only, alert-only
Date:        2026-10-20
Decider:     Operator (reference: D26, from LOOP-7)
Origin:      Two outages, seventeen hours and three days twenty hours, in which the
             supervisor's scheduled task was auto-disabled and nothing noticed.
Question:    What observes the supervisor, given that it cannot observe itself?
Options:     (a) A device-bound task reading the cursor's last-tick timestamp.
             (b) A device-independent task reading the scheduler's own run records.
             (c) A product report on the scheduler's auto-disable behaviour.
             (d) Accept the exposure.
Disposition: (a) and (b) and (c); (d) rejected. (a) every four hours, alerting
             past three hours stale. (b) every six hours, alerting on a disabled
             task, a suspension, a failed run or a stale run. Both alert-only: no
             watchdog re-enables, restarts or repairs anything. (b) states in its
             own alerts that nothing watches it in turn.
Reasoning:   (a) alone shares the machine's failure modes. (b) is immune to them
             because the scheduler records runs as a third party, and records
             "never ran" as an absence, which a self-published heartbeat cannot.
             Alert-only because a watchdog that acts is a second dispatcher in a
             system whose premise is one. The regress stops at (b) deliberately.

### GAL-D09: Liveness is terminal status, never pid existence
Date:        2026-10-15
Decider:     Operator (reference: LOOP-5 ruling)
Origin:      A dead agent reported as running for four hours; the first drafted
             workaround told the next tick to check whether the pid existed.
Question:    What is positive evidence that a dispatched job finished?
Options:     (a) The process is gone.
             (b) The log stopped growing.
             (c) The job record reached a terminal status.
Disposition: (c), only. No pid polling anywhere in the supervisor. Absent a
             terminal status past the timeout plus a grace window, the job is
             indeterminate: harvest what is on disk, record the job id, park, and
             do not dispatch a second agent against the same packet. Corroborating
             signals may inform the report but never decide it. Part (b) of the
             same ruling: dispatch uses a streaming output format so a killed agent
             leaves a partial trail.
Reasoning:   Pids are reused; the runtime that spawned the process holds a handle
             and is immune, a third party polling an integer is not. Logs are
             silent for buffered agents. Only the terminal status is written by the
             party that actually observed the exit.

### GAL-D10: One packet in flight at a time
Date:        2026-10-20
Decider:     Operator (reference: LOOP-8 ruling)
Origin:      A ratified change was sequenced "beside" a dispatched packet and the
             question arose whether that meant concurrently.
Question:    May the supervisor run two agents at once?
Options:     (a) Strictly sequential; the next packet dispatches after the current
                 one merges or parks.
             (b) Extend the cursor to a job array, make harvest iterate, serialize
                 only the gate.
             (c) Dispatch both and serialize the gate behind a mutex.
Disposition: (a). "Sequenced beside" in any ruling means queue adjacency, never
             concurrency. If real concurrency is ever wanted, (b) is the honest form
             and belongs in its own decision with per-run isolation of every
             exclusive resource as its precondition.
Reasoning:   The cursor carries one job and harvest is singular, so a second job is
             invisible to the next harvest, which is GAL-D09's failure reintroduced
             on purpose. The gate's integration tests share one database and two
             concurrent runs interleave fixtures, so both greens are untrustworthy.
             A cold gate dominates wall clock anyway, so (c) buys little.

### GAL-D11: Acceptance criteria must be covered by the capability grant
Date:        2026-10-20
Decider:     Supervisor, inside existing rules (reference: DEFECT-4)
Origin:      A packet required a container build proof from an agent whose dispatch
             granted no container tool; the packet's fallback clause absorbed the
             failure so it read as an environment limit.
Question:    Whose defect is a required criterion the agent cannot satisfy?
Options:     (a) The environment's.
             (b) The packet's.
Disposition: (b). Before dispatching, every required criterion is checked against
             the tool grant. If a criterion needs a program the dispatch does not
             grant, either grant it or stop making the criterion required. Granting
             the tool may not be sufficient, since a capability can still be
             refused by an approval layer; verify rather than assume.
Reasoning:   A fallback clause that converts a packet defect into an environment
             limit hides the defect from the review. Recorded as PM-fixable because
             it changes the packet template and the dispatch step, not a decision.

### GAL-D12: Agents commit every green step; the harness denies destructive git
Date:        2026-10-15
Decider:     Operator (reference: R-commit-early and R-recon)
Origin:      Uncommitted work in a worktree is unrecoverable under the harness's
             deny list, and the first orphaned agent run was recoverable only
             because it had committed as it went.
Question:    What must an agent do with work in progress, and what may it never do?
Options:     (a) Commit at the end.
             (b) Commit every green micro-step as it goes; the harness denies
                 checkout, restore, reset, clean, stash and any force push at the
                 permission layer.
Disposition: (b).
Reasoning:   With destructive verbs denied, uncommitted work has no recovery path,
             so the only durable state is a commit. An agent that dies mid-run
             leaves its commits; an agent that commits at the end leaves nothing.
             The deny list is enforced by the harness, not by instruction, because
             instructions can be reasoned around and permission layers cannot.

---

### GAL-D13: Instruction files are attended-only write surface
Date:        2026-10-21
Decider:     Operator (reference: LOOP-13 ruling, attended session 2026-10-21)
Origin:      An unattended tick attempting an owed amendment to the protocol file
             was refused three times by the substrate's permission classifier as
             "Instruction Poisoning", including a write of the replacement
             paragraph to a scratch file outside the repository with no edit
             performed. The trigger was the content, imperative protocol prose
             destined for a later agent, not the mechanism.
Question:    Who may edit the files that govern later unattended runs, and when?
Options:     (a) Treat the refusal as a substrate defect and route around it.
             (b) Make the protocol file, the agent ground-rules file and the
                 harness settings attended-only: edited by the supervisor only in
                 a session with the operator present, on a branch that merges
                 under the gate; an unattended run parks an owed amendment and
                 never attempts it.
             (c) Move protocol amendments into the stored prompt instead.
Disposition: (b).
Reasoning:   An unattended agent rewriting the instruction file that governs later
             unattended agents is the exact shape the guard exists to stop, and
             every protocol amendment the reference loop had landed before this
             ruling would be refused today. (a) builds on the assumption that the
             guard will keep failing open. (c) violates GAL-D07. (b) costs one
             attended session per amendment and makes the authorship of every
             protocol change a human-present event by construction. Descriptive
             writes (cursor, decision queue, receipts, state files) are unaffected
             and remain unattended write surface.

---

### GAL-D14: An agent runs in the foreground; a result event never substitutes for a terminal record
Date:        2026-10-21
Decider:     Operator (reference: LOOP-11 riders (e) and (f), attended session
             2026-10-21, after the LOOP-11 correction)
Origin:      A finished agent emitted its result event, then stayed resident for
             fifteen minutes waiting on a background task it had spawned for its
             gate run, answered a stale wakeup with a second result event, and only
             then exited. The supervisor's first diagnosis blamed the job daemon and
             recommended accepting the agent's own result event as a terminal
             signal; the correction showed the daemon was right and the process was
             genuinely alive.
Question:    How does the loop prevent an agent from outliving its own completion
             report, and what does the harvest do when it sees a result event
             before a terminal record?
Options:     (a) Accept the result event as terminal for harvest purposes.
             (b) Shorten the dispatch timeout.
             (c) Fix job reaping in the daemon.
             (d) Accept the exposure.
             (e) The dispatch prompt forbids background tasks, monitors and
                 scheduled wakeups, so the final result and process exit coincide.
             (f) Step 3 states that a result event with a non-terminal record means
                 wait, never harvest.
Disposition: (e) and (f). (a) withdrawn: it would have had the supervisor tear
             down a worktree with a live agent inside it. (b) rejected: trades a
             liveness bug for a correctness bug. (c) not applicable to this
             incident. (d) rejected.
Reasoning:   GAL-D09 held: terminal status only was the rule that kept the
             supervisor from racing a live process. The cost was one tick, not the
             hours the first diagnosis projected. (e) removes the cause; (f) closes
             the door the withdrawn (a) would have opened, so that no later
             supervisor rediscovers it as a shortcut.

---

### GAL-D15: The decision queue is append-only intake; the ledger is the sole closure record
Date:        2026-10-21
Decider:     Supervisor under the operator's explicit delegation, operator present
             (reference: LOOP-14, attended session 2026-10-21)
Origin:      Following GAL-D13, an unattended tick was refused writes to the
             decision queue and the project state file, which GAL-D13 did not
             cover. The refused writes were descriptive in form but carried
             ruling-shaped prose: dispositions, and a narrative telling later
             ticks what the current unit was.
Question:    Which bookkeeping writes may an unattended run make once instruction-
             shaped content is refused regardless of file?
Options:     (a) Extend GAL-D13 to the queue and the state file by name.
             (b) Stop writing closure into the queue at all: the queue becomes
                 append-only intake, the ledger is the sole closure record, and
                 closure is read by presence of a ledger entry.
             (c) Retry refused writes next run.
             (d) Leave the files stale indefinitely.
Disposition: (b), plus the state-file amendment from (a): an unattended run writes
             only the state file's header; the narrative is attended carriage.
             (c) and (d) rejected.
Reasoning:   (b) removes the class of write that was being refused instead of
             naming files, and matches how the two records are actually read:
             the ledger as authority, the queue as a queue. A queue that reports
             ruled items as open will eventually cause a run to re-raise a settled
             decision, which is the rule 7 failure in a different file. The
             general form is: text that reads as a ruling or as an instruction to a
             later run is attended-only by content, whatever file it lands in.

---

### GAL-D16: The lock owner is written to the cursor at acquisition
Date:        2026-10-21
Decider:     Supervisor under the operator's explicit delegation, operator present
             (reference: LOOP-15, attended session 2026-10-21)
Origin:      A tick lost its execution bridge mid-run and left the mutex ref held
             with no cursor evidence of who held it. The next tick could only wait
             out the steal window. The after-the-fact lock record landed by the
             GAL-D13 carriage records a lock only once it has been released.
Question:    How does a later run tell a crashed owner from a live one?
Options:     (a) Write the lock_history entry at acquisition with released_at null
                 and fill it at release.
             (b) Rely on the reflog and the steal window.
             (c) Shorten the steal window.
Disposition: (a).
Reasoning:   One extra cursor write per run, and the cursor is then honest about
             who holds the lock at every moment. The steal window stays as the
             safety margin instead of being the only evidence. (b) leaves the gap;
             (c) trades it for a liveness race.

---

### GAL-D17: The plan is countable and the status page is generated from the tree
Date:        2026-10-21
Decider:     Operator (reference: three rulings in an attended session; design by
             the supervisor under that direction)
Origin:      The reference project's tracker was updated by hand from whichever
             session was open, had no data source of record, could not project a
             date, and its own status session said so.
Question:    How does the loop give constant, trustworthy visibility to someone
             who will not read handoffs?
Options:     (a) A scheduled task that rewrites a tracker page from prose.
             (b) A plan of record in the repository (plan.json, under the gate), a
                 deterministic read-only snapshot script with provenance shas, a
                 validator that gates publication, and a fixed page the status
                 task republishes with a fresh snapshot beside it. The only prose
                 is a labeled narrative.
             (c) Keep the hand-maintained tracker.
Disposition: (b). The hand-maintained tracker is retired. Projection is derived
             from measured throughput and a declared packets-per-unit assumption
             the page shows; it is never chosen.
Reasoning:   Every number an investor reads should trace to a commit. (a)
             inherits every weakness of the hand tracker and adds drift. (b) puts
             judgment in two reviewable places, the script and the page, and keeps
             the task itself mechanical, which is why the cheapest model runs it
             (rule 10). The task is read-only on the repository and never takes
             the lock: it is a fifth loop item beside tick, digest and the two
             watchdogs, not a second supervisor.

### GAL-D18: The loop publishes; the operator never pushes
Date:        2026-10-27
Decider:     Operator (reference project, attended ruling 2026-10-21, as D40)
Origin:      Publishing main was the human's job, so the published branch lagged
             the gated one by however long the human was away, and nobody could
             tell a merge that had not been pushed from one that had.
Question:    Who publishes the branch the loop has already gated and merged?
Options:     (a) The operator pushes when convenient.
             (b) The supervisor publishes after every fast-forward, through a
                 governed path with the credential passed by reference, from a
                 throwaway worktree removed in the same run.
Disposition: (b). Never force, never mirror, never a branch other than main.
Reasoning:   A merge the loop performed is a merge the loop should finish. If the
             publish is refused by a permission layer, that refusal is recorded as
             evidence for the operator's settings and retried by the next run; it
             is never a reason to hand the push back to the human, because that
             reintroduces exactly the lag this closes. Report the gap with a
             left-right count against the remote rather than counting local
             commits, so a partial push is visible.

---

### GAL-D19: Machine state is written as a structured round trip
Date:        2026-10-27
Decider:     Operator (reference project, as D42)
Origin:      The cursor is JSON that both a human and a supervisor edit. A prose
             edit to a machine-read file corrupts it silently and the next reader
             fails somewhere unrelated.
Question:    How does anything write the cursor without risking its structure?
Options:     (a) Careful text editing.
             (b) Parse the file, confirm that re-serializing the parsed object
                 reproduces the bytes exactly, then edit the object, re-serialize
                 and write.
Disposition: (b). A round trip that is not byte-identical is a refusal to write,
             not a warning.
Reasoning:   The byte-identical check is the whole point. It proves the writer's
             serializer agrees with the file's existing shape before the writer is
             trusted to replace it, which catches an unexpected key order, a lost
             unicode escape or a hand edit that did not round trip. Writing is
             cheap; discovering a corrupted cursor three runs later is not.

---

### GAL-D20: A gate step that cannot run fails the gate
Date:        2026-10-27
Decider:     Operator (reference project, as D44)
Origin:      A gate step whose tool was missing reported success by doing nothing.
Question:    What does the gate do when a step cannot execute at all?
Options:     (a) Skip it and note the skip.
             (b) Fail the gate.
Disposition: (b). Fail closed. A skip is recorded in the receipt only where a
             decision has explicitly made that step conditional, and the condition
             and the skip are both named there.
Reasoning:   A gate is a claim that the suite ran. A step that silently did not run
             turns that claim into a lie that nobody can see from the receipt. The
             cost of (a) is a green gate on an unverified tree, which is the one
             thing the gate exists to prevent.

---

### GAL-D21: The work commit precedes the gate of record, and the agent asserts the binding
Date:        2026-10-27
Decider:     Operator (reference project, as D49)
Origin:      An agent ran the gate on a dirty tree, so the receipt bound nothing
             and the packet looked green.
Question:    How does a reviewer know the agent's gate ran on the work it shipped?
Options:     (a) Trust the agent's summary.
             (b) Require the work committed first, the gate run on that commit,
                 the receipt committed as its own next commit, and the agent to
                 assert in its receipt that the gate's bound commit equals its work
                 commit. The review flags a null or mismatched binding.
Disposition: (b). A null binding means the gate ran on a dirty tree and is not the
             gate of record.
Reasoning:   The independent gate the supervisor runs stays authoritative, so the
             flag alone is not a rejection. But an agent that cannot state what its
             own gate bound has not demonstrated it understands what it proved, and
             that is worth catching before review rather than after merge.

---

### GAL-D22: Scope facts come from a probe at ruling time
Date:        2026-10-27
Decider:     Operator (reference project, as D50)
Origin:      A ruling fixed a file list from an agent's halt-receipt prose. The
             file named did not hold the construct. The packet halted, and the
             cycle was lost.
Question:    Where does a decision get its facts about the tree?
Options:     (a) From the agent output that raised the question.
             (b) From a read-only probe run at the moment of ruling, cited inline.
Disposition: (b). Never from an agent's prose, never from memory, never from a
             prior document that was itself written from either.
Reasoning:   Agent prose is a claim about the tree made by something that had a
             reason to stop. Memory is worse: it was true once. A probe costs
             seconds and converts a ruling from plausible to checkable. When the
             probe contradicts the intake, say so in the ruling; that contradiction
             is itself a defect worth recording, and in the reference project it
             twice caught a supervisor error before it reached a packet.

---

### GAL-D23: Every required criterion names a test the gate can reach
Date:        2026-10-27
Decider:     Operator (reference project, as D51, amended by D69 and D77)
Origin:      Packets carried criteria that no test proved, and later a packet whose
             surface had no test harness at all could not be cut under the original
             rule.
Question:    What makes an acceptance criterion real?
Options:     (a) A clear statement of the desired behaviour.
             (b) A named test file that proves it, where the probe shows the
                 harness that file needs already exists, cited by an existing test
                 that uses it.
Disposition: (b), with two amendments. REACHABILITY: a harness that exists is not
             a harness the criterion can be reached from; the probe shows the path,
             not just the presence. NO NATIVE HARNESS: for a surface with no
             language-native test harness, the equivalent is a deterministic
             self-check script the gate runs over committed fixtures, with each
             criterion naming the fixture it asserts over. Never prose, never a
             manual step, never a criterion the gate cannot reach.
Reasoning:   The rule exists so a criterion is falsifiable by the thing that merges
             it. Written too narrowly it made its own remedy uncuttable, which is
             how the amendments arrived. Widening what counts as a test is correct;
             widening whether one is required is not.

---

### GAL-D24: A receipt commit touches only the receipt directory
Date:        2026-10-27
Decider:     Operator (reference project, as D52)
Origin:      A supervisor committed a receipt alongside an unrelated file, which
             changed the tree the receipt was binding.
Question:    What may ride in the commit that carries a gate receipt?
Options:     (a) Whatever bookkeeping is pending.
             (b) The receipt directory and nothing else.
Disposition: (b). Any other surface rides its own commit before the gate runs.
Reasoning:   The binding rule excludes the receipt directory from the hash so that
             committing the receipt cannot change what it binds. That exclusion
             covers that directory and nothing else, so a second file in the same
             commit invalidates the very receipt being written.

---

### GAL-D25: The scope probe sweeps back-references
Date:        2026-10-27
Decider:     Operator (reference project, as D56)
Origin:      A packet added a member to a set that an earlier packet had asserted
             was complete. The earlier assertion failed, in a file the new packet
             had never heard of.
Question:    How far does a packet's file list reach?
Options:     (a) The files the change touches.
             (b) Those, plus every site that asserts over a set the change extends,
                 found by grepping the workspace for each literal the criteria will
                 change.
Disposition: (b), limited to the assertion. When a packet extends a closed set a
             prior packet asserted exhaustively, that prior packet's assertion
             sites are in scope by default, for the assertion only.
Reasoning:   An exhaustive assertion is a promise about the whole set, so adding to
             the set breaks it by construction. The sweep is mechanical and cheap;
             discovering it from a red gate costs a cycle, and discovering it after
             merge costs trust in the suite.

---

### GAL-D26: The product is held to the standards of the category it claims
Date:        2026-10-27
Decider:     Operator (reference project, as D61)
Origin:      Decisions were being made against what the current single-tenant
             deployment needed, while the product was described as a competitor to
             an enterprise platform.
Question:    What standard does a decision get judged against?
Options:     (a) What the present deployment requires.
             (b) What a shipped product in the claimed category would require.
Disposition: (b). A known gap may ship only when the decision names the gap, names
             its closure path, and names the deploy gate that blocks the unsafe
             shape until it closes. "Good enough for the current deployment" is
             never accepted without those three.
Reasoning:   The bar is what stops a series of locally reasonable choices from
             compounding into a product that cannot be sold. It sits beside the
             hard invariants and never replaces them: where the bar and a
             convenience conflict the bar wins, and where the bar and an invariant
             conflict the work stops for a recorded decision. Making it operational
             matters more than stating it, so it appears in three places: a section
             in the packet template, a one-line verdict in every review, and a
             provisioning rule that refuses to cut a packet whose section is
             unfilled.

---

### GAL-D27: A standing delegation may move rulings to the supervisor, within four limits
Date:        2026-10-27
Decider:     Operator (reference project, as D64)
Origin:      The loop idled for want of authority. Work that was ready to cut
             waited on a human to rule a question the record could already settle.
Question:    May the supervisor rule, and if so with what limits?
Options:     (a) No. The operator rules everything, and the loop idles.
             (b) A time-boxed grant, renewed by hand.
             (c) A standing grant with explicit limits and a reversal path.
Disposition: (c), with four limits that the grant does not loosen. (1) Hard
             invariants are not negotiable; a plan needing one traded is refused,
             not ratified. (2) AN UNATTENDED RUN NEVER RATIFIES. (3) The operator
             keeps the physical acts: credentials, permission settings, deploy
             windows, anything reaching production. (4) Rulings that land code are
             flagged as expensive to reverse, so review stays possible.
Reasoning:   Limit (2) is the load-bearing one and it is a security property, not
             an etiquette. An unattended supervisor run reads agent output, logs
             and receipts. If such a run could ratify, any text an agent emitted
             could manufacture a decision, which inverts the authority hierarchy
             this method is built on. Ratification therefore stays with runs whose
             inputs are human-authored artifacts: the ledger, the decision queue,
             the status file and the streams. This amends the format rule that a
             decider is always a person: under a standing delegation the decider
             field names the delegation and the supervisor acting under it, and the
             operator's reversal right is what keeps it accountable.

---

### GAL-D28: One unmerged ledger carriage at a time
Date:        2026-10-27
Decider:     Supervisor under the standing delegation (reference project, as D67)
Origin:      Two branches both appended to the end of the ledger. The second
             conflicted with the first the moment either landed, and a run had to
             stop and park rather than resolve it.
Question:    How many unmerged branches may carry ledger appends?
Options:     (a) As many as rulings require.
             (b) Exactly one.
Disposition: (b). A ruling made while one is outstanding is appended to that same
             branch. When main has moved under an outstanding carriage, the
             attended supervisor re-cuts it from current main and re-applies its
             appends; the cursor records the base it was cut from.
Reasoning:   Two append-only writers at the end of one file conflict
             deterministically, so this is arithmetic rather than bad luck. A run
             still never resolves a carriage conflict, which is unchanged and
             correct; this removes the situation that produces one.

---

### GAL-D29: Boot time is the liveness oracle
Date:        2026-10-27
Decider:     Supervisor under the standing delegation (reference project, as D79)
Origin:      A job record reported itself running for seven days, across a reboot,
             with empty logs and a worktree that no longer existed.
Question:    When may a run conclude that a non-terminal job is dead?
Options:     (a) Only on a terminal status, parking indefinitely otherwise.
             (b) Also when the job started before the operating system's last boot.
Disposition: (b). A job whose start time precedes the current boot is DEAD,
             whatever its record says, and may be treated as terminal with no
             further evidence and recorded as dead-by-boot.
Reasoning:   No process survives a reboot, so this is proof rather than inference,
             and it involves no pid, so GAL-D09's prohibition on pid polling is
             untouched. The existing timeout rule can only ever park, because
             silence is not death. This adds a conclusion where one is available
             and takes none away: a non-terminal job started after the last boot
             stays indeterminate.

---

### GAL-D30: The status plane shows no figure it did not compute that run
Date:        2026-10-27
Decider:     Supervisor under the standing delegation (reference project, as D66)
Origin:      The status page republished a block of hand-maintained values under a
             fresh timestamp for days. One of them described a property as healthy
             while a confirmed breach of it sat in the decision queue.
Question:    What may the generated page display?
Options:     (a) Computed figures plus a maintained block that changes rarely.
             (b) Only what the snapshot computed for the run that publishes it.
Disposition: (b). A value that cannot be recomputed is labelled with the date it
             was asserted, excluded from every count and risk derived from it, or
             omitted. The validator fails the run when a rendered field has no
             computed source, and a failed validation publishes nothing.
Reasoning:   This extends GAL-D17 from where the numbers come from to what the page
             may show. A stale figure under a fresh timestamp is worse than no
             figure, because the timestamp is the reader's evidence of freshness.
             The same run also showed a counter including entries its own text
             marked resolved, which inflated both a count and the risk derived from
             it: a figure can be computed every run and still be wrong, so the rule
             is about provenance and the review is about correctness.

---

### GAL-D31: Dispatch cost is proportional to available work, and the gatekeeper fails open
Date:        2026-10-27
Decider:     Operator (reference project, direction) and supervisor (design)
Origin:      Budget exhaustion stopped the loop twice. The supervisor is the most
             expensive scheduled item, it loads its full protocol before it reads
             any state, and an idle run costs very nearly what a working run costs.
             Two consecutive runs did exactly that against an empty queue.
Question:    How does the loop stop paying supervisor prices for idle hours?
Options:     (a) Run the supervisor less often, which also slows real work.
             (b) Downgrade the supervisor's model, which is where review judgment
                 lives.
             (c) A cheap gatekeeper that reads only the cursor and wakes the
                 supervisor when there is work.
Disposition: (c). The gatekeeper runs on the cheapest adequate model, reads the
             cursor and the lock, and fires the supervisor unless the cursor
             explicitly declares the queue empty. The supervisor keeps a sparse
             self-schedule as a floor, so a dead gatekeeper cannot silence the loop
             for longer than that interval.
Reasoning:   The gatekeeper FAILS OPEN, and that is the whole safety argument: if
             anything is unreachable, unparseable, ambiguous or merely surprising,
             it fires. A wrong fire costs one supervisor run. A wrong silence stops
             the loop, which this method has already paid for in days. (b) is
             rejected because the expensive judgment is exactly the part worth
             paying for: in the reference project the supervisor's probe found a
             real cross-tenant defect and, separately, caught a dependency trap
             before dispatch that would have cost a full cycle. Cheapening the
             reviewer to save on review is the wrong direction. Note that the
             gatekeeper becomes the thing that must run hourly, so the watchdogs
             must watch it rather than the supervisor once the supervisor leaves
             its dense schedule.

---

### GAL-D32: An outstanding ledger carriage is work in the queue
Date:        2026-10-28
Decider:     Operator (reference project, as D90 and D97, both ruled under the
             standing delegation)
Origin:      Three rulings in one day sat on short-lived carriage branches that
             never reached main. Runs read the ledger on main (GAL-D05), so each
             was invisible: twice the stranded ruling was the very work the loop
             then reported itself idle for want of, and the third was the rule
             that would have caught the first two. GAL-D03 says where an append
             rides and GAL-D28 says how many carriages may exist; neither says
             what happens to a carriage with nothing left to ride.
Question:    What happens to a ledger carriage when the packet queue empties, and
             when may a run declare the queue empty?
Options:     (a) Wait for the next packet branch; the carriage rides it whenever
                 that is.
             (b) The deciding session gates and merges its own carriage.
             (c) Every run probes for an outstanding carriage by content before
                 it may declare the queue empty or blocked, and the run that
                 finds one lands it as its own gated carriage when no packet
                 branch will carry it.
             (d) Accept the exposure.
Disposition: (c). Outstanding means: a carriage tip that is not an ancestor of
             main AND whose diff against main on the ledger adds a decision
             heading main lacks. Ancestry alone is not the test, because
             superseded branches would report forever. A non-empty probe is work
             in the queue: the run re-cuts the carriage from current main,
             verifies that the ledger differs from main by exactly the original's
             added text, runs the independent gate and fast-forwards. That is
             landing, not ratifying; the run writes no ruling of its own, and a
             conflict still stops and parks (GAL-D28). A held idle or blocked
             determination is re-tested against the same probe at the start of
             every run. (a) is what stranded three rulings. (b) rejected: a
             session that both rules and merges puts its rulings on main without
             the independent gate, which is GAL-D27 limit (2) by another route.
             (d) failed twice in one day.
Reasoning:   The ledger on main is the only ledger a run reads, so a ruling
             anywhere else does not exist to the loop. The probe makes that state
             loud within one cadence, and the vehicle already existed, because a
             run can gate and merge a supervisor-surface branch. The rule is
             written as a probe keyed on content so that litter branches stay
             quiet and so that the check cannot be satisfied by remembering.

---

### GAL-D33: No trigger of the supervisor depends on the operator's machine being awake
Date:        2026-10-28
Decider:     Operator (reference project, attended session 2026-10-28; the
             standing recommendation recorded in the cursor after the third
             device-absence outage)
Origin:      Between 00:18Z and 00:29Z on 2026-10-28 the operator's computer was
             unreachable and the scheduler auto-disabled every task that required
             it, each with suspension_reason device_absent: the gatekeeper, the
             supervisor and the decision session, in eleven minutes. The loop had
             no dispatcher for an hour. A cloud-only watch created three hours
             earlier ran throughout. This was the third time device absence had
             switched off the only dispatcher.
Question:    Which loop components may be bound to the operator's machine?
Options:     (a) All of them except the cloud watchdog, with the watchdog layer
                 to catch the disable.
             (b) No trigger of the supervisor is device-bound. The gatekeeper,
                 the supervisor and the decision session run without a device
                 binding and reach the repository through the execution
                 substrate; only a component whose job is the machine itself,
                 the device watchdog, is bound to it.
             (c) Find a scheduler that does not auto-disable.
Disposition: (b), wherever the execution substrate is reachable from the cloud,
             as the reference substrate is. A component that a closed laptop can
             switch off must never be the loop's only trigger. Where the
             substrate is a shell on the machine and nothing else, the binding is
             unavoidable and is recorded as a known weakness with its cost; the
             cloud watchdog is then the only cover and the sparse-backstop
             cutover (GAL-D35) is not available.
Reasoning:   (a) is what the kit carried and it was disproved three times. The
             watchdog layer shortens an outage; it does not prevent one, and a
             watchdog that alerts a sleeping operator at midnight has preserved
             the outage, not the loop. A run that cannot reach the machine ends
             quietly in one line and costs nothing; a task the scheduler has
             disabled costs the loop until a human notices. (c) swaps the
             scheduler, which is a swap point, and still leaves the loop
             depending on a machine for a job that needs the machine only for a
             few commands.

---

### GAL-D34: The gatekeeper judges dispatchability from the cursor's determination, and a run that ends with nothing in flight says so in every field
Date:        2026-10-28
Decider:     Operator (reference project, gatekeeper corrected in the attended
             session of 2026-10-28; the obligations DEFECT-31 left open there are
             ruled here for the kit)
Origin:      The reference gatekeeper skipped only on the literal state name
             idle. D97 then introduced idle-blocked, so a loop that was provably
             unable to dispatch fired the expensive supervisor every hour, the
             inverse of the gatekeeper's purpose. Separately, a supervisor run
             that parked on a failed gate left the cursor's top-level job_id
             naming a job harvested two runs earlier, and the gatekeeper's first
             rule, a non-null job_id fires, produced the same wrong fire for as
             long as the loop stayed blocked. The same parked run had left queued
             and the next-action text describing a packet merged two runs before,
             handing its successor a stale instruction.
Question:    What may the gatekeeper key its skip on, and what does a run owe the
             cursor's other readers when it ends with nothing in flight?
Options:     (a) Enumerate every state name that means skip, and keep the list
                 current as the ledger grows.
             (b) The gatekeeper skips only on the cursor's freshly written
                 determination that nothing is dispatchable, whatever the state
                 is called, and fires on anything else; and every run that ends
                 with no job in flight clears job_id, dispatched_at and all
                 in-flight language, and rewrites queued and any next-action
                 field to describe the situation it is leaving, not the one it
                 found.
             (c) Invert the gatekeeper's rule order so a blocked determination
                 outranks a non-null job_id.
Disposition: (b). The determination has two shapes with one consequence, an
             empty queue and a blocked queue, and the skip covers both. The
             job_id rule stays first, because fail-open is the gatekeeper's
             safety argument and a cursor that lies about in-flight work is the
             run's defect, not the gatekeeper's. A run that parks writes its
             state and its gate result and refreshes its successor's
             instructions in the same write; a partial write is a defect of the
             run. (a) rejected: the set of state names grows with the ledger and
             a cheap reader cannot be re-taught every time. (c) rejected: it
             teaches the gatekeeper to reason about staleness, which is exactly
             the judgment it was built not to need.
Reasoning:   The cursor is a shared bus with more than one reader. The supervisor
             can reason about a stale field; a cheap scheduled task cannot, and
             it costs money every hour it is misled. Keying the skip on a
             determination the run re-tests every time (GAL-D32) rather than on
             a name that can go stale puts the truth-keeping obligation on the
             one component with the judgment to keep it. The reference saw both
             halves of this in one day.

---

### GAL-D35: The gatekeeper cutover has three preconditions
Date:        2026-10-28
Decider:     Operator (reference project, attended session 2026-10-28; extends
             the arming rule the kit already carried)
Origin:      The reference gatekeeper ran for a day without automatic approval,
             so every firing waited on a human who was often asleep, and nothing
             noticed because the supervisor's own hourly schedule covered the
             gap. The next day the gatekeeper was auto-disabled by device absence
             alongside the supervisor it fronts. Had the supervisor already been
             on its sparse backstop, either condition would have slowed the loop
             to the backstop interval with no alert.
Question:    When may the supervisor leave its hourly schedule for the sparse
             backstop behind the gatekeeper?
Options:     (a) When the gatekeeper has fired at least once.
             (b) When the gatekeeper has demonstrated its skip path on a
                 genuinely empty or blocked queue, runs with automatic approval,
                 and carries no device binding the scheduler can disable; all
                 three read back from the scheduler's own task record, not from
                 what was asked for.
Disposition: (b). Until all three hold the supervisor keeps its hourly schedule
             and the gatekeeper runs beside it; the mutex makes the overlap safe.
             A gatekeeper that needs approval is decorative: it fires when
             someone is awake. A gatekeeper the scheduler can switch off is a
             single point of failure in front of the component the loop depends
             on.
Reasoning:   The skip path is the one that can stop the loop, so it has to be
             observed; the kit already said so. Approval and device binding are
             the two ways a correct gatekeeper still fails to fire, and both are
             invisible from the tree, which is why the evidence is the
             scheduler's record and why the arming step reads it back.

---

### GAL-D36: A gate that removes a capability names its replacement
Date:        2026-10-28
Decider:     Operator (reference project, as D98, attended)
Origin:      The reference correctly gated its migration embed out of the
             production binary, and nothing replaced the production migration
             path. Three decisions that were each right met at a point nobody
             stood on: a production database that could not take a migration and
             could not state its own schema version, discovered when a deploy
             window was scoped to apply migrations that had no mechanism to run.
Question:    What does a build-integrity decision owe when it subtracts something
             the system used to be able to do?
Options:     (a) Nothing beyond the gate; the subtraction is the point.
             (b) The decision names what now performs the removed capability, or
                 names the gap, its closure path and the deploy gate that blocks
                 the unsafe shape until it closes (the GAL-D26 three), and a
                 probe at ruling time confirms the replacement exists.
Disposition: (b). A gate that subtracts is ratified only with its replacement or
             its named gap. Building the replacement does not grant the authority
             to run it: the capability and its trigger are separate decisions.
Reasoning:   Each of the three decisions was reviewed on its own terms and
             passed. None was asked what the system could no longer do once all
             three held, because no rule asked. The question is cheap at ruling
             time and expensive at deploy time, and the GAL-D26 three were
             already the form for a named gap; this makes them owed by
             subtractions as well as by shortfalls.

---

### GAL-D37: The probe at ruling time covers intakes and prior findings
Date:        2026-10-28
Decider:     Operator (reference project, attended session 2026-10-27, where the
             error was made and corrected)
Origin:      The reference supervisor repeated a filed intake's claim to the
             operator, that four deploy gates were in no runbook, without
             checking it. The gap had been closed on main: only one gate was
             absent and a ruling already assigned it. GAL-D22 required a probe
             for facts about the tree, and the supervisor had probed the file
             list; it had not probed the claim.
Question:    What does the probe-before-ruling rule cover?
Options:     (a) File lists, paths and constructs: the tree facts GAL-D22 names.
             (b) Those, plus every intake, prior finding and parked item that a
                 ruling or a report relies on, re-read against current main at
                 the moment of use.
Disposition: (b). An intake is a claim about the tree made at the time it was
             filed, by a run that may have been wrong, about a tree that has
             since moved. Before a ruling cites one or a report repeats one, the
             run re-tests the claim and says whether it still holds. A
             contradiction between the intake and the probe is recorded as a
             defect of the intake.
Reasoning:   GAL-D22's own reasoning says memory is worse than agent prose
             because it was true once. A filed intake is memory with a heading.
             The probe costs seconds; the miss cost a false report to the
             operator and, had it been ruled on, a packet cut to close a gap that
             was already closed.

---

### GAL-D33-C1: Correction to the evidence cited by GAL-D33 and GAL-D35
Date:        2026-10-28
Decider:     Operator, in an attended review of the kit
Origin:      GAL-D33's disposition says the unbound shape is available "as the
             reference substrate is", and GAL-D35 says all three cutover
             preconditions are "read back from the scheduler's own task
             record". The audit behind both had read the reference scheduler's
             approved-folders field as the device binding and concluded that
             the reference's gatekeeper and supervisor already ran unbound.
Question:    What does the reference actually demonstrate, and how is a device
             binding verified?
Options:     (a) Edit the two entries.
             (b) Append this correction beside them, never over them.
Disposition: (b). The entries stand as written; this records what was wrong.
             The reference's gatekeeper, supervisor and decision session were
             all still bound to the machine on 2026-10-28, which is exactly why
             all three were auto-disabled with device_absent in eleven minutes.
             Unbinding them is the standing recommendation in the reference,
             not an accomplished fact. The one component that has demonstrated
             the unbound shape is the hourly watch created without a device
             requirement, which survived the window. The approved-folders field
             in the scheduler's listing is not the binding and the listing does
             not expose the binding at all; the only API-visible signal is the
             "still requires that computer" line returned on a prompt update,
             observed on the gatekeeper while its listing showed no folders.
             GAL-D35 therefore reads: approval is read back from the task
             record; the binding is verified by whatever signal the scheduler
             gives, and a scheduler that gives none means the task is treated as
             bound.
Reasoning:   The design requirement in GAL-D33 is strengthened by the
             correction, not weakened: three bound tasks died together and the
             one unbound task did not. But a kit that told adopters the
             reference already runs unbound would have cited as a proof the
             exact thing that failed. The attended supervisor made the same
             misreading of the folders field earlier the same day, which is why
             the field is now named in SWAP-POINTS section 6 as the trap it is.

---

## Adopting this ledger

Copy this file to `docs/DECISIONS.md` in the target repository. Keep the format
section verbatim. Keep the foundational entries as they are, so the target's own
ledger can cite `GAL-D04` rather than restating it. Begin the target's own numbering
at `D01` below a heading for the project, and reference GAL ids where a project
decision applies one.

A project may amend a foundational decision with its own dated entry that cites the
GAL id and states the amendment. It may not edit the GAL entry. If a substrate
makes a foundational decision impossible to honour, that is recorded as a known
weakness with its cost, the way `FAILURE-LOG.md` records the reference's, and is
not quietly dropped.
