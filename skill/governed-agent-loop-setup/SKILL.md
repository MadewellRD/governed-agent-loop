---
name: governed-agent-loop-setup
description: Arm a Governed Agent Loop (GAL) in a target repository: ask the ten swap-point questions, parameterize the kit, run setup-loop, create the six scheduled tasks, write the first packet, verify. Use when the user wants an unattended supervisor-plus-coding-agent loop set up for a project, or says "set up the loop", "arm GAL", "governed agent loop for <repo>".
---

# Governed Agent Loop setup

You are arming a supervisory control loop in someone's repository. The loop
is: a scheduled supervisor tick that reads one cursor, harvests the last
agent's delivered commit, reviews it at the delivered tip against a gate
receipt bound to that tip, merges or rejects, and dispatches exactly one new
packet; a cheap gatekeeper in front of it; a daily decision digest; two
watchdogs; and a status task. The kit you are
parameterizing lives in the `governed-agent-loop` repository. Read its
`README.md` (the eleven rules) and `SWAP-POINTS.md` before asking anything. The
eleven rules are not configurable. If a substrate makes one impossible, stop and
report that; do not drop the rule.

Hard constraints on you during setup:

- Never put a credential, token, or connection string into a prompt, a script,
  a cursor, or a chat message. Credentials are passed by reference only
  (`{{SP:5:AGENT_CREDENTIAL}}` is a reference name, never a value).
- Never check out the target repo's main branch in the supervisor worktree.
  `setup-loop` refuses to run from main; do not work around that.
- Never hand-run the tick protocol to "get it started". The first scheduled
  tick starts the loop. A hand-run tick is an untraceable actor.
- Never write a ruling into a stored prompt or a handoff. Rulings originate in
  the decision ledger (GAL-D07). If the user decides something during setup
  that is a loop decision, record it as a ledger entry, then reference it.
- If any tool call is denied by a permission or policy layer, stop and report.
  Do not find another route.
- Do not change a scheduled task's model unless the user says the model name
  in their own words.

## Step 0: locate the kit and the target

Find the kit: ask for its path if not obvious (default `D:\dev\governed-agent-loop`
on the reference machine; otherwise a clone of the published repo). Confirm it
contains `protocol/pm-tick.md`, `scripts/setup-loop.template.ps1`,
`scripts/gate.template.ps1`, and `prompts/`. Find the target repo: it must be
an existing git repository with an authoritative product branch. Record both
absolute paths. Do not proceed on a repo with no commits.

## Step 1: the ten swap-point questions

Ask with the question tool, grouped so the user answers in at most three
rounds. Offer the reference value as the recommended default where it is
portable. For each, the token names you will resolve are listed.

1. **Repo root and loop home** (`{{SP:1:REPO_ROOT}}`, `{{SP:1:LOOP_HOME}}`,
   `{{SP:1:MAIN}}`, `{{SP:1:CURSOR_BRANCH}}`, `{{SP:1:CURSOR_WORKTREE}}`).
   Defaults: loop home `ops/pm`, main `main`, cursor branch `ops/pm-loop`,
   worktree `.worktrees/pm-setup`. Ask only for main's name and whether the
   defaults are acceptable.
2. **Gate command and step list** (`{{SP:2:GATE_CMD}}`). What is the
   validation suite? Ask for the exact commands and which are blocking versus
   advisory. Default invocation `pwsh -NoProfile -Command ./scripts/gate.ps1`.
   These fill the SWAP 2 block of `gate.template.ps1`.
3. **Receipts directory** (`{{SP:3:RECEIPTS_DIR}}`). Default
   `docs/gate-receipts/`. This is the only binding exclusion; say so.
4. **Execution substrate** (`{{SP:4:EXEC_START}}`, `{{SP:4:EXEC_STATUS}}`,
   `{{SP:4:SERVICE_ACCOUNT}}`, `{{SP:4:PUBLISH_CREDENTIAL}}`). How does the
   supervisor run a long command and poll it? Which account does it run as?
   Which credential reference does the governed publish use (GAL-D18; a
   different secret from the agent's)? Is the substrate reachable from the
   cloud, or only from a shell on the machine? The reference is a governed MCP
   execution runtime under a Windows service account, reachable from the cloud.
   If the answer is "the shell in my scheduled task", record that, note that
   liveness must still key on terminal status, not pid, and note that every
   trigger of the supervisor will then be device-bound (GAL-D33), which is a
   known weakness to write into the target's ledger and a reason the gatekeeper
   cutover in step 4 is not available.
5. **Agent invocation and grant** (`{{SP:5:AGENT_BIN}}`,
   `{{SP:5:AGENT_TOOL_GRANT}}`, `{{SP:5:AGENT_CREDENTIAL}}`,
   `{{SP:5:AGENT_TIMEOUT_MS}}`). Which coding agent, which model (ask the user
   to name it; do not pick), which tool allowlist, which credential reference,
   what timeout. The grant must cover the gate command or the agent cannot
   self-gate (rule 8).
6. **Scheduler** (`{{TICK_TASK_NAME}}`, `{{GATEKEEPER_TASK_NAME}}`,
   `{{DEVICE_WATCHDOG_TASK_NAME}}`, `{{STATUS_TASK_NAME}}`,
   `{{TICK_BACKSTOP_CRON}}`). Default: Claude scheduled tasks, gatekeeper
   hourly, supervisor fired by the gatekeeper with a sparse self-schedule as a
   backstop (`0 */6 * * *`), decision session daily (every 4h once a standing
   delegation exists, see step 4), device watchdog every
   4h, cloud watchdog every 6h, status every 2h. Confirm cadences and the
   user's time zone. Offset the gatekeeper a few minutes ahead of the
   supervisor's backstop so the two do not collide on the same minute.

   Also collect a MODEL TIER for each of the six tasks (swap point 10). Ask the
   user to name each model; never pick one. The reference assignment, with
   reasons, is in `SWAP-POINTS.md`: strongest for the supervisor and the
   decision session, cheapest adequate for the gatekeeper and both watchdogs,
   cheap for status. A device-bound task carries its model in a signed session
   request and cannot be changed through the API afterwards, so this is a
   create-time decision, not a tuning knob.
7. **Exclusive resources** (`{{SP:7:EXCLUSIVE_RESOURCES}}`). What does the
   gate need exactly one of (a database, a port, a container daemon)? Each one
   becomes a fail-closed precondition in SWAP 7 and a reason the tick runs one
   packet at a time.
8. **Decision ledger** (`{{SP:8:LEDGER_PATH}}`, `{{SP:8:DEC_QUEUE_PATH}}`).
   Defaults `docs/DECISIONS.md` and `<loop home>/DEC-PENDING.md`.

Also collect the unnumbered values: `{{PROJECT_NAME}}`, `{{PM_IDENTITY}}`
(the supervisor's commit identity, distinct from the operator's),
`{{PRODUCT_INVARIANTS}}` (the product's hard invariants, pasted or pointed at),
`{{AGENT_RULES_FILE}}` (CLAUDE.md or equivalent), `{{PROJECT_STATE_FILE}}`,
`{{BUILD_STATE_FILE}}`, and the timing values `{{LOCK_STALE_MINUTES}}` (50),
`{{LIVENESS_GRACE_MINUTES}}` (10), `{{WATCHDOG_STALE_HOURS}}` (3),
`{{CLOUD_WATCHDOG_STALE_HOURS}}` (8). Defaults in parentheses are the reference
values and are fine for a first loop.

For the status plane (GAL-D17), also collect: `{{SP:9:REGISTRY_FILE}}` (the
project's structured registry that seeds `plan.json`, or none),
`{{THROUGHPUT_WINDOW_START}}` (the date the capacity model last changed; the
first dispatch if unknown), `{{LAST_DEPLOY_COMMIT}}` (the last recorded deploy on
main), `{{STATUS_TASK_NAME}}` and, after the first hand publish of the page,
`{{STATUS_ARTIFACT_URL}}`. The page is published once by hand with a seed snapshot
before the status task exists, so the task has a URL to republish.

## Step 2: parameterize

Copy from the kit into the target repo, resolving every `{{...}}` token above
in the copy. Nothing in the kit is edited. Destinations:

| Kit | Target |
|---|---|
| `protocol/pm-tick.md` | `<loop home>/pm-tick.md` (setup-loop copies it; resolve first) |
| `protocol/packet-TEMPLATE.md` | `<loop home>/packet-TEMPLATE.md` |
| `protocol/*.schema.json` | `<loop home>/schema/` |
| `scripts/gate.template.ps1` | `scripts/gate.ps1`, SWAP 2 and SWAP 7 blocks filled |
| `scripts/setup-loop.template.ps1` | `scripts/setup-loop.ps1` |
| `prompts/*.prompt.md` | not copied into the repo; they become scheduled task prompts |
| `prompts/agent-dispatch.md` | `<loop home>/agent-dispatch.md` |

After resolving, grep every copied file for `\{\{[A-Z_:0-9]+\}\}`. The only
permitted survivors are the per-packet tokens in `packet-TEMPLATE.md` and
`agent-dispatch.md` (`{{NNN}}`, `{{sha}}`, `{{type}}`, `{{criterion}}`,
`{{invariant}}`, `{{1}}`) and the legend line in `pm-tick.md`. Anything else
unresolved is a setup failure; fix it before step 3.

Do not edit the binding block of `gate.ps1`. If the user's receipts directory
differs from the default, pass it as the `-ReceiptsDir` parameter; the block
itself stays byte-identical to the kit.

## Step 3: run setup-loop

From the target repo root, on a non-main branch, under the account the
supervisor will run as:

    pwsh -NoProfile -Command ./scripts/setup-loop.ps1 -ProjectName "<name>" [-MainBranch ...] [-LoopBranch ...] [-ReceiptsDir ...] [-OpsDir ...]

It is idempotent. Read its output. It must end with `all loop paths present`,
`no unresolved placeholders in protocol`, and a commit on the loop branch, or a
`skip nothing to commit` on a re-run. If it prints a warning about unresolved
placeholders, go back to step 2. If it fails a precondition, report the exact
line and stop.

## Step 4: the six scheduled tasks

Create them with the scheduled-task tools (never a local cron). Each prompt is
the corresponding resolved file from `prompts/`. Reading the repository does
not require binding a task to the computer: where the execution substrate is
reachable from the cloud, the task reaches the repository through it, and a run
that finds the machine asleep ends in one line. A task that IS bound to the
computer is a task the scheduler can switch off when the machine is unreachable,
and the reference lost its gatekeeper, supervisor and decision session that way
in eleven minutes. So no trigger of the supervisor is bound (GAL-D33). The
device watchdog is bound by definition, since the machine is what it watches,
and the status task may be.

| Task | Cadence | Computer | Approval | Tier | Prompt |
|---|---|---|---|---|---|
| `{{GATEKEEPER_TASK_NAME}}` | hourly | **no** | automatic | cheapest adequate | `gatekeeper.prompt.md` |
| `{{TICK_TASK_NAME}}` | `{{TICK_BACKSTOP_CRON}}` (see below) | **no** | automatic | strongest | `tick.prompt.md` |
| decision session | daily; every 4h under GAL-D27 | **no** | automatic | strong | `digest.prompt.md` |
| `{{DEVICE_WATCHDOG_TASK_NAME}}` | every 4h | yes | automatic | cheapest adequate | `watchdog-device.prompt.md` |
| cloud watchdog | every 6h | **no** | automatic | cheapest adequate | `watchdog-cloud.prompt.md` |
| `{{STATUS_TASK_NAME}}` | every 2h | yes | automatic | cheap | `status.prompt.md` |

"Computer: no" holds where the substrate is reachable from the cloud. Where it
is not, those three tasks are bound, the binding is recorded in the target's
ledger as a known weakness with the cloud watchdog as its only cover, and step 5
below is not available.

**Arm in this order, and do not shorten it.** The order exists because the
supervisor is the only thing that harvests finished work, and an unproven
gatekeeper in front of it is a single point of failure on the component the
whole loop depends on.

1. Create the supervisor on an HOURLY schedule, not the backstop. The loop must
   work without a gatekeeper first.
2. Create the decision session, both watchdogs and the status task.
3. Create the gatekeeper with automatic approval and no device binding, then
   verify both before its first firing: the approval from the scheduler's task
   record, the binding by the scheduler's own signal. The listing may not
   expose the binding at all (the reference's does not, and its approved-folders
   field is not it; the only signal is the "still requires that computer" line
   a prompt update returns). If the scheduler gives no signal, treat the task
   as bound.
   The reference ran a gatekeeper for a day without automatic approval and
   nothing noticed, because the hourly supervisor hid it; a gatekeeper that
   waits for a human fires when someone is awake, which is when the loop needs
   it least. For at least one full cycle, let both it and the hourly supervisor
   run. They cannot collide: the supervisor's mutex means the second caller
   loses the compare-and-swap and exits quietly. This costs one extra supervisor
   run per hour and buys evidence.
4. Watch for BOTH gatekeeper paths before cutting over. The fire path proves
   itself immediately, because there is work. The SKIP path only exercises once
   the queue genuinely empties or blocks, and it is the one that can stop the
   loop. A gatekeeper that has only ever said yes has not demonstrated it can
   safely say no.
5. Only when all three GAL-D35 preconditions hold, verified against the
   scheduler and not taken from what was asked for (skip path observed,
   automatic approval on, no device binding), move the supervisor to
   `{{TICK_BACKSTOP_CRON}}`. That schedule is a floor, not a cadence: it
   guarantees that a completely dead gatekeeper degrades the loop to slow rather
   than to silent, and it must be shorter than the device watchdog's staleness
   threshold so a stall is still caught. If the gatekeeper is device-bound
   because the substrate forces it, this step never happens: the supervisor
   keeps its hourly schedule and the gatekeeper's skip only saves the sessions
   that lose the mutex.

**The watchdogs watch the hourly component.** Before the cutover that is the
supervisor. After it, it is the GATEKEEPER, because the supervisor is then
expected to be quiet for hours at a time and its silence is no longer evidence
of anything. Repoint them in the same change as the cutover. A watchdog left
pointing at a backstopped supervisor will report a healthy loop while a dead
gatekeeper quietly starves it, which is the exact failure the watchdog layer
exists to catch. Both watchdog prompts carry an amendment section for this.

**On the decision session.** The kit ships `digest.prompt.md`, which recommends
and waits. That is the correct starting shape: a new loop has no track record,
and a standing delegation is earned rather than granted on day one. Arm it
daily as a digest. When the operator grants a standing delegation (GAL-D27),
the same task becomes a decision session that RULES: raise its cadence to every
4h, and amend its prompt so it writes rulings to the ledger on its own carriage
instead of producing recommendations. Until that delegation exists in the
target's own ledger, the task recommends and the loop idles on open questions,
which is the behaviour that motivated GAL-D27 in the first place.

Model: ask the user to name the model for each; never pick one. A device-bound
task carries its model in a signed session request and cannot be patched
through the API afterwards, so get it right at creation. If a tier is wrong
later, the user changes it by hand in the host application.

After creation, list the tasks and read back each one's cron, model and
permission mode, and confirm each one's device binding by the scheduler's own
signal, since a listing may not expose it. Report them in a table. Do not fire
the supervisor by hand.

## Step 5: the first packet

Write `<loop home>/packets/PKT-001.md` from the resolved template with the
user, on a branch cut from main, and merge it to main through the gate (or
have the user do it; the packet is a product-tree artifact and follows the
product's own merge discipline). The first packet should be small: one crate
or module, acceptance criteria provable by the gate, no new exclusive
resources. Its purpose is to prove the loop, not to deliver a feature.

Do not write the packet into the cursor. The tick discovers packets by reading
`<loop home>/packets/` on main.

## Step 6: verification

Before declaring the loop armed, confirm and report each of these with the
evidence you used:

- Every path `pm-tick.md` references exists on the loop branch or on main.
- `gate.ps1` parses (`[Parser]::ParseFile`) and, run in a scratch clone with the
  real steps replaced by `exit 0`, writes a receipt whose `bound_tree_hash`
  equals an independent SHA-256 over the sorted `git ls-files -s` manifest with
  the receipts dir excluded, and whose `binds_commit` is `true`.
- The cursor validates against `loop-state.schema.json` and is at tick 0.
- All six tasks exist with the expected cadences, models and permission modes,
  read back from the scheduler's task records. Every task runs with automatic
  approval. No trigger of the supervisor (gatekeeper, supervisor, decision
  session) is bound to the computer where the substrate allows it, confirmed by
  the scheduler's own binding signal and not inferred from a listing field;
  where the substrate does not allow it, that weakness is already written into
  the target's ledger.
- The supervisor is still on its hourly schedule, not the backstop. The cutover
  is a later, evidence-gated step and is not part of arming.
- The gatekeeper's decision logic has been dry-run by hand against the live
  cursor and against two synthetic cursors: one whose `state` is a name the
  schema does not list and whose `queued` opens with the blocked phrase, which
  must skip; one with a non-null `job_id`, which must fire. The live cursor
  proves today's state; the synthetic ones prove the rule survives the next
  state name the ledger invents (GAL-D34). Record the three verdicts and the two
  fields the gatekeeper read.
- The operator has been told the first diagnostic: when something is reported
  broken, read the scheduler's task list before probing the tree, because a
  disabled task leaves no trace in the repository (LOOP-21).
- The gatekeeper fires the supervisor by the scheduler's fire action and not by
  any other route, and its prompt contains the fail-open rule verbatim.
- The supervisor commit identity differs from the operator's.
- No `{{` tokens remain outside the permitted set.
- No credential value appears in any committed file or any task prompt
  (grep for the credential reference name and confirm only the reference
  appears).

If any item fails, the loop is not armed. Say which, and what the fix is. When
all pass, tell the user the time of the first scheduled tick and that the
first handoff will appear in `<loop home>/PM-HANDOFF.md` on the loop branch.
Do not summarize the method; point them at the kit's `docs/METHOD.md`.
