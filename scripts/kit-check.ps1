# kit-check.ps1
#
# The kit's own gate. Runs on every pull request and must pass before main
# moves. It checks structure, not facts: a reviewer reading the diff against
# the reference implementation's record is the other half (README, "How this
# kit gates itself"). Exit code is the number of findings.
#
# Invoke from the repository root:  pwsh -NoProfile -Command ./scripts/kit-check.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$findings = New-Object System.Collections.Generic.List[string]
function Fail([string]$msg) { $findings.Add($msg); Write-Host "FAIL  $msg" }
function Pass([string]$msg) { Write-Host "ok    $msg" }

$files = & git -C $root ls-files
$text = @{}
foreach ($f in $files) { $text[$f] = [System.IO.File]::ReadAllText((Join-Path $root $f)) }
$md = $files | Where-Object { $_ -like '*.md' }

# 1. No em or en dashes anywhere.
$hit = $false
foreach ($f in $files) {
  foreach ($ch in @([char]0x2014, [char]0x2013)) {
    $i = $text[$f].IndexOf($ch)
    if ($i -ge 0) { $hit = $true; Fail "$f contains U+$([int]$ch | ForEach-Object { $_.ToString('X4') }) at offset $i" }
  }
}
if (-not $hit) { Pass 'no em or en dashes' }

# 2. No setext accident: a non-blank line directly followed by --- renders as a heading.
$hit = $false
foreach ($f in $md) {
  $l = $text[$f] -split "`n"
  $frontmatterClose = -1
  if ($l.Count -gt 0 -and $l[0] -eq '---') { for ($i = 1; $i -lt $l.Count; $i++) { if ($l[$i] -eq '---') { $frontmatterClose = $i; break } } }
  for ($i = 1; $i -lt $l.Count; $i++) {
    if ($l[$i] -eq '---' -and $i -ne $frontmatterClose -and $l[$i-1].Trim() -ne '') { $hit = $true; Fail "$f`:$($i+1) '---' directly under text (setext heading)" }
  }
}
if (-not $hit) { Pass 'no setext accidents' }

# 3. Every ledger entry carries the seven fields, in order, and headings are unique.
$ledger = $text['docs/DECISIONS.md'] -split "`n"
$fields = @('Date','Decider','Origin','Question','Options','Disposition','Reasoning')
$cur = $null; $seen = @(); $ids = @(); $hit = $false
function Check-Entry {
  if (-not $script:cur) { return }
  $missing = $script:fields | Where-Object { $script:seen -notcontains $_ }
  if ($missing) { $script:hit = $true; Fail "ledger $script:cur missing field(s): $($missing -join ', ')" }
  $expected = $script:fields | Where-Object { $script:seen -contains $_ }
  if (($script:seen -join ',') -ne ($expected -join ',')) { $script:hit = $true; Fail "ledger $script:cur fields out of order: $($script:seen -join ', ')" }
}
foreach ($line in $ledger) {
  if ($line -match '^### (GAL-D[0-9]+(-C[0-9]+)?):') {
    Check-Entry
    $cur = $Matches[1]; $seen = @()
    if ($ids -contains $cur) { $hit = $true; Fail "ledger heading $cur appears twice" }
    $ids += $cur
  } elseif ($cur -and $line -match '^(Date|Decider|Origin|Question|Options|Disposition|Reasoning):') { $seen += $Matches[1] }
}
Check-Entry
if (-not $hit) { Pass "ledger: $($ids.Count) entries, all seven fields in order" }

# 4. Failure-log numbering is contiguous and headings are unique.
$log = $text['docs/FAILURE-LOG.md'] -split "`n"
$hit = $false
foreach ($kind in @('LOOP','DEFECT')) {
  $nums = @()
  foreach ($line in $log) { if ($line -match "^##+ $kind-([0-9]+)\.") { $n = [int]$Matches[1]; if ($nums -contains $n) { $hit = $true; Fail "failure log $kind-$n appears twice" }; $nums += $n } }
  if ($nums.Count -gt 0) {
    $max = ($nums | Measure-Object -Maximum).Maximum
    $min = ($nums | Measure-Object -Minimum).Minimum
    for ($n = $min; $n -le $max; $n++) { if ($nums -notcontains $n) { $hit = $true; Fail "failure log $kind-$n is missing between $kind-$min and $kind-$max" } }
  }
}
if (-not $hit) { Pass 'failure log numbering contiguous' }

# 5. Every id the kit cites exists.
$all = ($files | ForEach-Object { $text[$_] }) -join "`n"
$defined = @{}
foreach ($id in $ids) { $defined[$id] = $true }
foreach ($line in $log) { if ($line -match '^(##+ |- \*\*)((LOOP|DEFECT|INV|GATE|RED)-[0-9]+)') { $defined[$Matches[2]] = $true } }
$hit = $false
foreach ($m in [regex]::Matches($all, '\b(GAL-D[0-9]+(?:-C[0-9]+)?|LOOP-[0-9]+|DEFECT-[0-9]+)\b')) {
  $id = $m.Groups[1].Value
  # An id the reference implementation owns (its D-numbers and its own LOOP and DEFECT series) is
  # admitted when the text within 160 characters before it says 'reference'; an unqualified id must exist here.
  $before = $all.Substring([Math]::Max(0, $m.Index - 160), [Math]::Min(160, $m.Index))
  if (-not $defined.ContainsKey($id) -and $before -notmatch 'reference') { $hit = $true; Fail "reference to $id but no such entry (GAL-D in DECISIONS.md; LOOP and DEFECT in FAILURE-LOG.md)" }
}
if (-not $hit) { Pass 'every GAL-D, LOOP and DEFECT reference resolves' }

# 6. METHOD section references resolve, and the README rule count matches its headline.
$methodMax = 0
foreach ($line in ($text['docs/METHOD.md'] -split "`n")) { if ($line -match '^## ([0-9]+)\.') { $n = [int]$Matches[1]; if ($n -gt $methodMax) { $methodMax = $n } } }
$hit = $false
foreach ($m in [regex]::Matches($all, 'METHOD section ([0-9]+)')) { if ([int]$m.Groups[1].Value -gt $methodMax) { $hit = $true; Fail "reference to METHOD section $($m.Groups[1].Value); METHOD has $methodMax" } }
$ruleCount = ([regex]::Matches($text['README.md'], '(?m)^\*\*[0-9]+\. ')).Count
if ($ruleCount -ne 11) { $hit = $true; Fail "README lists $ruleCount numbered rules; the kit says eleven everywhere" }
if (-not $hit) { Pass "METHOD has $methodMax sections; README lists 11 rules" }

# 7. SWAP-POINTS: the values table and the numbered sections agree.
$sp = $text['SWAP-POINTS.md']
$rows = ([regex]::Matches($sp, '(?m)^\| [0-9]+ \| ')).Count
$secs = ([regex]::Matches($sp, '(?m)^## [0-9]+\. ')).Count
if ($rows -ne $secs) { Fail "SWAP-POINTS table has $rows value rows but $secs numbered sections" } else { Pass "SWAP-POINTS: $rows values, $secs sections" }
if ($sp -match '## The (\w+) values') {
  $words = @{ 'eight' = 8; 'nine' = 9; 'ten' = 10; 'eleven' = 11; 'twelve' = 12 }
  $w = $Matches[1].ToLower()
  if ($words.ContainsKey($w) -and $words[$w] -ne $rows) { Fail "SWAP-POINTS heading says '$w values' over $rows rows" }
}

# 8. Every placeholder a prompt or protocol file uses is one the setup skill resolves.
$skill = $text['skill/governed-agent-loop-setup/SKILL.md']
$src = ($files | Where-Object { $_ -like 'prompts/*' -or $_ -like 'protocol/*' } | ForEach-Object { $text[$_] }) -join "`n"
$hit = $false
foreach ($t in ([regex]::Matches($src, '\{\{[A-Z_:0-9]+\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)) {
  if ($skill.IndexOf($t) -lt 0) { $hit = $true; Fail "placeholder $t is used but the setup skill never collects it" }
}
if (-not $hit) { Pass 'every placeholder is collected by the setup skill' }

# 9. Every JSON file parses.
$hit = $false
foreach ($f in ($files | Where-Object { $_ -like '*.json' })) {
  try { $null = $text[$f] | ConvertFrom-Json } catch { $hit = $true; Fail "$f does not parse: $($_.Exception.Message)" }
}
if (-not $hit) { Pass 'all JSON parses' }

# 10. Tracked text is LF in the index, and nothing that looks like a credential value is tracked.
$eol = & git -C $root ls-files --eol
$crlf = $eol | Where-Object { $_ -match '^i/crlf|^i/mixed' }
if ($crlf) { foreach ($e in $crlf) { Fail "index EOL: $e" } } else { Pass 'index EOL is LF' }
$hit = $false
foreach ($m in [regex]::Matches($all, '\b(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b')) { $hit = $true; Fail "credential-shaped string tracked: $($m.Value.Substring(0,8))..." }
if (-not $hit) { Pass 'no credential-shaped strings' }

Write-Host ''
if ($findings.Count -eq 0) { Write-Host 'kit-check: PASS'; exit 0 }
Write-Host "kit-check: $($findings.Count) finding(s)"
exit $findings.Count
