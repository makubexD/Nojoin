#: create .env, pull the pinned images, start, and verify

<#
.SYNOPSIS
    First-run setup. Safe to re-run: existing non-placeholder secrets are left alone.

.DESCRIPTION
    Copies .env.example to .env when .env is missing, then generates
    DATA_ENCRYPTION_KEY, REDIS_PASSWORD, and FIRST_RUN_PASSWORD when those keys
    are missing or still the example placeholders. Only the first-run password
    is printed, and only when it was just generated.

.PARAMETER Gpu
    Turn GPU mode on for this run and remember it. -Gpu:$false turns it off.
    Absent leaves the saved mode. -Gpu does not change DataVolume.

.PARAMETER DataVolume
    Turn the named data volume on. -DataVolume:$false turns it off.
    Absent leaves the saved mode.

.PARAMETER IgnoreExistingData
    Switch to the named volume even when ./data exists and is not empty.
    Recordings already in ./data will not be visible; copy them first.

.EXAMPLE
    .\contrib\maku.ps1 stack install
#>
param(
    [switch]$Gpu,
    [switch]$DataVolume,
    [switch]$IgnoreExistingData
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Repo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Podman.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\lib\Images.psm1') -Force
Use-NativeExitCodes

function New-Token([int]$Length) {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = [byte[]]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $chars = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$chars.Append($alphabet[$b % $alphabet.Length]) }
    return $chars.ToString()
}

$root = Get-RepoRoot
$envPath = Join-Path $root '.env'
$example = Join-Path $root '.env.example'
if (-not (Test-Path -LiteralPath $envPath)) {
    if (-not (Test-Path -LiteralPath $example)) {
        throw (New-Refusal ".env.example is missing, so a new .env cannot be created." "restore .env.example from git")
    }
    Copy-Item -LiteralPath $example -Destination $envPath
    Add-Action 'created' '.env from .env.example'
}

$placeholders = @{
    FIRST_RUN_PASSWORD  = @('change_this_before_first_start')
    DATA_ENCRYPTION_KEY = @('change_this_to_a_long_random_secret')
    REDIS_PASSWORD      = @('change_this_before_remote_access', 'change_to_secure_string')
}
$map = Read-DotEnv $envPath
$generatedPassword = $null
foreach ($key in @('DATA_ENCRYPTION_KEY', 'REDIS_PASSWORD', 'FIRST_RUN_PASSWORD')) {
    $current = [string]$map[$key]
    $needs = (-not $map.ContainsKey($key)) -or [string]::IsNullOrWhiteSpace($current) -or ($current -in $placeholders[$key])
    if (-not $needs) { continue }
    $length = if ($key -eq 'FIRST_RUN_PASSWORD') { 24 } else { 48 }
    $fresh = New-Token $length
    Set-DotEnvKey $envPath $key $fresh
    $map[$key] = $fresh
    if ($key -eq 'FIRST_RUN_PASSWORD') { $generatedPassword = $fresh }
    Add-Action 'generated' $key
}

if ($generatedPassword) {
    Write-Host ""
    Write-Host "First-run password (shown once):" -ForegroundColor Cyan
    Write-Host "  $generatedPassword"
    Write-Host "Open https://localhost:14443/setup and enter it when asked."
    Write-Host "It is stored in .env as FIRST_RUN_PASSWORD and will not be printed again."
    Write-Host ""
} else {
    Write-Host "FIRST_RUN_PASSWORD is already set. It was not printed."
}

$saved = Get-StackMode
$modeArgs = @{}
if ($PSBoundParameters.ContainsKey('Gpu')) { $modeArgs.Gpu = [bool]$Gpu }
if ($PSBoundParameters.ContainsKey('DataVolume')) { $modeArgs.DataVolume = [bool]$DataVolume }
$mode = Resolve-StackMode @modeArgs
Assert-DataVolumeSwitch -WasEnabled:([bool]$saved.DataVolume) -Enable:([bool]$mode.DataVolume) -IgnoreExistingData:$IgnoreExistingData

& (Join-Path $PSScriptRoot 'doctor.ps1') -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume)
if ($LASTEXITCODE -ne 0) {
    throw (New-Refusal "doctor failed, so nothing was started." "fix the lines above, then re-run stack install")
}

Write-Stage 'pull'
$code = Invoke-StackCompose -Arguments @('pull') -Gpu:([bool]$mode.Gpu) -DataVolume:([bool]$mode.DataVolume) -RequireEnvFile
if ($code -ne 0) {
    throw (New-Refusal "podman compose pull failed (exit $code)." "podman compose version")
}
Add-Action 'pulled' "images at $(Get-NojoinTag)"

$startArgs = @{
    Gpu = [bool]$mode.Gpu
    DataVolume = [bool]$mode.DataVolume
}
if ($IgnoreExistingData) { $startArgs.IgnoreExistingData = $true }
& (Join-Path $PSScriptRoot 'start.ps1') @startArgs
if ($LASTEXITCODE -ne 0) { throw "stack start failed (exit $LASTEXITCODE)" }

& (Join-Path $PSScriptRoot 'verify.ps1')
exit $LASTEXITCODE
