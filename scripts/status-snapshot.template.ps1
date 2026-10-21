<#
.SYNOPSIS
  Deterministic, read-only status snapshot of the {{PROJECT_NAME}} loop and plan.

.DESCRIPTION
  Reads main BY REF (never the operator checkout), the loop cursor on ops/pm-loop,
  the receipts directory, the git log and {{SP:1:LOOP_HOME}}/plan.json, and emits one JSON
  document that the status tracker page renders. No LLM, no network, no writes to
  the repository. Every number carries the sha it was computed from.

  Run from any path inside the repository:
      pwsh -NoProfile -Command ./scripts/status-snapshot.ps1 -Out <file>

  Exit 0 on success, 2 if a precondition fails (not a repo, main unreadable, plan
  missing). A failed run writes nothing.
#>
[CmdletBinding()]
param(
    [string] $Out = 'status-snapshot.json',
    [string] $MainRef = 'main',
    [string] $CursorRef = '{{SP:1:CURSOR_BRANCH}}',
    [string] $ThroughputWindowStart = '{{THROUGHPUT_WINDOW_START}}',  # the date the capacity model last changed (reference: the one-in-flight ruling)
    [string] $LastDeployCommit = '{{LAST_DEPLOY_COMMIT}}'          # the last recorded deploy on main; update at each deploy
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$GeneratorVersion = '1.0.0'

$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { Write-Error 'status-snapshot: not inside a git repository'; exit 2 }
# Work from the common git dir so worktree checkouts never matter; everything below is by ref.
Set-Location $repoRoot

function G { param([string[]]$a) & git @a 2>$null }
function Show($ref, $path) { (G @('show', "${ref}:${path}")) -join "`n" }
function NowZ { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Z([DateTime]$d) { $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function ParseZ([string]$s) { if (-not $s) { return $null }; try { [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)) } catch { $null } }

$mainSha = G @('rev-parse', $MainRef)
if (-not $mainSha) { Write-Error "status-snapshot: ref $MainRef unreadable"; exit 2 }
$originSha = G @('rev-parse', "origin/$MainRef")
$cursorSha = G @('rev-parse', $CursorRef)
$gap = (G @('rev-list', '--left-right', '--count', "origin/${MainRef}...${MainRef}")) -split '\s+'

# ---------------- plan ----------------
$planText = Show $MainRef '{{SP:1:LOOP_HOME}}/plan.json'
if (-not $planText) {
    # Allow a not-yet-merged plan on the current checkout, flagged as such.
    if (Test-Path '{{SP:1:LOOP_HOME}}/plan.json') { $planText = Get-Content '{{SP:1:LOOP_HOME}}/plan.json' -Raw; $planSource = 'working tree (not yet on main)' }
    else { Write-Error 'status-snapshot: {{SP:1:LOOP_HOME}}/plan.json missing'; exit 2 }
} else { $planSource = "main:{{SP:1:LOOP_HOME}}/plan.json" }
$plan = $planText | ConvertFrom-Json
$planBlob = $(if ($planSource -like 'main:*') { G @('rev-parse', "${MainRef}:{{SP:1:LOOP_HOME}}/plan.json") } else { $null })

# ---------------- cursor ----------------
$cursor = (Show $CursorRef '{{SP:1:LOOP_HOME}}/loop-state.json') | ConvertFrom-Json
$lastTick = ParseZ $cursor.last_tick
$lockRef = G @('rev-parse', '--verify', '--quiet', 'refs/pm/tick-lock')
$lockHolder = $null
if ($cursor.lock_history) {
    $open = @($cursor.lock_history | Where-Object { -not $_.released_at })
    if ($open.Count) { $lockHolder = $open[-1].job_id }
    elseif ($lockRef) { $lockHolder = 'held (owner not in cursor; written at release under the pre-D32 form)' }
}
$dispatchedAt = ParseZ $cursor.dispatched_at

# empty-tick streak: consecutive cursor commits from the tip whose subject says quiet
$streak = 0
foreach ($line in (G @('log', $CursorRef, '--format=%s', '-40'))) {
    if ($line -match 'quiet tick|QUIET TICK|no dispatch, no harvest') { $streak++ } elseif ($line -match 'cursor') { break }
}

# ---------------- merge train ----------------
# Source of record: ops/pm/receipts/PKT-*.json on main (the agent's receipt, added to main by the
# fast-forward). A packet counts as merged when its receipt says complete, or when a PM independent
# receipt commit on main names it (covers a receipt left at "halted" by a later successful attempt).
$subjects = @{}
foreach ($line in (G @('log', $MainRef, '--format=%H|%ct|%s', '-600'))) {
    $parts = $line -split '\|', 3
    $subj = $parts[2]
    $m = [regex]::Match($subj, 'PKT-\d+[a-z]?(?:-fix\d)?')
    if ($m.Success -and ($subj -match 'independent' -or $subj -match 'MERGED')) {
        if (-not $subjects.ContainsKey($m.Value)) {
            $rc = [regex]::Match($subj, '\b([0-9a-f]{12})\b')
            $subjects[$m.Value] = @{ sha = $parts[0].Substring(0,12); at = [DateTimeOffset]::FromUnixTimeSeconds([long]$parts[1]).UtcDateTime; pm_receipt = $(if ($rc.Success) { $rc.Groups[1].Value } else { $null }); subject = $subj }
        }
    }
}
$merges = @()
$halted = @()
foreach ($path in (G @('ls-tree', '--name-only', $MainRef, '{{SP:1:LOOP_HOME}}/receipts/'))) {
    if ($path -notmatch '{{SP:1:LOOP_HOME}}/receipts/(PKT-[\w-]+)\.json$') { continue }
    $pkt = $Matches[1]
    try { $r = (Show $MainRef $path) | ConvertFrom-Json } catch { continue }
    $addedLine = (G @('log', $MainRef, '--diff-filter=A', '--format=%H|%ct', '--', $path)) | Select-Object -Last 1
    if (-not $addedLine) { continue }
    $ap = $addedLine -split '\|'
    $completedAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$ap[1]).UtcDateTime
    $pm = $subjects[$pkt]
    $isMerged = ($r.status -eq 'complete') -or ($null -ne $pm)
    $rec = [ordered]@{
        packet = $pkt; status = $r.status; branch = $r.branch
        completed_at = (Z $completedAt); completed_sha = $ap[0].Substring(0,12)
        merged_at = $(if ($pm) { Z $pm.at } else { Z $completedAt })
        merged_sha = $(if ($pm) { $pm.sha } else { $ap[0].Substring(0,12) })
        agent_receipt = $r.gate_receipt; pm_receipt = $(if ($pm) { $pm.pm_receipt } else { $null })
        turnaround_minutes = $(if ($pm) { [Math]::Round(($pm.at - $completedAt).TotalMinutes) } else { $null })
        summary = $(if ($r.summary) { ([string]$r.summary).Substring(0, [Math]::Min(220, ([string]$r.summary).Length)) } else { $null })
    }
    if ($isMerged) { $merges += $rec } else { $halted += $rec }
}
$merges = @($merges | Sort-Object merged_at)
$halted = @($halted | Sort-Object completed_at)
$carriages = @()
foreach ($line in (G @('log', $MainRef, '--format=%H|%ct|%s', '-600'))) {
    $parts = $line -split '\|', 3
    if ($parts[2] -match 'PM gate receipt|independent PM gate receipt' -and $parts[2] -notmatch 'PKT-') {
        $carriages += [ordered]@{ sha = $parts[0].Substring(0,12); merged_at = (Z ([DateTimeOffset]::FromUnixTimeSeconds([long]$parts[1]).UtcDateTime)); subject = $parts[2] }
    }
}
$turnarounds = @($merges | Where-Object { $null -ne $_.turnaround_minutes } | ForEach-Object { $_.turnaround_minutes })
$meanTurnaround = $(if ($turnarounds.Count) { [Math]::Round(($turnarounds | Measure-Object -Average).Average) } else { $null })

# ---------------- throughput and projection ----------------
$winStart = ParseZ $ThroughputWindowStart
$now = [DateTime]::UtcNow
$inWindow = @($merges | Where-Object { (ParseZ $_.merged_at) -ge $winStart })
$days = [Math]::Max(0.25, ($now - $winStart).TotalDays)
$perDay = [Math]::Round($inWindow.Count / $days, 2)
$series = @()
$d = $winStart.Date
while ($d -le $now.Date) {
    $n = @($inWindow | Where-Object { (ParseZ $_.merged_at).Date -eq $d }).Count
    $series += [ordered]@{ date = $d.ToString('yyyy-MM-dd'); packets = $n }
    $d = $d.AddDays(1)
}
$cum = 0; $cumSeries = @()
foreach ($s in $series) { $cum += $s.packets; $cumSeries += [ordered]@{ date = $s.date; cumulative = $cum } }

$scopeUnits = @($plan.units | Where-Object { $_.phase })
$remaining  = @($scopeUnits | Where-Object { $_.status -ne 'done' })
$factor = [double]$plan.assumptions.packets_per_unit_default
$band = @($plan.assumptions.packets_per_unit_band | ForEach-Object { [double]$_ })
function ProjDate([double]$f) {
    if ($perDay -le 0) { return $null }
    $packets = $remaining.Count * $f
    $daysNeeded = $packets / $perDay + 1.0   # +1 day: the deploy that has not happened
    return (Z $now.AddDays($daysNeeded))
}
$projection = [ordered]@{
    basis = "merged packets per day since $ThroughputWindowStart (LOOP-8: one packet in flight), remaining plan units x declared packets-per-unit factor, plus one day for the overdue deploy"
    scope_units = $scopeUnits.Count; done_units = ($scopeUnits.Count - $remaining.Count); remaining_units = $remaining.Count
    packets_per_unit = $factor; packets_per_unit_band = $band
    packets_per_day = $perDay
    packets_needed = [Math]::Round($remaining.Count * $factor, 1)
    projected_date = (ProjDate $factor)
    projected_date_band = @((ProjDate $band[0]), (ProjDate $band[1]))
    original_end = $plan.plan_of_record.original_end
    rebaseline_status = $plan.plan_of_record.rebaseline
    factor_is_assumption = $true
}

# ---------------- phases and lanes ----------------
function Roll($group, $key) {
    $out = @()
    foreach ($g in ($plan.units | Where-Object { $_.$key } | Group-Object $key | Sort-Object Name)) {
        $u = @($g.Group)
        $out += [ordered]@{
            name = $g.Name; total = $u.Count
            done = @($u | ? { $_.status -eq 'done' }).Count
            in_progress = @($u | ? { $_.status -in 'in_progress','in_flight','queued' }).Count
            planned = @($u | ? { $_.status -eq 'planned' }).Count
            blocked = @($u | ? { $_.status -eq 'blocked' }).Count
            pct_done = [Math]::Round(100.0 * @($u | ? { $_.status -eq 'done' }).Count / $u.Count)
            units = @($u | ForEach-Object { [ordered]@{ id=$_.id; title=$_.title; status=$_.status; conflict=$_.conflict } })
        }
    }
    return ,$out
}
$phases = Roll 'phase' 'phase'
$lanes  = Roll 'lane' 'lane'

# ---------------- decisions ----------------
$decPending = Show $MainRef '{{SP:8:DEC_QUEUE_PATH}}'
$ledger     = Show $MainRef '{{SP:8:LEDGER_PATH}}'
$openDecisions = @()
foreach ($m in [regex]::Matches($decPending, '(?m)^## ([A-Z]+-\d+[A-Za-z-]*)[: ]([^\r\n]*)')) {
    $id = $m.Groups[1].Value; $title = $m.Groups[2].Value
    if ($title -match 'CLOSED|PM-FIXED|RATIFIED|RULED|ANSWERED|SUPERSEDED|CORRECTION|DISCHARGED|MOOT|^update|^ruling|\(NOTE') { continue }
    if ($openDecisions | Where-Object { $_.id -eq $id }) { continue }
    if ($id -match 'CORRECTION') { continue }
    if ($ledger -match [regex]::Escape($id)) { continue }   # D31: closed when the ledger answers it
    $found = [regex]::Match($decPending.Substring($m.Index, [Math]::Min(1200, $decPending.Length - $m.Index)), '(?i)found[: ]+(\d{4}-\d{2}-\d{2}(?:T[\d:]+Z)?)')
    $foundAt = $(if ($found.Success) { ParseZ $found.Groups[1].Value } else { $null })
    if (-not $foundAt) { $h = [regex]::Match($title, '(\d{4}-\d{2}-\d{2})'); if ($h.Success) { $foundAt = ParseZ $h.Groups[1].Value } }
    $openDecisions += [ordered]@{ id = $id; title = $title.Trim(); found = $(if ($foundAt) { Z $foundAt } else { $null }); age_days = $(if ($foundAt) { [Math]::Round(($now - $foundAt).TotalDays, 1) } else { $null }) }
}
$recentRulings = @()
foreach ($m in [regex]::Matches($ledger, '(?m)^### (D\d+): ([^\r\n]*)')) {
    $recentRulings += [ordered]@{ id = $m.Groups[1].Value; title = $m.Groups[2].Value.Trim() }
}
$recentRulings = @($recentRulings | Select-Object -Last 8)

# ---------------- repo health ----------------
$deploySha = G @('rev-parse', '--short=12', $LastDeployCommit)
$deployDate = $(if ($deploySha) { Z ([DateTimeOffset]::FromUnixTimeSeconds([long](G @('log', '-1', '--format=%ct', $LastDeployCommit))).UtcDateTime) } else { $null })
$sinceDeploy = $(if ($deploySha) { [int](G @('rev-list', '--count', "${LastDeployCommit}..${MainRef}")) } else { $null })
$mergesSinceDeploy = @($merges | Where-Object { $deployDate -and (ParseZ $_.merged_at) -gt (ParseZ $deployDate) }).Count

# latest receipt on main for advisory state
$latestReceipt = $null
$names = G @('ls-tree', '--name-only', $MainRef, '{{SP:3:RECEIPTS_DIR}}')
$best = $null
foreach ($n in $names) {
    if ($n -notmatch '\.json$') { continue }
    try { $r = (Show $MainRef $n) | ConvertFrom-Json } catch { continue }
    $t = ParseZ $(if ($r.generated_at) { $r.generated_at } else { $r.timestamp_utc })
    if ($t -and (-not $best -or $t -gt $best.t)) { $best = @{ t = $t; r = $r; n = $n } }
}
if ($best) {
    $audit = $best.r.steps | Where-Object { $_.name -eq 'audit' } | Select-Object -First 1
    $latestReceipt = [ordered]@{
        file = $best.n; generated_at = (Z $best.t); all_passed = [bool]$best.r.all_passed
        blocking_failed = $best.r.gating_steps_failed
        audit_advisory_passed = $(if ($audit) { [bool]$audit.passed } else { $null })
        head_commit_at_gen = $best.r.head_commit_at_gen
    }
}
# gate pass rate and duration over receipts on main (PM independent ones are the ones that merged)
$receiptStats = @{ total = 0; passed = 0; durations = @() }
foreach ($n in $names) {
    if ($n -notmatch '\.json$') { continue }
    try { $r = (Show $MainRef $n) | ConvertFrom-Json } catch { continue }
    $receiptStats.total++
    if ($r.all_passed) { $receiptStats.passed++ }
}

# ---------------- risks (computed, not written) ----------------
$risks = @()
if ([int]$gap[1] -gt 0) { $risks += [ordered]@{ id='unpushed'; level='high'; text="$($gap[1]) commits on main exist only on this machine" } }
if ($mergesSinceDeploy -gt 0) { $risks += [ordered]@{ id='undeployed'; level='medium'; text="$mergesSinceDeploy packets merged since the last recorded deploy ($deploySha, $deployDate)" } }
if ($lastTick -and ($now - $lastTick).TotalHours -gt 3) { $risks += [ordered]@{ id='loop-stale'; level='high'; text="last tick $([Math]::Round(($now - $lastTick).TotalHours,1)) hours ago" } }
if ($lockRef) { $risks += [ordered]@{ id='lock-held'; level='info'; text="tick lock held by $lockHolder" } }
if ($streak -ge 4) { $risks += [ordered]@{ id='starved'; level='medium'; text="$streak consecutive empty ticks: the queue is waiting on operator rulings" } }
if ($openDecisions.Count) { $oldest = ($openDecisions | Where-Object { $null -ne $_.age_days } | Sort-Object age_days -Descending | Select-Object -First 1).age_days; $risks += [ordered]@{ id='decisions'; level='medium'; text="$($openDecisions.Count) open operator decisions" + $(if ($null -ne $oldest) { ", oldest $oldest days" } else { '' }) } }
if ($latestReceipt -and -not $latestReceipt.audit_advisory_passed) { $risks += [ordered]@{ id='advisory'; level='low'; text='latest gate receipt reports an advisory audit failure' } }
$conflicts = @($plan.units | Where-Object { $_.conflict })
if ($conflicts.Count) { $risks += [ordered]@{ id='plan-conflict'; level='low'; text="$($conflicts.Count) plan units where tracker.json and STATUS.md disagree ($(($conflicts | % id) -join ', '))" } }

# ---------------- invariants ----------------
$invariants = @($plan.invariants)

# ---------------- assemble ----------------
$snapshot = [ordered]@{
    schema = 'gal-status-snapshot-v1'
    generated_at = (NowZ)
    generator = [ordered]@{ script = 'scripts/status-snapshot.ps1'; version = $GeneratorVersion; deterministic = $true }
    provenance = [ordered]@{
        main = $mainSha; origin_main = $originSha; cursor_branch_tip = $cursorSha
        plan = $planSource; plan_blob = $planBlob
        plan_generated_from = $plan.generated_from
        receipts_on_main = $receiptStats.total
    }
    project = [ordered]@{ name = '{{PROJECT_NAME}}'; plan = $plan.plan_of_record }
    repo = [ordered]@{
        main_short = $mainSha.Substring(0,12); origin_behind = [int]$gap[0]; origin_ahead = [int]$gap[1]
        pushed = ([int]$gap[1] -eq 0)
        last_deploy = [ordered]@{ sha = $deploySha; date = $deployDate; commits_since = $sinceDeploy; packets_since = $mergesSinceDeploy }
        latest_receipt = $latestReceipt
        gate = [ordered]@{ receipts = $receiptStats.total; passed = $receiptStats.passed; pass_rate_pct = $(if ($receiptStats.total) { [Math]::Round(100.0 * $receiptStats.passed / $receiptStats.total) } else { $null }); mean_turnaround_minutes = $meanTurnaround }
    }
    loop = [ordered]@{
        state = $cursor.state; packet = $cursor.current_packet; job_id = $cursor.job_id; branch = $cursor.branch
        dispatched_at = $(if ($dispatchedAt) { Z $dispatchedAt } else { $null })
        elapsed_minutes = $(if ($dispatchedAt -and $cursor.state -eq 'dispatched') { [Math]::Round(($now - $dispatchedAt).TotalMinutes) } else { $null })
        last_tick = $(if ($lastTick) { Z $lastTick } else { $null })
        tick_age_minutes = $(if ($lastTick) { [Math]::Round(($now - $lastTick).TotalMinutes) } else { $null })
        lock_held = [bool]$lockRef; lock_holder = $lockHolder
        empty_tick_streak = $streak
        inbox = @($cursor.dec_pending_inbox | ForEach-Object { $_.id })
        queued = @($cursor.queued)
        scheduler = $null   # filled by the status task from list_triggers; the script cannot reach it
    }
    merges = $merges
    halted = $halted
    carriages = @($carriages | Sort-Object merged_at)
    throughput = [ordered]@{ window_start = $ThroughputWindowStart; days = [Math]::Round($days, 2); packets = $inWindow.Count; per_day = $perDay; daily = $series; cumulative = $cumSeries }
    projection = $projection
    phases = $phases
    lanes = $lanes
    decisions = [ordered]@{ open = $openDecisions; recent_rulings = $recentRulings }
    risks = $risks
    invariants = $invariants
    narrative = $null   # written by the status task, labeled on the page as prose
}
($snapshot | ConvertTo-Json -Depth 10) | Set-Content -Path $Out -Encoding utf8
Write-Host ("SNAPSHOT ok  main={0} merges={1} per_day={2} remaining={3} projected={4} open_decisions={5} risks={6}" -f $mainSha.Substring(0,12), $merges.Count, $perDay, $remaining.Count, $projection.projected_date, $openDecisions.Count, $risks.Count)
exit 0
