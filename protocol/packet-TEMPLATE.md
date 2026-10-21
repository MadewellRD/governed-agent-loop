# PKT-{{NNN}}: {{one-line title}}

<!--
A packet is one bounded unit of work. Small enough to review in one sitting and
to gate once. If either would take longer, split it. Every section below is
required; "N/A" is an acceptable value, an absent section is not.

Delete these comments when the packet is cut.
-->

**Branch:** `{{type}}/{{short-slug}}` cut from `{{SP:1:MAIN}}` at `{{sha}}`
**Worktree:** `.worktrees/agent-PKT-{{NNN}}`
**Authorising decision(s):** {{GAL-Dnn or project Dnn}}
**Dispatched:** {{host-clock timestamp, filled by the supervisor}}
**Attempt:** {{1}}

---

## Scope

{{What this packet does, in two or three sentences. State the outcome, not the
steps.}}

**Exact paths in scope:**

- `{{path/one}}`
- `{{path/two}}`

**Explicitly out of scope:**

- {{Anything adjacent that a reasonable agent might touch and must not.}}
- {{Anything the authorising decision considered and deferred.}}

If completing the work requires touching a path outside the list above, that is
a HALT condition (see below), not a judgment call.

---

## Invariants in force

{{The product's hard invariants that this change could affect. Copy them in full
from the governance document; do not reference them by number. The agent must be
able to check its work against the text.}}

1. {{invariant}}
2. {{invariant}}

Any change that would violate one of these is a reject on review regardless of
whether the acceptance criteria pass. Do not implement a workaround; HALT.

---

## Acceptance criteria

Each criterion is REQUIRED unless marked ADVISORY. Each names how it is proven.

**Tool coverage:** every REQUIRED criterion below is achievable with the dispatch
grant `{{SP:5:AGENT_TOOL_GRANT}}`. If a criterion needs a program not in that
grant, the supervisor either extends the grant for this dispatch or marks the
criterion ADVISORY before dispatching. An agent that finds itself unable to
satisfy a REQUIRED criterion for lack of a tool must HALT, not improvise, and
must say which tool.

- **A1 (REQUIRED).** {{criterion}} Proven by: {{test, command, or inspection}}.
- **A2 (REQUIRED).** {{criterion}} Proven by: {{...}}.
- **A3 (REQUIRED, negative control).** {{A test that FAILS when the change is
  absent or reverted, proving the test is load-bearing.}} Proven by: running it
  against the pre-change tree and observing the failure, then against the
  post-change tree and observing the pass. Record both outcomes in the receipt.
- **A4 (ADVISORY).** {{criterion}} Proven by: {{...}}.

---

## Required tests

- The full gate: `{{SP:2:GATE_CMD}}`, run from the branch tip, all blocking steps
  green.
- The negative control in A3, with both outcomes recorded.
- {{Any focused per-crate or per-module suite the change touches.}}
- Secret scan clean on the diff.

The gate receipt is written to `{{SP:3:RECEIPTS_DIR}}` and committed as its own
commit after the code commit, so the gate runs against the committed code. Note
that the receipt binds the tree at the moment the gate ran; the supervisor will
re-gate the delivered tip independently regardless.

---

## Halt conditions

A HALT is an instruction, not a suggestion. On any of these: stop implementing,
write a halted receipt stating which condition and what was observed, commit it,
and end. Do not end with a question. Do not improvise around it.

- A change outside the exact paths in scope is needed.
- A REQUIRED criterion cannot be satisfied with the granted tools.
- An invariant in force would be violated by any available implementation.
- {{Packet-specific halt: e.g. "the dependency bump turns out not to be
  lockfile-only"; "the schema change requires a migration"; "the test database
  is unreachable".}}
- The packet contradicts itself. Say where.

---

## Working rules

- **Commit every green micro-step as you go.** A previous agent run died before
  it could report, and its commits were the only evidence that survived. Work
  that is not committed does not exist.
- Never run `git checkout`, `restore`, `reset`, `clean`, `stash`, or any force
  push. The harness denies them; do not attempt them.
- Read `CLAUDE.md` (or the project's agent ground-rules file) first.
- Scratch files may live untracked inside the worktree. Delete them before the
  gate-of-record run. Never commit them.
- Do not push. The supervisor merges; the operator pushes.
- Your final message is a report, not a conversation. State what you did, what
  you did not do and why, every deviation from this packet with its reason, and
  the receipt id.

---

## Receipt

On completion, `{{SP:1:LOOP_HOME}}/receipts/PKT-{{NNN}}.json` with: status
(`complete` or `halted`), the halt condition if any, each acceptance criterion with
its outcome and evidence, the negative-control outcomes, the gate receipt id, any
deviation from the packet with reason, and anything you found that was out of
scope and left alone.

---

<!-- Supervisor fills below at harvest. -->

## Amendments

{{Dated amendments the supervisor made to this packet under GAL-D06, if any.
Narrowing only. Each with date, what changed, and why.}}

## Harvest

{{Job id, terminal status, exit code, duration, delivered tip, agent receipt id and
whether it bound the tip, independent gate receipt id, verdict, merge sha.}}
