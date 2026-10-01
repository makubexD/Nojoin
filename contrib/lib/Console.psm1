# Console output shared by every command, so a stage, a pass and a refusal
# look the same whichever command produced them.

function Write-Stage([string]$Name) {
    Write-Host ""
    Write-Host "-- $Name" -ForegroundColor Cyan
}

function Write-Pass([string]$Name, [string]$Detail) {
    $line = if ($Detail) { "{0,-10} {1}" -f $Name, $Detail } else { $Name }
    Write-Host "OK    $line" -ForegroundColor Green
}

function Write-Warn([string]$Name, [string]$Detail) {
    $line = if ($Detail) { "{0,-10} {1}" -f $Name, $Detail } else { $Name }
    Write-Host "WARN  $line" -ForegroundColor Yellow
}

function Write-Fail([string]$Name, [string]$Detail) {
    $line = if ($Detail) { "{0,-10} {1}" -f $Name, $Detail } else { $Name }
    Write-Host "FAIL  $line" -ForegroundColor Red
}

function New-Refusal([string]$Problem, [string]$Fix) {
    $text = $Problem
    if ($Fix) { $text += [Environment]::NewLine + "  fix: $Fix" }
    return $text
}

# `throw "text"` sets TargetObject to that same string. A real fault leaves
# TargetObject null, or sets it to a path, so the message is compared too.
function Test-IsRefusal($ErrorRecord) {
    return ($ErrorRecord.TargetObject -is [string]) -and
           ($ErrorRecord.Exception.Message -ceq [string]$ErrorRecord.TargetObject)
}

function Write-Refusal([string]$Name, [string]$Message) {
    $lines = @($Message -split "`r?`n")
    Write-Fail $Name $lines[0]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        Write-Host $lines[$i] -ForegroundColor Red
    }
}

# $global:, because Import-Module -Force wipes module scope, and `stack update`
# hands off to another command in the same process.
if (-not $global:MakuActions) { $global:MakuActions = [System.Collections.ArrayList]::new() }

function Add-Action([string]$Verb, [string]$Detail) {
    [void]$global:MakuActions.Add([pscustomobject]@{ At = Get-Date; Verb = $Verb; Detail = $Detail })
}

function Clear-Actions {
    if (-not $global:MakuActions) { $global:MakuActions = [System.Collections.ArrayList]::new() }
    $global:MakuActions.Clear()
}

function Write-ActionLog {
    if (-not $global:MakuActions -or $global:MakuActions.Count -eq 0) { return }
    Write-Stage 'actions taken'
    foreach ($a in $global:MakuActions) {
        Write-Host ("  {0}  {1,-10} {2}" -f $a.At.ToString('HH:mm:ss'), $a.Verb, $a.Detail)
    }
    $global:MakuActions.Clear()
}

Export-ModuleMember -Function Write-Stage, Write-Pass, Write-Warn, Write-Fail, `
                              New-Refusal, Test-IsRefusal, Write-Refusal, `
                              Add-Action, Write-ActionLog, Clear-Actions
