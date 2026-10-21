<#
.SYNOPSIS
  Governed Agent Loop gate template. Runs the validation steps, computes the
  binding, writes a v2 self-attesting receipt, and exits non-zero on any
  blocking failure.

.DESCRIPTION
  The binding computation and the receipt shape are the load-bearing parts and
  are NOT swap points. The step registry and the preconditions are. Edit only
  the blocks marked SWAP.

  Invoke from the repository root, under the same account the supervisor runs
  as, in a clean detached worktree at the exact tip to be gated:

      pwsh -NoProfile -Command ./scripts/gate.ps1

  Some execution substrates refuse the -File launch flag because it bypasses
  command inspection; -Command is the portable form.

  Binding rule (normative, see protocol/gate-receipt.schema.json $comment):
  SHA-256 over the UTF-8 bytes of the lines of `git ls-files -s`, with every
  line whose path begins with the receipts directory removed, sorted ordinally,
  joined with a single LF and no trailing LF. The receipts directory is the ONLY
  exclusion.

.NOTES
  Exit 0 iff all blocking steps passed and every precondition held.
  Exit 1 otherwise. The receipt is written in both cases.
  Exit 2 if the gate could not even start (not a repo, HEAD unreadable).
#>

[CmdletBinding()]
param(
    # SWAP 3: receipts directory, repo-relative, trailing slash.
    [string] $ReceiptsDir = 'docs/gate-receipts/',

    # Report a dirty working tree as a precondition failure (fail closed) or
    # merely record it. The reference fails closed.
    [bool]   $DirtyTreeIsFailure = $true,

    # Toolchain pin check. SWAP 2: adapt to your toolchain or set to $null.
    [string] $ToolchainName    = 'rustc',
    [string] $ToolchainPinFile = 'rust-toolchain.toml'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# 0. Sanity: inside a git repo, HEAD readable.
# ---------------------------------------------------------------------------
$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { Write-Error 'gate: not inside a git repository'; exit 2 }
Set-Location $repoRoot

$headAtStart = (& git rev-parse HEAD 2>$null)
if (-not $headAtStart -or $headAtStart.Length -ne 40) {
    Write-Error 'gate: HEAD unreadable; a receipt cannot name a commit it cannot read (GAL-D04)'
    exit 2
}

$startedUtc = [DateTime]::UtcNow
function NowZ { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

$receiptsDirNorm = $ReceiptsDir.TrimEnd('/','\').Replace('\','/') + '/'

# ---------------------------------------------------------------------------
# 1. Working tree state. Untracked, non-ignored files outside the receipts
#    directory count as dirty. Modified tracked files count as dirty.
# ---------------------------------------------------------------------------
$porcelain = @(& git status --porcelain --untracked-files=all 2>$null)
$dirtyLines = @($porcelain | Where-Object {
    $_ -and -not ($_.Substring(3).Replace('\','/').StartsWith($receiptsDirNorm))
})
$workingTreeDirty = $dirtyLines.Count -gt 0

# ---------------------------------------------------------------------------
# 2. The binding. DO NOT EDIT THIS BLOCK.
# ---------------------------------------------------------------------------
function Get-ManifestLines {
    param([string[]] $RawLines, [string] $Exclude)
    # Each line: "<mode> <object> <stage>\t<path>". Exclude by path prefix.
    $kept = foreach ($l in $RawLines) {
        if (-not $l) { continue }
        $tab = $l.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $path = $l.Substring($tab + 1).Replace('\','/')
        if ($path.StartsWith($Exclude)) { continue }
        $l
    }
    $arr = @($kept)
    [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return ,$arr
}

function Get-Sha256Hex {
    param([string] $Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)   # no BOM
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}

# Staged manifest, exactly as the rule states.
$stagedRaw   = @(& git ls-files -s)
$stagedLines = Get-ManifestLines -RawLines $stagedRaw -Exclude $receiptsDirNorm
$boundTreeHash = Get-Sha256Hex -Text ($stagedLines -join "`n")
$receiptId = $boundTreeHash.Substring(0, 12)

# HEAD's tree rendered to the same line shape, for self-attestation.
# ls-tree gives "<mode> <type> <object>\t<path>"; ls-files -s gives
# "<mode> <object> <stage>\t<path>". Rewrite to the latter with stage 0.
$headRaw = @(& git ls-tree -r --full-tree $headAtStart) | ForEach-Object {
    $tab  = $_.IndexOf("`t")
    $meta = $_.Substring(0, $tab).Split(' ')
    "$($meta[0]) $($meta[2]) 0`t$($_.Substring($tab + 1))"
}
$headLines = Get-ManifestLines -RawLines $headRaw -Exclude $receiptsDirNorm
$headTreeHash = Get-Sha256Hex -Text ($headLines -join "`n")

# binds_commit: true when staged == HEAD manifest. Null is reserved for the
# stage->gate->commit workflow where the commit does not yet exist; in THIS
# script HEAD always exists, so a mismatch is a precondition failure, never
# false (schema: "Never FALSE").
$bindsCommit = ($boundTreeHash -eq $headTreeHash)

# ---------------------------------------------------------------------------
# 3. Preconditions. Fail closed: a missing precondition is a failed gate,
#    never a skipped step. SWAP 7: add every exclusive resource the steps need.
# ---------------------------------------------------------------------------
$preconditions = [ordered]@{}

$preconditions['head_readable']        = $true
$preconditions['staged_matches_head']  = $bindsCommit
$preconditions['working_tree_clean']   = (-not $workingTreeDirty) -or (-not $DirtyTreeIsFailure)

# SWAP 7 begin ------------------------------------------------------------
# Example: an integration test database.
$preconditions['test_database_url_set'] = -not [string]::IsNullOrWhiteSpace($env:TEST_DATABASE_URL)
# Example: a container daemon, only if a step needs it.
# $preconditions['docker_daemon_reachable'] = (& docker info 2>$null; $LASTEXITCODE -eq 0)
# SWAP 7 end --------------------------------------------------------------

$toolchain = $null
if ($ToolchainName) {
    # SWAP 2: adapt the version probe and the pin read to your toolchain.
    $ver = $null
    try { $ver = ((& $ToolchainName --version 2>$null) -split ' ')[1] } catch {}
    $pin = $null
    if ($ToolchainPinFile -and (Test-Path $ToolchainPinFile)) {
        $m = Select-String -Path $ToolchainPinFile -Pattern 'channel\s*=\s*"([^"]+)"' | Select-Object -First 1
        if ($m) { $pin = $m.Matches[0].Groups[1].Value }
    }
    $toolchain = [ordered]@{
        name        = $ToolchainName
        version     = $ver
        matches_pin = ($null -eq $pin) -or ($ver -eq $pin)
    }
    $preconditions['toolchain_matches_pin'] = [bool]$toolchain.matches_pin
}

$allPreconditionsHeld = -not ($preconditions.Values -contains $false)

# ---------------------------------------------------------------------------
# 4. Step registry. SWAP 2: this is your validation suite. Keep blocking and
#    advisory explicit. An advisory step that fails on every receipt has become
#    noise; fix it or formally accept it with a dated entry.
# ---------------------------------------------------------------------------
$steps = @(
    # SWAP 2 begin --------------------------------------------------------
    @{ name='fmt';            blocking=$true;  cmd={ & cargo fmt --all -- --check } },
    @{ name='check';          blocking=$true;  cmd={ & cargo check --workspace } },
    @{ name='clippy';         blocking=$true;  cmd={ & cargo clippy --workspace --all-targets --all-features -- -D warnings } },
    @{ name='test-workspace'; blocking=$true;  cmd={ & cargo test --workspace --all-features --no-fail-fast } },
    @{ name='doc';            blocking=$true;  cmd={ $env:RUSTDOCFLAGS='-D warnings'; & cargo doc --workspace --all-features --no-deps } },
    @{ name='gitleaks';       blocking=$true;  cmd={ & gitleaks detect --no-banner --redact --source . } },
    @{ name='audit';          blocking=$false; cmd={ & cargo audit } }
    # SWAP 2 end ----------------------------------------------------------
)

$stepResults = @()
if ($allPreconditionsHeld) {
    foreach ($s in $steps) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $exit = $null
        try {
            & $s.cmd *>&1 | Out-Null
            $exit = $LASTEXITCODE
        } catch {
            $exit = 1
        }
        $sw.Stop()
        if ($null -eq $exit) { $exit = 0 }
        $stepResults += [ordered]@{
            name        = $s.name
            blocking    = [bool]$s.blocking
            passed      = ($exit -eq 0)
            exit_code   = $exit
            duration_ms = [int]$sw.ElapsedMilliseconds
        }
    }
} else {
    # Preconditions failed: record every step as not run, blocking ones as
    # failed, so the receipt is honest about what did not happen.
    foreach ($s in $steps) {
        $stepResults += [ordered]@{
            name        = $s.name
            blocking    = [bool]$s.blocking
            passed      = $false
            exit_code   = $null
            duration_ms = $null
            note        = 'not run: precondition failed'
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Stability: HEAD must not have moved and the tree must not have changed
#    during the run, or the receipt binds nothing.
# ---------------------------------------------------------------------------
$headAtEnd = (& git rev-parse HEAD)
$stagedRawEnd = @(& git ls-files -s)
$stagedEndHash = Get-Sha256Hex -Text ((Get-ManifestLines -RawLines $stagedRawEnd -Exclude $receiptsDirNorm) -join "`n")
$stableDuringRun = ($headAtEnd -eq $headAtStart) -and ($stagedEndHash -eq $boundTreeHash)

# ---------------------------------------------------------------------------
# 6. Verdict and receipt.
# ---------------------------------------------------------------------------
$gatingFailed = @($stepResults | Where-Object { $_.blocking -and -not $_.passed }).Count
$allPassed = ($gatingFailed -eq 0) -and $allPreconditionsHeld -and $stableDuringRun

$receipt = [ordered]@{
    schema               = 'gal-gate-receipt-v2'
    receipt_id           = $receiptId
    timestamp_utc        = (NowZ)
    head_commit_at_gen   = $headAtStart
    git_head_at_start    = $headAtStart
    git_head_at_end      = $headAtEnd
    stable_during_run    = $stableDuringRun
    bound_tree_hash      = $boundTreeHash
    binds_commit         = $bindsCommit
    binding_rule_version = 1
    working_tree_dirty   = $workingTreeDirty
    toolchain            = $toolchain
    preconditions        = $preconditions
    steps                = $stepResults
    gating_steps_failed  = $gatingFailed
    all_passed           = $allPassed
    generated_by         = [ordered]@{
        role     = $(if ($env:GAL_ROLE) { $env:GAL_ROLE } else { 'agent' })
        identity = $(if ($env:GAL_IDENTITY) { $env:GAL_IDENTITY } else { $env:USERNAME })
        job_id   = $env:GAL_JOB_ID
    }
    container_build_proof = $null
}

New-Item -ItemType Directory -Force -Path $receiptsDirNorm | Out-Null
$receiptPath = Join-Path $receiptsDirNorm "$receiptId.json"
($receipt | ConvertTo-Json -Depth 8) | Set-Content -Path $receiptPath -Encoding utf8 -NoNewline

# ---------------------------------------------------------------------------
# 7. Report. One line a supervisor can grep.
# ---------------------------------------------------------------------------
$verdict = if ($allPassed) { 'PASS' } else { 'FAIL' }
Write-Host ("RESULT {0}  receipt={1}  head={2}  binds_commit={3}  blocking_failed={4}  stable={5}  preconditions_ok={6}" -f `
    $verdict, $receiptId, $headAtStart.Substring(0,12), $bindsCommit, $gatingFailed, $stableDuringRun, $allPreconditionsHeld)
foreach ($r in $stepResults) {
    $tag = if ($r.blocking) { 'BLOCK' } else { 'ADVIS' }
    Write-Host ("  [{0}] {1,-16} {2}" -f $tag, $r.name, $(if ($r.passed) { 'ok' } else { "FAIL (exit $($r.exit_code))" }))
}

exit $(if ($allPassed) { 0 } else { 1 })
