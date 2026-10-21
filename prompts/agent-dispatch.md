# Agent dispatch contract

How the supervisor starts one headless agent. This is the argument list, the
prompt it carries, the capability grant, and the rules the agent is told. The
supervisor reads this file at step 8 of `protocol/pm-tick.md`.

The reference agent is Claude Code in print mode. The shape generalizes to any
agent that can be launched non-interactively with a prompt, a working directory, a
scoped tool grant, and a streaming output format.

---

## The invocation

Through `{{SP:4:EXEC_START}}`, as a durable job, never a synchronous call:

```
program:      {{SP:5:AGENT_BIN}}
cwd:          {{SP:1:REPO_ROOT}}\.worktrees\agent-PKT-{{NNN}}
credential:   {{SP:5:AGENT_CREDENTIAL}}
timeout_ms:   {{SP:5:AGENT_TIMEOUT_MS}}
args:
  -p "<the prompt below, as one string>"
  --permission-mode acceptEdits
  --allowedTools Bash({{tool-1}}:*)
  --allowedTools Bash({{tool-2}}:*)
  ...                                   one --allowedTools per entry in {{SP:5:AGENT_TOOL_GRANT}}
  --output-format stream-json
  --verbose
```

**Working directory is the packet worktree.** The packet file is already in it.
The agent discovers nothing; it is handed everything.

**The credential is a reference.** `{{SP:5:AGENT_CREDENTIAL}}` is resolved by the
execution runtime at call time and never appears in arguments, logs or the agent's
environment as a literal. It is the agent's own authentication, which is a
different secret from any publish credential; binding rules that admit one will
refuse the other, by tool name and by program name.

**Streaming output, and the flag it needs.** `--output-format stream-json` makes
the agent write incrementally, so a killed agent leaves a partial trail. The
reference agent's print mode refuses that format without `--verbose`; include
both. The alternative, buffered JSON, writes nothing until exit and left two
zero-byte logs on the reference's first orphaned run.

**No `--model` flag by default.** The agent uses its own configured default,
which is independent of the supervisor's model. To pin it, add `--model <id>`
here; that is a gated change to this file, not an edit to the agent's config on
the machine, which is invisible to the repo.

**Timeout.** Four hours is generous for a well-bounded packet; the reference's
packets completed in 16 to 33 minutes. The timeout is the ceiling after which the
supervisor treats a non-terminal job as indeterminate (GAL-D09), not an estimate.

---

## The prompt

One string. Resolve the placeholders.

> You are a coding agent for {{PROJECT_NAME}}. Read
> `{{SP:1:LOOP_HOME}}/packets/PKT-{{NNN}}.md` in this working directory and
> execute it exactly; it is your complete task specification. Read
> `{{AGENT_RULES_FILE}}` first for ground rules.
>
> Commit every green micro-step as you go. A previous agent run on this loop
> died before it could report, and its commits were the only evidence that
> survived. Work that is not committed does not exist.
>
> If you hit a halt condition named in the packet, or anything that would
> require touching a path outside the packet's scope, write the halted receipt
> the packet describes, commit it, and stop. Do not end your run with a
> question. A question is not a receipt and leaves the supervisor nothing to
> harvest.
>
> Do not push. Do not merge. Do not modify the supervisor's files under
> `{{SP:1:LOOP_HOME}}` except the receipt the packet asks for. Your final message
> is a report: what you did, what you did not do and why, every deviation from
> the packet with its reason, and the receipt id.

---

## The capability grant

`{{SP:5:AGENT_TOOL_GRANT}}` is the full list of programs the agent may run. The
reference grant is `cargo`, `git`, `pwsh`, `powershell` and `gitleaks`, which is
everything its gate and its commits need and nothing else.

Scope it to the packet. A packet that needs a container build gets `docker` in
its grant for that dispatch and the supervisor verifies the capability actually
works before dispatching, because a granted tool can still be refused by an
approval layer with no human present (GAL-D11). A packet that does not need it
does not get it.

The grant is also what the supervisor's tool-coverage check compares the
packet's required criteria against. If a criterion is not achievable with the
grant, the packet is defective, not the environment.

**Denied by the harness, not by instruction:** `git checkout`, `restore`,
`reset`, `clean`, `stash`, and any force push. These are enforced at the
permission layer because instructions can be reasoned around and permission
layers cannot (GAL-D12). The prompt tells the agent not to attempt them so it does
not waste a turn finding out.

---

## What the agent is not told

The agent is not told the supervisor's protocol, the ledger, the cursor, or any
decision beyond the ones cited in its packet. It does not need them and they are
not its concern. An agent that knows how the merge works will eventually reason
about whether its work "really needs" the gate. The division of labour is the
design: the agent does the work, the supervisor decides whether the work is
allowed to exist.

---

## Harvest expectations

When the job reaches terminal status, the supervisor expects to find on the
branch: one or more commits, a receipt at
`{{SP:1:LOOP_HOME}}/receipts/PKT-{{NNN}}.json` as its own commit after the code,
and optionally a gate receipt in `{{SP:3:RECEIPTS_DIR}}`. The supervisor will
re-gate the delivered tip regardless of whether the agent's receipt binds it. An
agent run that ends with no commits and no receipt is harvested as a halt without
a receipt, which is a packet-template defect to fix, not an agent failure to
punish.
