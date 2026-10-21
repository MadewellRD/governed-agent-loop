# Failure log

The ten rules in `README.md` were not designed. They were extracted from a week of
running the reference implementation and writing down what broke. This file is the
evidence. Every entry has a date, what was observed, the root cause, and the rule
or decision it produced. Hashes are the reference repository's and are included so
the claims are checkable, not decorative.

The reference implementation is SignalDesk AiTSM: a Rust workspace of about thirty
crates on Windows, dispatching Claude Code headlessly through a governed MCP
execution runtime, supervised by an hourly scheduled task. It went live on
2026-10-15. This log covers 2026-10-15 through 2026-10-20.

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
| 6. A lock must be a lock | LOOP-6 and its timestamp rider |
| 7. Rulings originate in the ledger | LOOP-9, the LOOP-8 provenance incident, LOOP-4 |
| 8. Criteria covered by grant | DEFECT-4 |
| 9. Nothing waits on a human | D17, the DEC queue, every parked item |
| 10. Model matches blast radius | LOOP-3, the digest cadence incident |
