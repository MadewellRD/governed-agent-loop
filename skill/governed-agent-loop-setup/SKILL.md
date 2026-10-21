---
name: governed-agent-loop-setup
description: Arm a Governed Agent Loop (GAL) in a target repository: ask the eight swap-point questions, parameterize the kit, run setup-loop, create the four scheduled tasks, write the first packet, verify. Use when the user wants an unattended supervisor-plus-coding-agent loop set up for a project, or says "set up the loop", "arm GAL", "governed agent loop for <repo>".
---

# Governed Agent Loop setup

You are arming a supervisory control loop in someone's repository. The loop
is: a scheduled supervisor tick that reads one cursor, harvests the last
agent's delivered commit, reviews it at the delivered tip against a gate
receipt bound to that tip, merges or rejects, and dispatches exactly one new
packet; a daily decision digest; and two watchdogs. The kit you are
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

## Step 1: the eight swap-point questions

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
   `{{SP:4:SERVICE_ACCOUNT}}`). How does the supervisor run a long command and
   poll it? Which account does it run as? The reference is a governed MCP
   execution runtime under a Windows service account. If the answer is "the
   shell in my scheduled task", record that and note that liveness must still
   key on terminal status, not pid.
5. **Agent invocation and grant** (`{{SP:5:AGENT_BIN}}`,
   `{{SP:5:AGENT_TOOL_GRANT}}`, `{{SP:5:AGENT_CREDENTIAL}}`,
   `{{SP:5:AGENT_TIMEOUT_MS}}`). Which coding agent, which model (ask the user
   to name it; do not pick), which tool allowlist, which credential reference,
   what timeout. The grant must cover the gate command or the agent cannot
   self-gate (rule nine).
6. **Scheduler** (`{{TICK_TASK_NAME}}`, `{{DEVICE_WATCHDOG_TASK_NAME}}`).
   Default: Claude scheduled tasks, tick hourly, digest daily, device watchdog
   every 4h, cloud watchdog every 6h. Confirm cadences and the user's time zone.
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
`{{LIVENESS_GRACE_MINUTES}}` (240), `{{WATCHDOG_STALE_HOURS}}` (3),
`{{CLOUD_WATCHDOG_STALE_HOURS}}` (8). Defaults in parentheses are the reference
values and are fine for a first loop.

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

## Step 4: the four scheduled tasks

Create them with the scheduled-task tools (never a local cron). Each prompt is
the corresponding resolved file from `prompts/`. The tick and device watchdog
require the user's computer; the digest requires it too in the reference (it
reads the repo); the cloud watchdog does not and must not (its value is that it
runs when the computer is asleep).

| Task | Cadence | Requires computer | Prompt |
|---|---|---|---|
| `{{TICK_TASK_NAME}}` | hourly, off the hour | yes | `tick.prompt.md` |
| digest | daily, user's evening | yes | `digest.prompt.md` |
| `{{DEVICE_WATCHDOG_TASK_NAME}}` | every 4h | yes | `watchdog-device.prompt.md` |
| cloud watchdog | every 6h | no | `watchdog-cloud.prompt.md` |

Model: ask the user to name the model for each. A device-bound task carries its
model in a signed session request and cannot be changed afterwards through the
API, so get it right at creation. The reference runs tick and digest on the
strongest model and watchdogs on the cheapest that can read a run record.

After creation, list the tasks and read back each one's cron, requires-device
flag, and permission mode. Report them in a table. Do not fire the tick.

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
- The four tasks exist with the expected cadences and device flags.
- The supervisor commit identity differs from the operator's.
- No `{{` tokens remain outside the permitted set.
- No credential value appears in any committed file or any task prompt
  (grep for the credential reference name and confirm only the reference
  appears).

If any item fails, the loop is not armed. Say which, and what the fix is. When
all pass, tell the user the time of the first scheduled tick and that the
first handoff will appear in `<loop home>/PM-HANDOFF.md` on the loop branch.
Do not summarize the method; point them at the kit's `docs/METHOD.md`.
