<#
.SYNOPSIS
  Validate a status snapshot before it is published. Exit 0 only when the snapshot
  parses, matches {{SP:1:LOOP_HOME}}/schema/status-snapshot.schema.json, and passes the semantic
  checks below. The status task refuses to publish on any non-zero exit.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Snapshot,
    [string] $Schema = (Join-Path (Split-Path $PSScriptRoot -Parent) '{{SP:1:LOOP_HOME}}/schema/status-snapshot.schema.json'),
    [int] $MaxAgeMinutes = 30
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$fail = @()
if (-not (Test-Path $Snapshot)) { Write-Host "VALIDATE FAIL  snapshot missing: $Snapshot"; exit 1 }
if (-not (Test-Path $Schema))   { Write-Host "VALIDATE FAIL  schema missing: $Schema"; exit 1 }
$raw = Get-Content $Snapshot -Raw
try { $s = $raw | ConvertFrom-Json } catch { Write-Host "VALIDATE FAIL  not JSON: $($_.Exception.Message)"; exit 1 }

# structural
$schemaOk = $false
try { $schemaOk = Test-Json -Json $raw -SchemaFile $Schema -ErrorAction Stop } catch { $fail += "schema: $($_.Exception.Message)" }
if (-not $schemaOk -and -not $fail) { $fail += 'schema: Test-Json returned false' }

# semantic
$gen = [DateTime]::Parse($s.generated_at, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
$age = ([DateTime]::UtcNow - $gen).TotalMinutes
if ($age -gt $MaxAgeMinutes) { $fail += "stale: generated $([Math]::Round($age)) minutes ago (limit $MaxAgeMinutes)" }
if ($age -lt -5) { $fail += "generated_at is in the future by $([Math]::Round(-$age)) minutes; host clock skew" }
if ($s.provenance.main -notmatch '^[0-9a-f]{40}$') { $fail += 'provenance.main is not a full sha' }
if ($s.projection.remaining_units -lt 0 -or $s.projection.done_units -lt 0) { $fail += 'projection counts negative' }
if ($s.projection.scope_units -ne ($s.projection.done_units + $s.projection.remaining_units)) { $fail += 'projection: scope != done + remaining' }
if ($s.throughput.per_day -gt 0 -and -not $s.projection.projected_date) { $fail += 'projection: throughput positive but no projected date' }
if ($s.projection.projected_date) {
    $pd = [DateTime]::Parse($s.projection.projected_date, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
    if ($pd -lt $gen) { $fail += 'projection: projected date before generation time' }
}
foreach ($p in $s.phases) { if ($p.total -ne ($p.done + $p.in_progress + $p.planned + $p.blocked)) { $fail += "phase $($p.name): counts do not sum to total (parked or cut units present?)" } }
if ($s.merges.Count -gt 0) {
    $last = $s.merges[-1]
    if (-not ($last.merged_sha -match '^[0-9a-f]{7,40}$')) { $fail += 'merges: last merged_sha malformed' }
}
if ($s.narrative -and ($s.narrative -match '(?i)\b(must|shall|next tick|dispatch|merge now|re-enable)\b')) { $fail += 'narrative reads as an instruction; it may only describe' }

if ($fail.Count) { Write-Host 'VALIDATE FAIL'; $fail | ForEach-Object { Write-Host "  - $_" }; exit 1 }
Write-Host ("VALIDATE ok  generated={0} age={1}m merges={2} per_day={3} projected={4}" -f $s.generated_at, [Math]::Round($age), $s.merges.Count, $s.throughput.per_day, $s.projection.projected_date)
exit 0
