#: fast-forward, pull images when the pin changed, and verify

<#
.SYNOPSIS
    Update a machine that already runs the stack.

.DESCRIPTION
    git pull --ff-only on the current branch. If that pull changed contrib/,
    the command re-launches itself once (MAKU_RELAUNCHED) so the rest of the
    run is the code that was just fetched. Images are pulled only when the
    pin changed. compose up -d then recreates the services whose config changed.

    Gpu and DataVolume follow the saved mode. Passing a switch turns that mode
    on. -Gpu does not change DataVolume. Turning one off takes an explicit
    false: -Gpu:$false or -DataVolume:$false.

.PARAMETER Gpu
    Turn GPU mode on for this run and remember it. -Gpu:$false turns it off.
    Absent leaves the saved mode.

.PARAMETER DataVolume
    Turn the named data volume on for this run and remember it.
    -DataVolume:$false turns it off. Absent leaves the saved mode.

.PARAMETER IgnoreExistingData
    Switch to the named volume even when ./data exists and is not empty.
    Recordings already in ./data will not be visible; copy them first.

.PARAMETER Service
    Pass a single service to compose up. The pin pull still covers the whole stack.

.EXAMPLE
    .\contrib\maku.ps1 stack update
#>
param(
    [switch]$Gpu,
    [switch]$DataVolume,
    [switch]$IgnoreExistingData,
    [ValidateSet('db', 'redis', 'socket-proxy', 'api', 'worker-gpu', 'worker-cpu', 'worker-io', 'worker-parse', 'frontend', 'nginx')]
    [string]$Service
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Use-NativeExitCodes

$boundGpu = $PSBoundParameters.ContainsKey('Gpu')
$boundDataVolume = $PSBoundParameters.ContainsKey('DataVolume')

function Restart-IfToolingChanged([string]$From, [string]$To, [string]$TagBefore) {
    if ($env:MAKU_RELAUNCHED -eq '1' -or $From -eq $To) { return }
    $touched = @(& git diff --name-only $From $To -- 'contrib/' | Where-Object { $_ })
    if ($touched.Count -eq 0) { return }

    Write-Host "The pull updated contrib/. Re-running with the version just fetched."
    Add-Action 'relaunched' 'the pull replaced contrib/, so the run restarted on the new tooling'
    Write-ActionLog

    $entry = (Resolve-Path (Join-Path $PSScriptRoot '..\..\maku.ps1')).Path
    $childArgs = @('-NoProfile', '-File', $entry, 'stack', 'update')
    if ($boundGpu) { $childArgs += ('-Gpu:$' + [bool]$Gpu) }
    if ($boundDataVolume) { $childArgs += ('-DataVolume:$' + [bool]$DataVolume) }
    if ($IgnoreExistingData) { $childArgs += '-IgnoreExistingData' }
    if ($Service) { $childArgs += @('-Service', $Service) }
    $env:MAKU_RELAUNCHED = '1'
    $env:MAKU_TAG_BEFORE = $TagBefore
    try {
        & pwsh @childArgs
        exit $LASTEXITCODE
    } finally {
        Remove-Item Env:\MAKU_RELAUNCHED -ErrorAction SilentlyContinue
        Remove-Item Env:\MAKU_TAG_BEFORE -ErrorAction SilentlyContinue
    }
}

$branch = Get-CurrentBranch
if ($branch -ne 'podman') {
    throw (New-Refusal "stack update only runs on the podman branch (this checkout is '$branch')." `
                       "git checkout podman")
}

Assert-CleanTree
$root = Get-RepoRoot
Push-Location $root
try {
    $tagBefore = if ($env:MAKU_RELAUNCHED -eq '1' -and $env:MAKU_TAG_BEFORE) { [string]$env:MAKU_TAG_BEFORE } else { Get-NojoinTag }
    $before = (& git rev-parse HEAD).Trim()

    Write-Host "Pulling $(Get-CurrentBranch)..."
    $pullText = (& git pull --ff-only 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw (New-Refusal "git pull --ff-only failed.`n$pullText" `
                           "resolve it by hand, or re-clone and check out podman")
    }
    if ($pullText) { Write-Host $pullText }
    $after = (& git rev-parse HEAD).Trim()
    if ($before -eq $after) {
        Write-Host "Already up to date at $($after.Substring(0, 8))."
    } else {
        Write-Host "Updated $($before.Substring(0, 8)) -> $($after.Substring(0, 8))."
        Add-Action 'pulled' "$($before.Substring(0, 8)) -> $($after.Substring(0, 8))"
    }

    Restart-IfToolingChanged $before $after $tagBefore

    # Refuse a DataVolume switch before Test-PodmanReady. That helper starts a
    # stopped machine, and this refusal does not need it.
    $saved = Get-StackMode
    $modeArgs = @{}
    if ($boundGpu) { $modeArgs.Gpu = [bool]$Gpu }
    if ($boundDataVolume) { $modeArgs.DataVolume = [bool]$DataVolume }
    $mode = Resolve-StackMode @modeArgs
    Assert-DataVolumeSwitch -WasEnabled:([bool]$saved.DataVolume) -Enable:([bool]$mode.DataVolume) -IgnoreExistingData:$IgnoreExistingData

    Test-PodmanReady
    Save-StackMode ([bool]$mode.Gpu) ([bool]$mode.DataVolume)

    $tagAfter = Get-NojoinTag
    if ($tagBefore -ne $tagAfter) {
        Write-Host "Pin changed $tagBefore -> $tagAfter. Pulling images."
        $code = Invoke-StackCompose -Arguments @('pull') -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume) -RequireEnvFile
        if ($code -ne 0) {
            throw (New-Refusal "podman compose pull failed (exit $code)." "the pin moved but the images did not arrive")
        }
        Add-Action 'pulled' "images $tagBefore -> $tagAfter"
    } else {
        Write-Host "Pin is still $tagAfter. Not pulling images."
    }

    $composeArgs = @('up', '-d')
    if ($Service) { $composeArgs += $Service }
    $code = Invoke-StackCompose -Arguments $composeArgs -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume) -RequireEnvFile
    if ($code -ne 0) {
        throw (New-Refusal "podman compose up failed (exit $code)." ".\contrib\maku.ps1 stack logs")
    }
    Add-Action 'updated' "tag $tagAfter"

    & (Join-Path $PSScriptRoot 'verify.ps1')
    exit $LASTEXITCODE
}
finally { Pop-Location }
