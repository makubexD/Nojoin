#: show per-stage processing times from the worker logs

<#
.SYNOPSIS
    How long each processing stage took for recent recordings.

.DESCRIPTION
    Reads `podman logs nojoin-worker-gpu` (stdout and stderr). A line that
    contains `pipeline_metric {` is JSON. Only recording_id, stage, and
    elapsed_ms are kept. The payload is never printed. The line
    `Recording: [N] processing succeeded in X seconds` supplies the total
    when final_processing_completed is absent.

    Logs reset when the container is recreated. This command does not
    start, stop, or recreate anything.

.PARAMETER Last
    How many recordings to show, newest last. Default 5.

.PARAMETER Since
    Passed to `podman logs --since` (for example 30m).

.PARAMETER Json
    Emit one object per stage: recording_id, stage, seconds.

.EXAMPLE
    .\contrib\maku.ps1 stack timing

.EXAMPLE
    .\contrib\maku.ps1 stack timing -Last 3 -Since 30m
#>
param(
    [int]$Last = 5,
    [string]$Since,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Use-NativeExitCodes

if ($Last -lt 1) {
    throw (New-Refusal "-Last must be at least 1." ".\contrib\maku.ps1 stack timing -Last 5")
}

Test-PodmanReady

$logArgs = @('logs', 'nojoin-worker-gpu')
if ($Since) { $logArgs += @('--since', $Since) }
$raw = & podman @logArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    $hint = @($raw | Select-Object -First 2 | ForEach-Object { "$_" }) -join ' '
    if ($hint.Length -gt 200) { $hint = $hint.Substring(0, 200) }
    throw (New-Refusal "podman logs nojoin-worker-gpu failed (exit $LASTEXITCODE). $hint" "podman ps --filter name=nojoin-worker-gpu")
}

# Known stages first, in pipeline order. Anything else follows, in log order.
$known = @(
    'live_asr_region',
    'final_asr_invocation',
    'final_diarization_invocation',
    'segmentation_refinement',
    'final_processing_completed',
    'overlap_analytics'
)

# recording_id -> ordered stage -> seconds (last sample wins).
$byId = @{}
$lastSeen = @{}
$succeeded = @{}
$metricCount = 0
$lineNo = 0

foreach ($item in @($raw)) {
    $lineNo++
    $line = [string]$item
    if ($line -match 'pipeline_metric\s+(\{.*\})\s*$') {
        $metricCount++
        try {
            $event = $Matches[1] | ConvertFrom-Json
        } catch {
            continue
        }
        if ($null -eq $event.recording_id -or $null -eq $event.elapsed_ms) { continue }
        $stage = [string]$event.stage
        if (-not $stage) { continue }
        $id = [string]$event.recording_id
        $seconds = [math]::Round(([double]$event.elapsed_ms) / 1000.0, 1)
        if (-not $byId.Contains($id)) { $byId[$id] = [ordered]@{} }
        $byId[$id][$stage] = $seconds
        $lastSeen[$id] = $lineNo
        continue
    }
    if ($line -match 'Recording: \[(\d+)\] processing succeeded in ([0-9]+(?:\.[0-9]+)?) seconds') {
        $id = $Matches[1]
        $succeeded[$id] = [math]::Round([double]$Matches[2], 1)
        if (-not $lastSeen.Contains($id)) { $lastSeen[$id] = $lineNo }
    }
}

if ($metricCount -eq 0) {
    $window = if ($Since) { " since $Since" } else { '' }
    Write-Host "No pipeline_metric lines$window. No recordings processed since the container started; logs reset when the container is recreated."
    exit 0
}

$ids = @($byId.Keys | Sort-Object { $lastSeen[$_] })
if ($ids.Count -gt $Last) {
    $ids = @($ids | Select-Object -Last $Last)
}

function Get-TotalSeconds($Id) {
    $stages = $byId[$Id]
    if ($stages.Contains('final_processing_completed')) {
        return [double]$stages['final_processing_completed']
    }
    if ($succeeded.Contains($Id)) { return [double]$succeeded[$Id] }
    return $null
}

if ($Json) {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $stages = $byId[$id]
        $ordered = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $known) {
            if ($stages.Contains($name)) { $ordered.Add($name) }
        }
        foreach ($name in @($stages.Keys)) {
            if ($name -notin $known) { $ordered.Add($name) }
        }
        $recordingId = 0
        $idValue = if ([int]::TryParse($id, [ref]$recordingId)) { $recordingId } else { $id }
        foreach ($name in $ordered) {
            $rows.Add([pscustomobject]@{
                recording_id = $idValue
                stage = $name
                seconds = [double]$stages[$name]
            })
        }
    }
    Write-Output (ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 3)
    exit 0
}

$first = $true
foreach ($id in $ids) {
    if (-not $first) { Write-Host '' }
    $first = $false
    Write-Host "recording $id"
    $stages = $byId[$id]
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $known) {
        if ($stages.Contains($name)) { $ordered.Add($name) }
    }
    foreach ($name in @($stages.Keys)) {
        if ($name -notin $known) { $ordered.Add($name) }
    }
    foreach ($name in $ordered) {
        Write-Host ("  {0,-32} {1,6:0.0}" -f $name, [double]$stages[$name])
    }
    $total = Get-TotalSeconds $id
    $totalText = if ($null -eq $total) { 'unknown' } else { ('{0:0.0} s' -f $total) }
    if ($stages.Contains('final_asr_invocation') -and $null -ne $total -and $total -gt 0) {
        $share = 100.0 * [double]$stages['final_asr_invocation'] / $total
        Write-Host ("  total {0}, final_asr_invocation {1:0.0}%" -f $totalText, $share)
    } elseif ($stages.Contains('final_asr_invocation')) {
        Write-Host ("  total {0}, final_asr_invocation {1:0.0} s" -f $totalText, [double]$stages['final_asr_invocation'])
    } else {
        Write-Host "  total $totalText"
    }
}

exit 0
