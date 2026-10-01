#: show stack logs (-Follow to stream, -Service to filter)

<#
.SYNOPSIS
    podman compose logs.

.PARAMETER Service
    One service.

.PARAMETER Follow
    Stream until interrupted.

.PARAMETER Tail
    How many lines to show first. Default 200.

.EXAMPLE
    .\contrib\maku.ps1 stack logs -Service api
.EXAMPLE
    .\contrib\maku.ps1 stack logs -Follow
#>
param(
    [ValidateSet('db', 'redis', 'socket-proxy', 'api', 'worker-gpu', 'worker-cpu', 'worker-io', 'worker-parse', 'frontend', 'nginx')]
    [string]$Service,
    [switch]$Follow,
    [int]$Tail = 200
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Use-NativeExitCodes

Test-PodmanReady
$mode = Get-StackMode
$composeArgs = @('logs', '--tail', "$Tail")
if ($Follow) { $composeArgs += '-f' }
if ($Service) { $composeArgs += $Service }
$code = Invoke-StackCompose -Arguments $composeArgs -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume)
exit $code
