# Swap points

Everything in this repo is written against one reference implementation: a Rust
workspace on Windows, dispatching Claude Code through a governed MCP execution
runtime, scheduled by Claude scheduled tasks. None of those four choices is load
bearing. This file is the list of what you change, what the reference uses, and
what breaks if you get it wrong.

Read `README.md` first for the eleven rules. Those are **not** swap points. They are
the method. If a substrate makes one of them impossible, that is a finding about
the substrate, not permission to drop the rule.

---

## The ten values

Fill these in before you copy anything. Everything else derives from them.

| # | Value | Reference implementation |
|---|---|---|
| 1 | Repo root and loop home | `D:\dev\<project>`, loop files under `ops/pm/` |
| 2 | Gate command and step list | `scripts/gate.ps1`, 13 blocking steps plus 1 advisory |
| 3 | Receipts directory (the binding exclusion) | `docs/gate-receipts/` |
| 4 | Execution substrate | nMCP `execute_start` on Windows, service account `NT SERVICE\nMCP` |
| 5 | Agent invocation and capability grant | `claude -p … --allowedTools Bash(cargo:*) …` |
| 6 | Scheduler | Claude scheduled tasks, hourly gatekeeper, supervisor fired on demand with a sparse backstop; none of the three triggers bound to the machine |
| 7 | Exclusive resources the gate needs | one Postgres instance via `TEST_DATABASE_URL` |
| 8 | Decision ledger path | `docs/DECISIONS.md`, append only, gated |
| 9 | Registry file and status publish target | `docs/engineering-spec/tracker.json` seeds the plan of record; the page publishes as a claude.ai artifact the status task republishes |
| 10 | Model tier per role | strongest for the supervisor and decision session, cheapest adequate for gatekeeper and watchdogs, cheap for status, mid-tier for coding agents |

---

## 1. Repo root and loop home

The loop needs a home inside the target repo and a branch convention. The
reference puts everything under `ops/pm/` and uses a split bus: the cursor lives
on its own long-lived branch in a dedicated worktree, and every other loop file is
authoritative on `main` and written only on a packet branch that merges under the
gate.

**Why the split.** The cursor changes every tick and must never cost a gate run.
Everything else is a record and must never change without one. Collapsing them
means either ungated writes to your record or a fourteen-minute gate for a
bookkeeping line.

**If you skip it:** you will quietly start editing the record in a working tree,
and three ratified decisions will sit uncommitted for a day. That happened here.

**Failure mode to avoid:** do not give the main branch a permanent worktree. The
merge path is a fast-forward fetch into main, and git refuses that while main is
checked out anywhere. Temporary worktrees for verification are fine; remove them in
the same run.

---

## 2. Gate command and step list

The gate is the only thing standing between agent output and your main branch. It
must be runnable unattended, from a clean checkout, by the same account the
supervisor runs as.

| Stack | Plausible step list |
|---|---|
| Rust | `fmt --check`, `check`, `test --workspace --all-features`, `clippy -D warnings`, `doc` with `RUSTDOCFLAGS=-D warnings` |
| Python | `ruff check`, `ruff format --check`, `mypy`, `pytest`, a packaging build |
| Node / TS | `tsc --noEmit`, `eslint --max-warnings 0`, `vitest run`, `build` |
| Any | secret scanning, dependency advisory scan, container build if you ship images |

**Blocking versus advisory.** Separate them explicitly and record both. The
reference runs a dependency advisory scan as advisory, which was correct, and then
let it fail on every receipt for eleven runs until someone noticed it had become
background noise. An advisory step that always fails trains the reader to skip it,
and the next advisory that matters arrives in a channel nobody reads. Either fix the
advisory or record a dated acceptance of it.

**Requirement:** the gate must fail closed. If a precondition is missing, it fails
rather than skipping. A gate that silently skips its database tests because a
variable is unset is worse than no gate.

---

## 3. Receipts directory

One directory, excluded from the binding hash, holding one receipt per gate run.
The exclusion is what lets you commit the receipt without changing what it binds.

Exclude **only** this directory. The reference excludes `docs/gate-receipts/` and
nothing else, and that precision is what let a later run prove by recomputation
that a receipt still bound `main` after the receipt commit landed. Widen the
exclusion and you lose that property silently.

---

## 4. Execution substrate

How the supervisor runs commands on the machine that holds the repo. This is the
single biggest variation between deployments and the place every first-time setup
stalls.

| Substrate | Notes |
|---|---|
| Governed MCP runtime (reference) | Policy-gated roots, credential references, execution profiles. Strongest audit story. Most setup. |
| Direct local shell | Simplest. No credential brokering, no policy layer. Fine for a single-operator project. |
| SSH to a build host | Works. Watch command timeouts and non-interactive environment differences. |
| CI runner | Gate runs for free and in isolation. Dispatch and harvest need somewhere else to live. |

**Things the reference learned the hard way, which generalize:**

- The service account's `PATH` is not your `PATH`. Resolve tool paths explicitly or
  inject them into an execution profile. Expect `cargo`, the agent binary, the
  secret scanner and the container CLI to all be missing.
- Long commands need a durable job model. A synchronous call through a connector
  will hit a request timeout, often around sixty seconds, no matter what timeout
  you pass. Start the job, poll it, read its log tail.
- Some substrates refuse flags that defeat command inspection. The reference cannot
  pass PowerShell's `-File` and invokes the gate as `-NoProfile -Command ./gate.ps1`.
- Repositories owned by a different user trip git's ownership check. Pass
  `-c safe.directory=<path>` per invocation rather than editing global config.
- A push that works in your terminal proves nothing about the unattended path.
  Your shell has a credential helper; the service account does not, and a governed
  publish call that takes a credential reference will default to sending none. The
  symptom is `could not read Username for 'https://...': terminal prompts disabled`,
  which reads like a configuration fault and is actually an unauthenticated call.
  Bind the credential by reference on every publish, and resolve each remote its own
  scoped credential rather than assuming one token covers every repository the loop
  touches. Diagnose this before concluding a token lacks permission: an unrelated
  403 on the same remote sent the reference implementation after a non-existent
  token-scope problem for a day.

---

## 5. Agent invocation and capability grant

Three parts: the binary and flags, the credential, and the tool grant.

**Flags.** Use a streaming output format so a killed agent still leaves a partial
trail on disk. The reference learned this from a job that buffered its entire result
to exit, died before exiting, and left two zero-byte logs. Its work survived only
because the packet required committing every green step.

**Credential.** Pass a reference, never a value. The reference uses
`nmcp://secret/<name>` resolved by the runtime at call time, never appearing in
arguments or logs. Note that the credential for dispatching the agent is a different
secret from the one for publishing to a remote, and binding rules that admit one
will refuse the other.

**Grant.** Scope the tools to what the packet actually needs. Then check, before
dispatching, that every required acceptance criterion is achievable with the grant
you are about to pass. Rule 8 exists because a packet demanded a container build
proof from an agent with no container tool, and the packet's own fallback clause
absorbed the failure so it read as an environment limit rather than a packet defect.

**Also note:** granting the tool may not be sufficient. A capability can still be
refused by an approval layer with no human present. Verify rather than assume.

---

## 6. Scheduler

Whatever fires the supervisor on a cadence. Four things it must give you:

1. A reliable cadence.
2. A record of each run's outcome, readable from somewhere other than the machine
   being watched.
3. A way to fire on demand.
4. Notification on a run that reports something.

**Cadence.** Hourly suits a loop where packets take fifteen to thirty minutes and
gates take fifteen to twenty-five. Slowing that cadence to save budget is the wrong
lever: it doubles the window in which finished work sits unharvested, which is the
expensive thing, and it buys the saving precisely on the ticks that had work to do.

What is true is that most ticks are quiet, and a quiet tick on the strongest
available model is the loop's largest recurring cost. The answer is to keep the
hourly cadence and make the hourly thing cheap: a gatekeeper on the cheapest
adequate tier reads the cursor and the lock, fires the supervisor when there is
work, and exits otherwise (GAL-D31). The supervisor keeps a sparse self-schedule as
a backstop so a dead gatekeeper degrades the loop to slow rather than to silent.

**Do not arm that shape first.** The gatekeeper's fire path proves itself the moment
there is work. Its SKIP path only exercises once the queue genuinely empties or
blocks, and that is the path that can stop the loop. Run the supervisor hourly
alongside the gatekeeper until all three of GAL-D35's preconditions hold, read
back from the scheduler's own task record: the skip path has been observed, the
gatekeeper runs with automatic approval, and it carries no device binding. The
reference ran a gatekeeper without automatic approval for a day and nothing
noticed, because the hourly supervisor hid it; the next day device absence
disabled the gatekeeper and the supervisor together. The mutex makes the overlap
safe: the second caller loses the compare-and-swap and exits.

**The gatekeeper judges the determination, not the state name.** It skips only
when the cursor's queue field carries the supervisor's own fresh statement that
nothing is dispatchable, empty or blocked, and fires on everything else. The
reference's first gatekeeper matched the string idle, the ledger introduced
idle-blocked the same day, and a blocked loop fired the supervisor hourly
(GAL-D34). Any rule in a cheap reader that names a state is a rule the next
ledger entry can silently invalidate.

**The failure to design against.** The reference scheduler auto-disables a
device-bound task when its machine is unreachable at a firing. A laptop asleep at
the wrong minute stopped the only dispatcher three times, the third time taking
the gatekeeper and the decision session with it in eleven minutes while a
cloud-only task kept running. The answer is not a better watchdog. No trigger of
the supervisor is bound to the machine (GAL-D33): the gatekeeper, the supervisor
and the decision session run unbound and reach the repository through the
execution substrate, and a run that finds the machine asleep ends in one line.
That needs a substrate reachable from the cloud, which the reference substrate
is. If yours is a shell on the machine and nothing else, the binding is
unavoidable; record it as a known weakness, keep the supervisor on its hourly
schedule, and understand that the cloud watchdog is your only cover.

---

## 7. Exclusive resources

Any resource your gate needs exclusive access to is the real reason for rule 4.

The reference gate runs integration tests against a single Postgres instance. A
migration advisory lock serialises the migration but does not isolate test data, so
two concurrent gate runs interleave fixtures and both greens become untrustworthy.
One in flight at a time is the cheap answer. Per-run database isolation is the
expensive answer and the only one that buys you real concurrency.

Inventory this before you consider parallelism: databases, ports, container names,
build caches, target directories, lockfiles.

---

## 8. Decision ledger

Append-only, lives in the repo, merges under the gate. This is the only place a
ruling may originate.

Record for each decision: the identifier, the date, who decided, the question, the
options considered, the disposition, and the reasoning. When a decision corrects an
earlier one, append a correction rather than editing the original. An audit trail
that gets rewritten is not one.

---

## The watchdog layer

Not one of the ten, because it is not optional and it is not a parameter.

The supervisor is the only dispatcher, so when it stops, everything stops. It
cannot detect its own absence. You need at least one observer that is not the
supervisor, and at least one of those observers must not depend on the same machine
the supervisor depends on, or you have simply duplicated the failure.

**Watch whatever runs hourly.** With a gatekeeper in front (section 6), that is the
gatekeeper, and the supervisor's silence between fires is expected rather than
diagnostic. Repoint the watchdogs in the same change that backstops the supervisor.
A watchdog still aimed at a backstopped supervisor reports a healthy loop while a
dead gatekeeper starves it, which is the exact failure the layer exists to catch.

The reference runs two: a device-bound one that reads the cursor and alerts on a
stale timestamp, and a cloud-only one that reads the scheduler's own run records and
alerts on a disabled task, a suspension, a failed run or a stale run. The second is
the important one, because the scheduler's record is written by a third party and
is therefore sound in a way a self-published heartbeat never is. Same reasoning as
rule 5.

**Scheduler health is the check the repository cannot make.** A disabled
scheduled task leaves no trace in the tree or the cursor. When something is
reported broken, read the scheduler's task records before probing the tree, and
have the cloud watchdog read every loop task rather than only the supervisor:
the reference's attended supervisor probed a healthy tree four times during a
live outage that had disabled three tasks. It is also the only check that still
works when the machine is unreachable, which is the moment it matters.

Make them read-only and alert-only unless you have deliberately decided otherwise.
A watchdog that repairs things is a second actor in a system whose whole premise is
that there is exactly one.

Nothing watches the outermost watchdog. Say so in its own alerts rather than
implying coverage you do not have, and stop the regress there on purpose.

---

## 9. Registry file and status publish target

The plan of record (`plan.json`) is seeded from whatever structured registry the
project already keeps (`{{SP:9:REGISTRY_FILE}}`) plus the build-state file's prose,
with every disagreement between them recorded on the unit, never resolved by a
script. The status page publishes to `{{STATUS_ARTIFACT_URL}}`; the status task
republishes the same artifact with a fresh snapshot beside it. Swap the registry
format in the seeding step and the publish target in the prompt. The snapshot's
`ThroughputWindowStart` is the date the capacity model last changed and
`LastDeployCommit` is the last recorded deploy on main; both are parameters.

**What breaks if you get it wrong.** A registry that is not under the gate gives
the page numbers nothing can audit. A publish target that the task creates fresh
each run scatters the history across artifacts; the task republishes one URL.

---

## 10. Model tier per role

The loop runs several scheduled roles and they do not need the same capability.
Getting this wrong in either direction is expensive, so it is a swap point rather
than a default.

What the reference project settled on, and why:

- **Supervisor: the strongest model available.** It reviews returned code
  invariants-first, probes the tree before cutting scope, and makes the merge
  decision. This is the judgment the method depends on. Its probes have caught a
  genuine security defect and a dependency trap that would each have cost more
  than the model difference.
- **Decision session: strong.** It rules architecture under the standing
  delegation, and a bad ruling compounds because later packets are cut from it.
- **Gatekeeper and watchdogs: the cheapest adequate model.** They read a few
  fields and compare values. There is no judgment to buy.
- **Status task: cheap.** Every figure comes from a deterministic script and the
  validator fails closed, so the model orchestrates and writes a short narrative.
- **Coding agents: mid-tier.** The supervisor has already done the probing,
  scoping, file lists and acceptance criteria. The agent executes a tightly
  specified packet, which is a different and lesser task than writing one.

The trap to avoid is uniform downgrading when the bill arrives. The cost is
dominated by how often the expensive role runs, not by its tier, so the lever is
cadence proportional to work (GAL-D31) and not the model list. See METHOD section
15.

One substrate note: on some platforms a scheduled task bound to a specific machine
cannot have its model changed through the API and must be edited by hand in the
host application. Check this before planning a tier change you cannot execute.

## Things that are not swap points

- The eleven rules in `README.md`.
- The binding rule. You may change which directory is excluded. You may not stop
  binding, and you may not widen the exclusion for convenience.
- Independent re-gating of the delivered tip. The agent's receipt is a claim.
- Terminal status as the only liveness signal.
- Compare-and-swap for the mutex.
- The ledger as the sole origin of rulings.

If your substrate makes one of these impossible, record it as a known weakness with
its cost, the way `docs/FAILURE-LOG.md` does. Do not quietly drop it. The value of
this method is entirely in the parts that do not bend.
