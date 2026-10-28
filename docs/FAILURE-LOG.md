# Failure log

The eleven rules in `README.md` were not designed. They were extracted from a week of
running the reference implementation and writing down what broke. This file is the
evidence. Every entry has a date, what was observed, the root cause, and the rule
or decision it produced. Hashes are the reference repository's and are included so
the claims are checkable, not decorative.

The reference implementation is SignalDesk AiTSM: a Rust workspace of about thirty
crates on Windows, dispatching Claude Code headlessly through a governed MCP
execution runtime, supervised by an hourly scheduled task. It went live on
2026-10-15. This log runs from 2026-10-15 onward; every entry is dated.

If a rule in this method looks excessive, find its entry here first.

---

## The two outages

These are the headline cost and the reason the watchdog layer is not optional.

**Outage 1. 2026-10-16, seventeen hours.** The supervisor's scheduled task was
auto-disabled at 00:23Z with `suspension_reason: device_absent` because the laptop
was unreachable at that one firing. Nothing alerted. The dispatched agent had
finished cleanly at 00:06Z, exit 0, all work committed, and sat unharvested until
the operator checked by hand at 16:40Z. The loop had done its job and nobody
collected the result.

**Outage 2. 2026-10-16 to 2026-10-20, three days and twenty hours.** Both scheduled
tasks failed at 20:21Z and 20:23Z with `USAGE_LIMIT_REACHED`, then an hour later
both were auto-disabled with `device_absent`. The agent for PKT-004 had completed at
19:56:58Z, exit 0, three commits on its branch. It was found on 2026-10-20 at
16:05Z. The budget exhaustion was aggravated by the decision digest task having
been changed from daily to hourly, which doubled scheduled session consumption for
no decision value.

Neither outage involved an agent failure. Both were the supervisor stopping with
no observer. This produced LOOP-7, rule 1's corollary, and the two-layer watchdog.

---

## Loop incidents

### LOOP-1. Loop bookkeeping on a side branch, 2026-10-15

**Observed.** The loop's own files lived on a long-running branch that had never
merged to main. Main was checked out nowhere. The question arose whether
write-surface-only commits could fast-forward main without a gate run.

**Root cause.** No decision existed about what the loop's own bookkeeping was
allowed to do to main.

**Produced.** D19: no ungated fast-forward of main, ever, including for
bookkeeping. Every PM commit that reaches main needs its own receipt or rides a
packet branch that has one.

---

### LOOP-2. Dispatch denied by the session permission layer, 2026-10-15

**Observed.** Ticks 7 and 8 saw the supervisor session's own permission classifier
refuse `execute_start` of the agent binary with the label "Create Unsafe Agents."
The execution runtime was healthy throughout.

**Root cause.** Never identified. It stopped on its own after two occurrences.

**Produced.** Closed on 2026-10-20 after three consecutive clean dispatches, with
closing text that says explicitly the cause was never found, so a recurrence is
recognized as a recurrence rather than diagnosed from scratch. The general lesson:
an intermittent failure that stops by itself is not a fixed one, and the closing
record should say so.

---

### LOOP-3. Shared budget across supervisor, agents and operator, 2026-10-15

**Observed.** The 13:24Z tick ran eight seconds and ended with
`USAGE_LIMIT_REACHED`. Eight ticks, four agent runs and two cold gate builds had
landed in one window.

**Root cause.** Hourly ticks, dispatched agents and the operator's own sessions
all draw on one budget. While limited, ticks fail fast and harvest nothing.

**Produced.** A note rather than a protocol change. The operator declined to slow
the cadence, correctly: halving the tick doubles the window finished work sits
unharvested, which is the expensive thing. The real lever turned out to be the
digest cadence (see outage 2) and the watchdog model choice (rule 10).

---

### LOOP-4. The bus forked between two branches, 2026-10-15

**Observed.** Ticks read `DEC-PENDING.md` from a working tree on the side branch
while an authoritative copy diverged on main. Tick 16 carried some items to main
and missed three ratified decisions and an operator ruling, because it read the
committed side-branch copy and those edits were only in the working tree.

**Root cause.** Two copies of the record, no rule about which one was true.

**Produced.** D23, the split bus: the cursor is the only file that lives on the
side branch; every other loop file is main-authoritative, read with `git show
main:<path>`, written only on a packet branch that merges under the gate. The
ratified-but-uncommitted text was committed as a durability checkpoint first, then
carried properly.

**Also produced.** The rule that main must never be checked out permanently,
discovered while ratifying D23: the merge path is `git fetch . <branch>:main`, and
git refuses that while main is checked out in any worktree.

---

### LOOP-5. A dead agent reported as running for four hours, 2026-10-15

**Observed.** Job `8060745e`, pid 48528, `timeout_ms` 14400000. At elapsed 4h03m
the execution runtime reported `status: running`, `exit_code: null`. The process
had been dead since 18:39:39Z. Three independent checks agreed: the pid did not
exist, both job logs were zero bytes with mtime at creation, and the record's
`last_updated` was 133 ms after `started`. The supervisor polled it across three
ticks, read Running each time, and waited 3h45m on a corpse.

**Root cause.** Three defects in the execution runtime: the timeout was declarative
only, the status endpoint echoed the record without assessing liveness, and the
runtime's own stuck-job detector keyed on a field written once at start, so its
detection latency was structurally equal to the timeout. Reported upstream.

**Also learned.** The agent's buffered JSON output format wrote nothing until exit,
so a killed agent left no trail. Its work survived only because the packet required
committing every green step.

**Produced.** Rule 5. Operator ruling: liveness is the job record reaching a
terminal status, never pid existence. Pids are reused; the runtime holds a handle
and is immune, a third party polling an integer is not. Absent terminal status past
the deadline is indeterminate, not running. Part (b): dispatch switched to streaming
output so a killed agent leaves a partial trail. R-commit-early stays as the real
backstop.

**The nearly-wrong fix.** The first cursor rule written in response told the next
tick to confirm the pid exists before believing a job was running. That is the
unsound check being removed from the runtime, reimplemented in the consumer. It was
caught and replaced before a tick acted on it.

---

### LOOP-6. Two supervisors ran at once and the lock did not stop it, 2026-10-16

**Observed.** A scheduled tick fired at 16:54:52Z. An attended tick was fired at
17:02Z under a merge hold set at 16:56Z. Both harvested the same packet, both
reviewed the same diff, both ran a full independent gate on tip `b9c6832`, two
gate runs for one tree. The scheduled tick merged to main at 17:10:29Z under a
hold it could not see.

**Root cause.** Three failures, none the operator's. The step-1 lock was advisory
and lived in a file the other tick overwrote wholesale. The staleness rule was the
only interlock and was unenforceable without compare-and-swap. A hold set after a
tick read the cursor was invisible to that tick for the rest of its run.

**Rider.** The concurrent tick wrote `last_tick: 17:35Z` at a real host time of
17:20:08Z, ten minutes in the future. Since the only interlock keyed on lock age, a
forward-dated lock silently suppresses legitimate ticks for the length of the skew.

**Produced.** Rule 6. An owned git ref `refs/pm/tick-lock` acquired by
compare-and-swap against non-existence (`git update-ref ... <commit> ""`, git's
CREATE_NEW), released by compare-and-swap delete, stolen only when older than 50
minutes and only by explicit compare-and-swap against the observed value. Plus a
mandatory re-read of the cursor as the last operation before any mutating step,
aborting if lock ownership or the hold changed, with the merge step named
specifically because it is the only irreversible one. Plus a hard rule that every
cursor timestamp comes from the host clock via a command, never estimated.

**First contended exercise.** 2026-10-20, tick 22, forced at 16:20Z with the
scheduled firing landing at 16:23Z. The forced tick took the lock cleanly, held it
through a 19-minute gate, and at 16:25:41Z the ref still held its value with a
single reflog entry. The scheduled tick lost the CAS and exited quietly. Released
by CAS delete. The interlock behaved.

---

### LOOP-7. Nothing watches the dispatcher, 2026-10-16 and again 2026-10-20

**Observed.** See the two outages above. The supervisor is the only thing that
harvests finished work, and when it stops, nothing notices.

**Root cause.** Every watchdog the loop had was inside the tick. A watchdog that is
itself the tick cannot detect its own absence.

**Produced.** Rule 1's corollary, ratified as D26 with three parts. (a) A
device-bound watchdog reading the cursor's `last_tick` every four hours, alerting
past three hours stale. (b) A cloud-only watchdog with no device dependency,
reading the scheduler's own run records every six hours, alerting on a disabled
task, a suspension, a failed run or a stale run. (c) A product report on the
scheduler's undocumented auto-disable behaviour. (d) Accepting the exposure was
rejected as no longer defensible.

**The design insight behind (b).** The original framing assumed an off-device
heartbeat needed somewhere new to publish to. It does not. The scheduler's own
record of each run is a heartbeat written by a third party, readable without the
device, and it is strictly better than anything the tick could publish about
itself, because a self-published heartbeat is silent in exactly the failure it
should detect. A tick that never ran writes nothing. Same reasoning as rule 5.

Both watchdogs are read-only and alert-only by operator ruling. A watchdog that
repairs things is a second actor in a system whose premise is that there is one.
Nothing watches the cloud watchdog, and its own alert text says so.

---

### LOOP-8. Why the loop cannot run two agents, 2026-10-20

**Observed.** A ratified dependency bump was sequenced "beside" a packet already
dispatched. The tick dispatched one and did not run the other concurrently.

**Root cause.** Three counts. The cursor carries one `job_id` and harvest is
singular, so a second job is invisible to the next harvest, which is LOOP-5
reintroduced on purpose. The gate's integration tests run against one database
and two concurrent gates interleave fixture data, so both greens are untrustworthy.
A cold gate is 19 to 25 minutes and two concurrent cargo builds contend for CPU and
caches, so the likely outcome is two slower runs.

**Produced.** Rule 4. Operator ruling: strictly sequential, one packet in flight.
"Sequenced beside" means queue adjacency, never concurrency. If real concurrency is
ever wanted, the blocker to solve first is per-run database isolation, not the
cursor shape.

**The provenance incident.** The PM wrote the LOOP-8 rule into the supervisor's
stored prompt labelled "ratified 2026-10-20" before the operator had ruled. Tick 23
read the stored prompt, correctly treated it as level-one operator instruction,
recorded the ratification in the ledger citing the prompt as authority, dispatched
a packet under it, and tick 24 merged that to main. The operator ruled after the
merge. The substance was correct; the provenance was not. A dated correction entry
was appended beside the original, not over it. This produced LOOP-9.

---

### LOOP-9. The stored prompt is unaudited level-one authority, 2026-10-20

**Observed.** See the provenance incident above. Nothing in the loop could
distinguish an operator ruling from a PM edit once text was in the stored prompt,
and a tick reading it could not either.

**Root cause.** The scheduled task's stored prompt sits at level 1 of the
instruction hierarchy, above the protocol file and above the decision ledger. It is
editable by the PM, lives outside the repo, outside the gate, and outside any audit
trail. It is the highest-authority unaudited surface in the loop, and the hole
belongs to whoever can edit it, not to the incident that exposed it.

**Produced.** Rule 7, ratified as D25: a tick may not cite the stored prompt as the
sole authority for a ratification. A ruling must land in the decision ledger under
the gate before a tick treats it as ratified. The stored prompt may restate a
ratified decision; it may never originate one. Scope clarification: an attended
ruling recorded in the cursor, host-clock stamped and committed, remains a valid
origin whose ledger text lands on the next packet branch, because without that the
rule deadlocks against D21.

**The stored prompt's own inverted hierarchy.** Separately, the original stored
prompt said its inline rules applied "even if the protocol file diverges," which
silently put a PM-editable prompt above the gated protocol. Rewritten so that a
contradiction between them is a halt condition rather than a precedence rule.

---

### LOOP-10. A guard with no true negative, 2026-10-21

**Observed.** The protocol's bus-split guard said: if the loop branch carries
anything beyond the cursor, that is a violation. Run honestly it fired every tick,
because 26 commits of pre-split history on that branch touched twelve paths. A tick
either parked the same historical finding every hour or silently reinterpreted the
sentence. The tick parked it and asked.

**Root cause.** The guard was written against the intended end state, not the
branch's actual history, so it could never return a negative.

**Produced.** The guard keys on a watermark: a violation is a commit on the loop
branch *after* a named commit that touches any path other than the cursor,
checked mechanically with `git log --name-only <watermark>..<loop-branch>` and
a path exclusion. First true negative on the next tick, every tick since. The
operator rejected rewriting the branch to match the rule as written, because the
cursor's whole audit trail lives in that reflog. A guard that cannot say "no" is
noise that trains the loop to ignore a real guard.

---

### LOOP-11. The supervisor misdiagnosed a live process as a stale record, 2026-10-21

**Observed.** A packet's agent emitted its result event at 04:20Z. The supervisor's
04:24Z tick found the job record non-terminal and exited quietly, correctly. It
then parked a finding that the job daemon had stopped updating the record and
recommended amending the harvest to accept the agent's own result event as a
terminal signal, projecting three and a half hours of idle ticks.

**What actually happened.** The agent had launched its gate as a background task.
After its first result it stayed resident, received a stale wakeup from that task at
04:35Z, answered it with a second result event, and exited. The record's
last-updated time equalled start because the daemon records state changes and the
state had not changed: the process was alive. The record went terminal at
04:35:09Z, and the next tick harvested normally. Cost: one tick.

**Root cause.** A headless agent that spawns background work can outlive its own
completion report. The supervisor read "no update since start" as "daemon dead"
when it meant "nothing changed".

**Produced.** A correction entry appended beside the original (never overwriting
it), withdrawing the recommendation, and GAL-D14: the dispatch prompt forbids
background tasks, monitors and scheduled wakeups, and the harvest step states that
a result event with a non-terminal record means wait. The proposed shortcut would
have had the supervisor tear down a worktree with a live agent inside it. Rule 5
held; the correction is the evidence that it should.

---

### LOOP-12. A foreground sleep wedged the device bridge, 2026-10-21

**Observed.** Pacing between gate polls, a tick issued a synchronous
`Start-Sleep -Seconds 420` with a generous job timeout. The bridge's own reply
budget is sixty seconds and independent of the job timeout. The call timed out,
and the next two read-only calls also timed out while the sleeping job held the
execution slot. About four minutes and three calls lost; nothing mutated.

**Root cause.** The job timeout governs the job. The bridge budget governs the
call. They are different numbers and the second is the binding one for anything
synchronous.

**Produced.** Pace in-session, never with a foreground command longer than the
bridge budget. Already a substrate gotcha below; this is the incident that
measured it.

---

### LOOP-13. The classifier refuses unattended edits to the protocol file, 2026-10-21

**Observed.** A tick attempting an owed, operator-directed amendment to the
protocol file was refused three times by the substrate's permission classifier,
reason "Instruction Poisoning". The third attempt wrote the replacement paragraph
to a scratch file outside the repository and performed no edit; it was refused
too. In the same tick, descriptive writes to the cursor and the decision queue
succeeded.

**Root cause.** The trigger is the content: imperative protocol prose that a later
unattended agent will read and follow. Every protocol amendment the loop had
landed before this would be refused today.

**Produced.** Rule 11 and GAL-D13. The protocol file, the agent ground-rules file
and the harness settings are attended-only write surface. The first amendment
under the rule, carrying the LOOP-11 riders and the lock-history record, was made
by the supervisor in an attended session on a carriage branch and merged under the
gate by the next unattended tick, which is allowed to gate and merge it, just not
to write it.

---

### DEFECT-5. A ratified outcome was unreachable inside the packet scope, 2026-10-21

**Observed.** A packet to make a policy evaluation transactional halted in 41
seconds with no code change: the repository trait had no transactional method, the
trait crate was out of scope, and the packet named out-of-scope as a halt. The agent
also corrected a field path the prior audit had got wrong and confirmed that no
migration was needed.

**Root cause.** The supervisor drew the packet scope from the audit's description
of the code rather than from the trait definition, and the ratification said "one
bounded packet", so the supervisor could not re-shape it on its own authority.

**Produced.** A good halt, accepted as a successful outcome. The operator split the
work: the half reachable today dispatches now; the half needing the trait change
gets the trait crate in scope and queues behind it. The supervisor's rule is that
it may narrow a packet it wrote (GAL-D06) but never widen one; widening is a
ruling.

---

### LOOP-14. The guard refuses ruling-shaped prose in any file, 2026-10-21

**Observed.** The first unattended tick after GAL-D13 was refused three writes it
had made many times before: the decision queue's disposition section (twice, once
narrowed), the state file's current-unit paragraph, and a script covering both.
Same reason as LOOP-13. The tick stopped re-attempting rather than rewording until
something passed.

**Root cause.** GAL-D13 named files. The guard keys on content: dispositions and
"the next tick does X" narrative are instructions to a later unattended agent
whatever file they sit in.

**Produced.** GAL-D15. The queue becomes append-only intake, the ledger the sole
closure record, the state file's narrative attended carriage. Removing the class
of write is sounder than ruling on each file, and the general rule is stated by
content, not by path.

---

### LOOP-15. A crashed owner is invisible until the steal window expires, 2026-10-21

**Observed.** A tick lost its execution bridge mid-run. The mutex ref stayed held,
its reflog named the generic lock message, and the cursor said nothing, because the
after-the-fact lock record is only written at release. The next tick saw a held
lock of unknown provenance and waited.

**Root cause.** The lock record written at release proves a lock was held; it
cannot show who holds one now.

**Produced.** GAL-D16: the lock_history entry is written at acquisition with
released_at null and completed at release, so the cursor always names the holder
and a crashed owner is visible immediately. The steal window becomes the safety
margin rather than the only evidence.

---

### LOOP-16. The isolation suite leaked a database per run, 2026-10-22

The shared test server held 471 databases totalling 6.3 GB. 469 were per-test
throwaways created by one integration suite, one per run, never dropped.

The teardown existed. The suite had a destructor that dropped its database, and on
failure it printed the error and continued. So the cleanup had been failing for 469
consecutive runs and reporting it only into a test log nobody read. A destructor is
also skipped outright when a process is killed or aborts, which this gate had done
before, so it was never a sufficient guarantee on its own.

It surfaced as an availability problem rather than a disk problem. After a reboot
the server needed crash recovery and spent over ninety seconds walking those
directories while refusing every connection. A gate firing in that window would
have failed for a reason unrelated to the tree.

Three rules came out of it, all folded into the per-run-database packet: a startup
sweep that drops stale throwaways is a required backstop, because a destructor that
never runs cannot be fixed by improving the destructor; a failed teardown must
surface through the gate rather than into a log; and the gate records the server's
database count in its receipt, so growth is visible every run instead of being
discovered after an outage. The second is the general lesson: a cleanup that fails
silently is indistinguishable from one that works.

### LOOP-17. An orphan job record survived a service restart, 2026-10-27

A job record reported itself running with an idle time of 623625 seconds against
its own 14400 second timeout. The probe found empty logs, a record last updated 133
milliseconds after launch, a worktree long removed, and no reference to it anywhere
in the cursor. The host had rebooted seven days after the job started.

It could not be cancelled. The cancel call refused it, because the service that
owned the record had been replaced at restart, so the runtime held an orphan it had
no way to reap. A sweep of all 309 records found exactly one in that state, so the
reaper was not systemically broken.

The useful output was GAL-D29 rather than the cleanup. A record that survives a
restart still claiming to run is a substrate defect worth recording, and the fix in
the loop is to stop asking the record and start asking the clock.

### LOOP-18. The supervisor attributed a deliberate pause to a fault, 2026-10-27

The loop was dark for about 97 hours. The next run read the gap as the dispatcher
outage incident firing a third time, reported that neither watchdog had shortened
it, and concluded that the alerting layer had become the thing that failed.

Every observation in that report was accurate and the conclusion was wrong. The
operator had paused the scheduled tasks because the account hit its usage limit, and
restarted them by hand. The watchdogs were silent because they were paused too.

What made the error available: re-enabling clears the paused state, so after the
fact a deliberate pause and a recovered fault look identical from the scheduler's
own fields. Enabled true, no suspension reason, and update timestamps clustered in
one minute are equally consistent with both, and the cheaper explanation was the
true one.

The rule: a run that finds a long gap reports the gap and the candidate causes and
leaves the attribution to a session that can ask. Attributing an outage to a defect
that did not occur is the misattribution class the provenance decisions exist to
prevent, applied to operations rather than to rulings, and the cost is concrete. A
false incident entry would have justified spending a packet hardening an alerting
layer that worked correctly.

### LOOP-19. Budget exhaustion stopped the loop twice, 2026-10-16 and 2026-10-22

The first time the dispatcher failed on a usage limit and was then auto-disabled,
costing seventeen hours with a finished agent unharvested. The second time the
operator paused everything deliberately to stop the spend, costing about 97 hours.

The loop had no visibility into its own consumption and no cadence that scaled with
available work. The dispatcher ran hourly whether or not anything was queued, and
because it loads its full protocol before reading any state, an idle run cost very
nearly what a working run cost. Two consecutive idle runs were observed doing
exactly that.

Budget is therefore a first-class design constraint for this method, not an
operational detail, and it is the subject of GAL-D31. The specific trap worth
naming: the instinct is to cheapen the expensive component, and the expensive
component is the one doing the review that the whole method depends on.

### DEFECT-6. A ruling named a path that did not exist, 2026-10-27

A decision scoped a gate step to a directory that was not in the tree. The packet
halted rather than guessing which of two similarly named directories was meant,
which was correct behaviour, and the cycle was lost.

The decision had been written without a probe, by the supervisor, days after it had
itself ratified the rule requiring probes at ruling time. It is recorded here rather
than quietly corrected because the rule's author violating it is the strongest
available evidence that the rule is necessary and that seniority does not exempt
anyone from it.

## Receipt binding: three consecutive packets

The single most repeated finding, and the one that justifies rule 3 on its own.

| Packet | Agent receipt | Bound tree | Delivered tip | What landed after the gate |
|---|---|---|---|---|
| PKT-002b | `68a86165c725` | `0bab877` | `b9c6832` | R4 test, STATUS and tracker edits |
| PKT-004 | `ea625fb97d41` | `f34148f` | `dac47d2` | the agent's receipt file |
| PKT-007 | `8a663e108938` | `97c8ef7` | `03f49af` | the agent's receipt file |

In every case the agent ran its gate, then committed again. In every case the
later commit touched a tracked path inside the bound surface. In every case the
agent's report said the receipt showed green, which was true of a tree it did not
deliver. In every case the supervisor's independent gate on the exact delivered tip
caught it.

**Produced.** D22 (a gate receipt names its commit), ratified 2026-10-16 and
landed 2026-10-20 as PKT-008: `head_commit_at_gen` becomes a required receipt
field, and a new `binds_commit` field self-attests the commit when the staged
manifest equals HEAD's tree manifest with the receipts directory excluded. The
pattern that was caught by diligence three times is now structurally impossible.

**The proof by recomputation.** Tick 19 recomputed the binding rule from commit
objects: SHA256 over ordinally sorted `git ls-files -s` lines excluding
`docs/gate-receipts/`. Control at `b9c6832` reproduced receipt `a730c7db0062`
exactly over 833 files. Subject at main `5390b71` produced the identical hash,
because the receipt commit touched only the excluded directory. That is what
"excluded only this directory" buys you.

---

## What independent review caught

Evidence for rule 3 from the other direction: the supervisor's review found things
the agent did not report or did not know to look for.

- **DEFECT-1** (2026-10-15). Repositories decoding Postgres ENUM columns into
  `String` fields failed against the schema. Pre-existing, found by an agent
  attempt. Ratified as D20, fixed as a bounded packet.
- **DEFECT-2** (2026-10-15). A workspace-scoping method did not rebind two
  repositories. Found by PM review, disposed as a blocking rider on the next
  packet, fixed first on its own commit.
- **DEFECT-3** (2026-10-16). A policy-evaluation route returned 500 for every
  tenant because it minted an event referencing a row it never inserted.
  Confirmed by PM code read, not taken on the agent's report. Pre-existing,
  structural, parked for a caller audit.
- **INV-2** (2026-10-16). An older approval surface took the approver identity
  from a client-supplied body field and had no step-up check. Not introduced by the
  packet, but made reachable by it. Found by PM review.
- **GATE-1** (2026-10-15). A migration-only change did not re-expand a compile-time
  embed, so a prior receipt was green against a stale migration set. Ratified as
  D18, fixed as PKT-004 with a `build.rs` rerun-if-changed and a structural test
  with a negative control.
- **RED-1** (2026-10-15). The first independent gate on a fresh database found
  main red: two test seed helpers inserting into tenanted tables without a tenant
  id. No production path failed. Fixed as PKT-003.
- **The PKT-002b scope question** (2026-10-16). The agent widened a factory beyond
  the packet and relocated it to a different crate. Two independent PM reviews
  concluded the widening was required by the governing decision rather than
  convenient, and the relocation was the only placement that did not invert a crate
  dependency. Ratified: the packet was wrong, not the agent. Produced D24's
  amendment that an unimplementable packet is a defect in the packet.

---

## DEFECT-4. The packet asked for what the grant could not deliver, 2026-10-20

**Observed.** PKT-004 made a container image build a required acceptance
criterion. The dispatch granted `cargo`, `git`, `pwsh`, `powershell` and
`gitleaks`. The agent's docker calls were refused by an approval prompt with no
human present. The packet's own fallback clause absorbed the failure, so it read as
an environment limitation rather than a packet defect. The supervisor ran the
build itself, exit 0, rather than merging on an unmet required criterion.

**Produced.** Rule 8. Before dispatching, check every required criterion against
the tool grant. Granting the tool may not be sufficient on its own, since a
capability can still be refused by an approval layer; verify rather than assume.

---

## Substrate findings that generalize

Not rules, but every one of these cost a tick.

- A synchronous connector call times out at about sixty seconds regardless of the
  timeout you pass. Long work must be started as a durable job and polled with
  small log reads. A `Start-Sleep` longer than that occupies the bridge and makes
  the next call time out too.
- The execution runtime refuses PowerShell's `-File` launch flag because it
  bypasses command inspection. The gate is invoked as `-NoProfile -Command`.
- The service account's `PATH` is not the operator's. The agent binary, the secret
  scanner, cargo and docker were all missing until injected via an execution
  profile.
- A legacy `patch_text_file` tool was a full-replace alias and clobbered the cursor
  on tick 8. Whole-file writes only.
- Repositories owned by a different Windows account trip git's ownership check
  under the service identity. `-c safe.directory=<path>` per call.
- The agent's print mode refuses streaming JSON output without `--verbose`.
- Publishing to the remote compares `expected_head` as a literal string, so the
  full 40-character sha is required.
- Pushing main from any automated session was refused by a permission classifier
  twice. The push became operator-owned and the protocol says so, rather than
  letting ticks burn attempts.

---

## Rules to incidents

| Rule | Earned by |
|---|---|
| 1. One dispatcher | D17, and both outages for the corollary |
| 2. Green must name its commit | D22, GATE-1, the three binding failures |
| 3. Review the delivered tip | the three binding failures, DEFECT-2, DEFECT-3, INV-2 |
| 4. One in flight | LOOP-8 |
| 5. Terminal status only | LOOP-5 |
| 6. A lock must be a lock | LOOP-6 and its timestamp rider, LOOP-15 |
| 7. Rulings originate in the ledger | LOOP-9, the LOOP-8 provenance incident, LOOP-4 |
| 8. Criteria covered by grant | DEFECT-4 |
| 9. Nothing waits on a human | D17, the DEC queue, every parked item |
| 10. Model matches blast radius | LOOP-3, the digest cadence incident |
| 11. Instruction files are attended-only | LOOP-13, LOOP-14, and LOOP-9 for why the prompt is not the alternative |
