#: start the stack (safe to re-run; reuses the saved mode)

<#
.SYNOPSIS
    podman compose up -d for the Podman override. Safe to re-run.

.DESCRIPTION
    Reuses the mode saved by the last start, install, or update. Passing -Gpu
    or -DataVolume turns that mode on. Passing -Gpu does not change DataVolume.
    Turning a mode off takes an explicit false: -Gpu:$false or -DataVolume:$false.

.PARAMETER Gpu
    Turn GPU mode on. -Gpu:$false turns it off. Absent leaves the saved mode.

.PARAMETER DataVolume
    Turn the named data volume on. -DataVolume:$false turns it off.
    Absent leaves the saved mode.

.PARAMETER IgnoreExistingData
    Switch to the named volume even when ./data exists and is not empty.
    Recordings already in ./data will not be visible; copy them first.

.PARAMETER Service
    Start only this service. Switches passed with it still update the saved mode.

.EXAMPLE
    .\contrib\maku.ps1 stack start
.EXAMPLE
    .\contrib\maku.ps1 stack start -Gpu
.EXAMPLE
    .\contrib\maku.ps1 stack start -DataVolume -IgnoreExistingData
.EXAMPLE
    .\contrib\maku.ps1 stack start -Gpu:$false
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

# Refuse a DataVolume switch before Test-PodmanReady. That helper starts a
# stopped machine, and this refusal does not need it.
$saved = Get-StackMode
$modeArgs = @{}
if ($PSBoundParameters.ContainsKey('Gpu')) { $modeArgs.Gpu = [bool]$Gpu }
if ($PSBoundParameters.ContainsKey('DataVolume')) { $modeArgs.DataVolume = [bool]$DataVolume }
$mode = Resolve-StackMode @modeArgs
Assert-DataVolumeSwitch -WasEnabled:([bool]$saved.DataVolume) -Enable:([bool]$mode.DataVolume) -IgnoreExistingData:$IgnoreExistingData

Test-PodmanReady
Assert-EnvFile | Out-Null
Save-StackMode ([bool]$mode.Gpu) ([bool]$mode.DataVolume)

$composeArgs = @('up', '-d')
if ($Service) { $composeArgs += $Service }
$code = Invoke-StackCompose -Arguments $composeArgs -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume) -RequireEnvFile
if ($code -ne 0) {
    throw (New-Refusal "podman compose up failed (exit $code)." ".\contrib\maku.ps1 stack logs")
}

$detail = "tag $(Get-NojoinTag)"
if ($mode.Gpu) { $detail += ' +gpu' }
if ($mode.DataVolume) { $detail += ' +datavolume' }
if ($Service) { $detail += " service $Service" }
Add-Action 'started' $detail
Write-Pass 'start' $detail
exit 0
