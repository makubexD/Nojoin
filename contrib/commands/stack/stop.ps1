#: stop the stack without deleting volumes

<#
.SYNOPSIS
    podman compose stop. Volumes, ./data, and the saved Gpu/DataVolume mode are kept.

.PARAMETER Service
    Stop only this service.

.EXAMPLE
    .\contrib\maku.ps1 stack stop
#>
param(
    [ValidateSet('db', 'redis', 'socket-proxy', 'api', 'worker-gpu', 'worker-cpu', 'worker-io', 'worker-parse', 'frontend', 'nginx')]
    [string]$Service
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Use-NativeExitCodes

Test-PodmanReady
$mode = Get-StackMode
$composeArgs = @('stop')
if ($Service) { $composeArgs += $Service }
$code = Invoke-StackCompose -Arguments $composeArgs -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume)
if ($code -ne 0) {
    throw (New-Refusal "podman compose stop failed (exit $code)." "podman ps --filter name=nojoin-")
}
Add-Action 'stopped' $(if ($Service) { $Service } else { 'stack' })
Write-Pass 'stop' $(if ($Service) { $Service } else { 'stack' })
exit 0
