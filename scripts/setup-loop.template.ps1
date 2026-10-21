<#
.SYNOPSIS
  Arms a Governed Agent Loop in an existing repository. Idempotent. Mutates
  only the loop's own paths; never touches product code or product branches.

.DESCRIPTION
  Creates the loop branch, the supervisor worktree, the cursor, the ledgers,
  the packet directory, the receipts directory, and the protocol file. Then
  verifies every path the protocol references actually exists and prints the
  values the scheduled tasks must be created with.

  This script does NOT create scheduled tasks. The scheduler is a product
  outside the repository and its credentials never belong in a script. The
  final section prints exactly what to create and where to paste the prompts.

  Run from the repository root under the same account the supervisor will run
  as, so that filesystem ownership and git safe.directory settings are settled
  before the first tick, not during it:

      pwsh -NoProfile -Command ./scripts/setup-loop.ps1 -ProjectName "<name>"

  Re-running is safe: every creation is conditional, nothing is overwritten,
  and a pre-existing cursor is left exactly as found.

.NOTES
  Placeholders in the kit ({{SP:n:NAME}}, {{PROJECT_NAME}}, ...) are resolved
  by the setup skill before this script runs. This script takes the resolved
  values as parameters so it can be run by hand as well.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ProjectName,

    # SP:1 the bus. The loop branch and where the supervisor checks it out.
    [string] $LoopBranch       = 'ops/pm-loop',
    [string] $WorktreePath     = '.worktrees/pm-setup',

    # SP:3 receipts and SP:4 ledgers, repo-relative.
    [string] $ReceiptsDir      = 'docs/gate-receipts',
    [string] $OpsDir           = 'ops/pm',

    # SP:5 the authoritative product branch. Never checked out by this script.
    [string] $MainBranch       = 'main',

    # Supervisor commit identity. A distinct identity is a traceability
    # requirement, not a convenience: it is how a reader tells a supervisor
    # commit from an operator commit.
    [string] $PmGitName        = "$ProjectName PM",
    [string] $PmGitEmail       = "pm@$($ProjectName.ToLower() -replace '[^a-z0-9]','-').invalid",

    # Lock and liveness parameters, written into the cursor for the tick to read.
    [int]    $LockStaleMinutes      = 50,
    [int]    $LivenessGraceMinutes  = 240,

    # Where the kit's protocol file lives relative to this script.
    [string] $KitProtocolFile  = (Join-Path $PSScriptRoot '..' 'protocol' 'pm-tick.md')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($msg) { Write-Host "== $msg" }
function Ok($msg)   { Write-Host "   ok   $msg" }
function Skip($msg) { Write-Host "   skip $msg (already present)" }
function Fail($msg) { Write-Error "setup: $msg"; exit 1 }

# ---------------------------------------------------------------------------
# 0. Preconditions. Fail closed.
# ---------------------------------------------------------------------------
Step 'preconditions'
$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { Fail 'not inside a git repository' }
Set-Location $repoRoot

if (-not (& git rev-parse --verify --quiet "refs/heads/$MainBranch")) {
    Fail "branch '$MainBranch' does not exist; the loop needs an authoritative product branch to serve"
}
Ok "repo $repoRoot, main branch $MainBranch"

$current = (& git rev-parse --abbrev-ref HEAD)
if ($current -eq $MainBranch) {
    # The supervisor's cardinal rule: main is never checked out in the
    # supervisor's working copy, because `git fetch . <branch>:main` refuses
    # to update a checked-out branch and the merge step would silently fall
    # back to something worse. Setup refuses to run from that state.
    Fail "'$MainBranch' is checked out here. Run setup from a non-main branch or a separate worktree (see docs/DECISIONS.md GAL-D05)."
}
Ok "HEAD is on '$current', not '$MainBranch'"

if (-not (Test-Path $KitProtocolFile)) { Fail "kit protocol file not found at $KitProtocolFile" }

# ---------------------------------------------------------------------------
# 1. Loop branch. Created from main's current tip so history is shared.
# ---------------------------------------------------------------------------
Step "loop branch $LoopBranch"
if (& git rev-parse --verify --quiet "refs/heads/$LoopBranch") {
    Skip $LoopBranch
} else {
    & git branch $LoopBranch $MainBranch | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "could not create $LoopBranch" }
    Ok "created from $MainBranch"
}

# ---------------------------------------------------------------------------
# 2. Supervisor worktree on the loop branch. The tick runs here, and only here.
# ---------------------------------------------------------------------------
Step "worktree $WorktreePath"
$wtAbs = Join-Path $repoRoot $WorktreePath
$existing = (& git worktree list --porcelain) -join "`n"
if ($existing -match [regex]::Escape($wtAbs.Replace('\','/'))) {
    Skip $WorktreePath
} elseif (Test-Path $wtAbs) {
    Fail "$WorktreePath exists but is not a registered worktree; refusing to overwrite"
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $wtAbs) | Out-Null
    & git worktree add $wtAbs $LoopBranch | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "git worktree add failed" }
    Ok 'added'
}

# Everything below operates inside the worktree.
Push-Location $wtAbs
try {
    # Supervisor identity, local to this worktree's repo config. Never global.
    & git config user.name  $PmGitName
    & git config user.email $PmGitEmail
    Ok "supervisor identity '$PmGitName <$PmGitEmail>' (local config)"

    # -----------------------------------------------------------------------
    # 3. Directories and ledgers. Create only what is absent.
    # -----------------------------------------------------------------------
    Step 'ledgers and directories'
    $dirs = @($OpsDir, (Join-Path $OpsDir 'packets'), $ReceiptsDir, 'docs')
    foreach ($d in $dirs) {
        if (Test-Path $d) { Skip $d } else { New-Item -ItemType Directory -Force -Path $d | Out-Null; Ok "mkdir $d" }
    }
    # .gitkeep so empty dirs survive the first commit.
    foreach ($d in @((Join-Path $OpsDir 'packets'), $ReceiptsDir)) {
        $k = Join-Path $d '.gitkeep'
        if (-not (Test-Path $k)) { New-Item -ItemType File -Path $k | Out-Null }
    }

    $nowZ = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $ledgers = @{
        (Join-Path $OpsDir 'DEC-PENDING.md') = @"
# ${ProjectName}: pending operator decisions

Append-only. The supervisor stages questions here; the operator answers in
session and the ruling is recorded in docs/DECISIONS.md. A ruling originates
in the ledger, never in a prompt or a handoff (GAL-D07). Corrections append
beside the original entry; nothing here is ever rewritten.

<!-- entries below; newest last -->
"@
        (Join-Path $OpsDir 'PM-HANDOFF.md') = @"
# ${ProjectName}: supervisor handoff

One entry per tick, newest first. Each entry names the tick number, the main
tip at start and end, what was harvested, what was dispatched, and what the
next tick must do. A handoff describes; it never rules.

<!-- entries below; newest first -->
"@
        'docs/DECISIONS.md' = @"
# ${ProjectName}: decision ledger

Append-only. Entries are numbered D01, D02, ... Each entry carries: date,
status (proposed | ratified | superseded), the question, the ruling, the
rationale, and consequences. A ratified entry is never edited; a correction
is a new entry that references the original. See the kit's docs/DECISIONS.md
for the format and GAL-D01..D12 for the loop's own decisions.

<!-- entries below; newest last -->
"@
    }
    foreach ($kv in $ledgers.GetEnumerator()) {
        if (Test-Path $kv.Key) { Skip $kv.Key }
        else { Set-Content -Path $kv.Key -Value $kv.Value -Encoding utf8 -NoNewline; Ok "wrote $($kv.Key)" }
    }

    # -----------------------------------------------------------------------
    # 4. The cursor. Only created if absent; an existing cursor is state and
    #    is never regenerated by setup.
    # -----------------------------------------------------------------------
    Step 'cursor'
    $cursorPath = Join-Path $OpsDir 'loop-state.json'
    if (Test-Path $cursorPath) {
        Skip $cursorPath
    } else {
        $mainTip = (& git rev-parse "refs/heads/$MainBranch")
        $cursor = [ordered]@{
            schema              = 'gal-cursor-v1'
            project             = $ProjectName
            tick                = 0
            updated_utc         = $nowZ
            main_branch         = $MainBranch
            main_tip_at_last_tick = $mainTip
            in_flight           = $null
            last_harvest        = $null
            merge_hold          = [ordered]@{ active = $false; reason = $null; set_utc = $null }
            lock                = [ordered]@{
                ref           = 'refs/pm/tick-lock'
                stale_minutes = $LockStaleMinutes
            }
            liveness            = [ordered]@{
                rule          = 'terminal-status-only'
                grace_minutes = $LivenessGraceMinutes
            }
            dec_pending_inbox   = @()
            notes               = 'Created by setup-loop. The tick owns this file from here on.'
        }
        ($cursor | ConvertTo-Json -Depth 6) | Set-Content -Path $cursorPath -Encoding utf8 -NoNewline
        Ok "wrote $cursorPath at tick 0, main tip $($mainTip.Substring(0,12))"
    }

    # -----------------------------------------------------------------------
    # 5. Protocol file. Copied from the kit, never overwritten; the operator
    #    edits the copy and the tick reads the copy.
    # -----------------------------------------------------------------------
    Step 'protocol'
    $protoDest = Join-Path $OpsDir 'pm-tick.md'
    if (Test-Path $protoDest) { Skip $protoDest }
    else { Copy-Item $KitProtocolFile $protoDest; Ok "copied protocol to $protoDest" }

    # -----------------------------------------------------------------------
    # 6. Verification. Every path the protocol references must exist, and no
    #    unresolved kit placeholder may remain in the copied protocol.
    # -----------------------------------------------------------------------
    Step 'verification'
    $required = @($cursorPath, $protoDest, (Join-Path $OpsDir 'DEC-PENDING.md'),
                  (Join-Path $OpsDir 'PM-HANDOFF.md'), 'docs/DECISIONS.md',
                  (Join-Path $OpsDir 'packets'), $ReceiptsDir)
    $missing = @($required | Where-Object { -not (Test-Path $_) })
    if ($missing.Count) { Fail "missing after setup: $($missing -join ', ')" }
    Ok 'all loop paths present'

    $unresolved = Select-String -Path $protoDest -Pattern '\{\{[A-Z_:0-9]+\}\}' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Sort-Object -Unique
    if ($unresolved) {
        Write-Warning "unresolved placeholders in ${protoDest}: $($unresolved -join ' ')"
        Write-Warning 'resolve them before the first tick; the tick protocol halts on contradiction, and an unresolved token is one'
    } else { Ok 'no unresolved placeholders in protocol' }

    if ((& git rev-parse --abbrev-ref HEAD) -ne $LoopBranch) { Fail "worktree is not on $LoopBranch" }
    Ok "worktree on $LoopBranch"

    # -----------------------------------------------------------------------
    # 7. Commit the arming as the supervisor identity, on the loop branch only.
    # -----------------------------------------------------------------------
    Step 'commit'
    & git add -- $OpsDir $ReceiptsDir docs/DECISIONS.md
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Skip 'nothing to commit'
    } else {
        $msg = "ops: arm governed agent loop for $ProjectName`n`nCreated by setup-loop. Loop branch $LoopBranch, cursor at tick 0.`nNOT A PRODUCT CHANGE: touches only loop paths."
        & git commit -q -m $msg
        if ($LASTEXITCODE -ne 0) { Fail 'commit failed' }
        Ok "committed $(& git rev-parse --short HEAD) on $LoopBranch"
    }
}
finally { Pop-Location }

# ---------------------------------------------------------------------------
# 8. What the operator does next. Printed, not done: the scheduler lives
#    outside the repo and its credentials never enter a script.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== next: create the scheduled tasks (outside this script)'
Write-Host @"
   1. Tick        hourly, requires the computer, prompt = prompts/tick.prompt.md
                  working dir: $WorktreePath   branch: $LoopBranch
   2. Digest      daily,  requires the computer, prompt = prompts/digest.prompt.md
   3. Watchdog A  every 4h, requires the computer, prompt = prompts/watchdog-device.prompt.md
   4. Watchdog B  every 6h, cloud (no computer), prompt = prompts/watchdog-cloud.prompt.md
   Model: tick and digest on the strongest model you will pay for; watchdogs on
   the cheapest that can read a run record (GAL-D12). Device-bound tasks carry
   their model in the signed session request; set it at creation.
   Then write the first packet into $OpsDir/packets/ from protocol/packet-TEMPLATE.md
   and let the next tick pick it up. Do not hand-run the tick protocol.
"@
exit 0
