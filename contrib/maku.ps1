<#
.SYNOPSIS
    The one entry point for this fork's tooling.

.DESCRIPTION
    Grammar:  maku <resource> <action> [options]

    The resource says what you are operating on, the action says what you are
    doing to it, and options only modify that operation. Run with no arguments
    to see every resource and action, or with just a resource to see that
    resource's actions.

    NO param() BLOCK, DELIBERATELY. A declared parameter block makes PowerShell
    bind every -Flag itself, so it rejects "-Gpu" before the command ever sees
    it. With no param block everything arrives in $args and is handed through.

.EXAMPLE
    .\contrib\maku.ps1
.EXAMPLE
    .\contrib\maku.ps1 stack start -Gpu
.EXAMPLE
    .\contrib\maku.ps1 fork status
#>
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "maku.ps1 needs PowerShell 7 (pwsh). This is $($PSVersionTable.PSVersion)." -ForegroundColor Red
    exit 2
}

Import-Module (Join-Path $PSScriptRoot 'lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Cli.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Console.psm1') -Force
Use-NativeExitCodes

$CommandRoot = Join-Path $PSScriptRoot 'commands'
$Resource = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$Action   = if ($args.Count -ge 2) { [string]$args[1] } else { '' }
# [object[]] is load-bearing: a one-element slice unrolls to a string.
[object[]]$Rest = @()
if ($args.Count -gt 2) { $Rest = $args[2..($args.Count - 1)] }

function Get-Resources {
    return @(Get-ChildItem -Path $CommandRoot -Directory -ErrorAction SilentlyContinue |
             Where-Object { Get-ChildItem -Path $_.FullName -Filter '*.ps1' -ErrorAction SilentlyContinue } |
             Sort-Object Name | Select-Object -ExpandProperty Name)
}

function Get-Actions([string]$res) {
    return @(Get-ChildItem -Path (Join-Path $CommandRoot $res) -Filter '*.ps1' -ErrorAction SilentlyContinue |
             Sort-Object Name | ForEach-Object { $_.BaseName })
}

function Get-Summary([string]$res, [string]$act) {
    $first = Get-Content (Join-Path $CommandRoot "$res\$act.ps1") -TotalCount 1 -ErrorAction SilentlyContinue
    if ($first -match '^#:\s*(.+)$') { return $Matches[1].Trim() }
    return ''
}

function Show-Resource([string]$res) {
    foreach ($act in (Get-Actions $res)) {
        Write-Host ("  {0,-9} {1,-9} {2}" -f $res, $act, (Get-Summary $res $act))
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "  maku <resource> <action> [options]"
    Write-Host ""
    $all = @(Get-Resources)
    for ($i = 0; $i -lt $all.Count; $i++) {
        Show-Resource $all[$i]
        if ($i -lt $all.Count - 1) { Write-Host "" }
    }
    Write-Host ""
    Write-Host "  Detail on any command:  Get-Help .\contrib\commands\<resource>\<action>.ps1 -Full"
    Write-Host ""
}

if (-not $Resource) { Show-Help; exit 0 }

$resources = @(Get-Resources)
if ($Resource -notin $resources) {
    Write-Host "Unknown resource '$Resource'." -ForegroundColor Red
    Write-Host "  known: $($resources -join ', ')"
    exit 2
}

if (-not $Action) {
    Write-Host ""
    Show-Resource $Resource
    Write-Host ""
    exit 0
}

$actions = @(Get-Actions $Resource)
if ($Action -notin $actions) {
    Write-Host "Unknown action '$Action' for '$Resource'." -ForegroundColor Red
    Write-Host "  known: $($actions -join ', ')"
    exit 2
}

$script = Join-Path $CommandRoot "$Resource\$Action.ps1"

try {
    $bound = ConvertTo-CommandArguments $script $Rest
} catch {
    Write-Host "$Resource $Action`: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
$positional = $bound.Positional
$named      = $bound.Named

# A global action list survives in an interactive session. A Ctrl-C skips both
# exits below, and the next command would otherwise print the previous run.
Clear-Actions

try {
    & $script @positional @named
    $code = $LASTEXITCODE
    Write-ActionLog
    exit $code
} catch {
    Write-ActionLog
    if (Test-IsRefusal $_) {
        Write-Refusal "$Resource $Action" $_.Exception.Message
    } else {
        Write-Host "$Resource $Action failed unexpectedly -- this is a bug in the CLI." -ForegroundColor Red
        Write-Host ($_ | Out-String)
    }
    exit 1
}
